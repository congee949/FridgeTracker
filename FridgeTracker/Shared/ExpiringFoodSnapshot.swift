import Foundation
import SwiftUI

// ⚠️ 跨 target 共享契约 —— 本文件同时编译进 FridgeTracker(app) 与 FridgeTrackerWidget(extension)
// 两个 target（project.pbxproj 中有两条 PBXBuildFile 指向同一个 fileRef）。
// 它承载 app ↔ widget 的全部共享约定：ExpiringFoodSnapshot 数据结构、App Group 标识、
// 快照文件 URL、JSON 编解码器，以及 expiryStatusText / expiryStatusColor 展示辅助。
// 修改时请勿移除任一 target 的 membership，否则 widget 或 app 会因找不到符号而编译失败。
let fridgeTrackerAppGroupIdentifier = "group.com.congee.FridgeTracker"
let expiringFoodsSnapshotFileName = "expiring-foods.json"
/// 与写入端 `WidgetDataStore.maximumSnapshotSize` 保持一致。读取端在真正打开文件前
/// 先做一次元数据预检，并在读取后再次校验，避免损坏或被替换的快照撑爆 Widget 进程。
let expiringFoodsSnapshotMaximumByteCount = 10 * 1_024 * 1_024

/// 与时区无关的公历民用日期。JSON 只编码为 `YYYY-MM-DD`，避免备份、Widget 和通知
/// 把“包装上写的某一天”误当成可跨时区平移的时间点。
struct LocalDate: Codable, Hashable, Comparable, Sendable, CustomStringConvertible {
    let year: Int
    let month: Int
    let day: Int

    private static var utcGregorian: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    init?(year: Int, month: Int, day: Int) {
        let components = DateComponents(calendar: Self.utcGregorian, year: year, month: month, day: day)
        guard let date = Self.utcGregorian.date(from: components) else { return nil }
        let roundTrip = Self.utcGregorian.dateComponents([.year, .month, .day], from: date)
        guard roundTrip.year == year, roundTrip.month == month, roundTrip.day == day else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    init(date: Date, timeZone: TimeZone = .current) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        // Every finite Foundation Date maps to a Gregorian year/month/day in a valid timezone.
        self.year = components.year!
        self.month = components.month!
        self.day = components.day!
    }

    init?(iso8601DateString value: String) {
        let fields = value.split(separator: "-", omittingEmptySubsequences: false)
        guard fields.count == 3,
              fields[0].count == 4, fields[1].count == 2, fields[2].count == 2,
              let year = Int(fields[0]), let month = Int(fields[1]), let day = Int(fields[2]),
              let validated = LocalDate(year: year, month: month, day: day) else { return nil }
        self = validated
    }

    var iso8601DateString: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    var description: String { iso8601DateString }

    func date(in timeZone: TimeZone = .current, hour: Int = 0, minute: Int = 0) -> Date? {
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        ))
    }

    func adding(days: Int) -> LocalDate? {
        guard let base = date(in: Self.utcGregorian.timeZone),
              let result = Self.utcGregorian.date(byAdding: .day, value: days, to: base) else { return nil }
        return LocalDate(date: result, timeZone: Self.utcGregorian.timeZone)
    }

    func days(until other: LocalDate) -> Int {
        let start = date(in: Self.utcGregorian.timeZone)!
        let end = other.date(in: Self.utcGregorian.timeZone)!
        return Self.utcGregorian.dateComponents([.day], from: start, to: end).day!
    }

    static func < (lhs: LocalDate, rhs: LocalDate) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let date = LocalDate(iso8601DateString: value) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid Gregorian LocalDate: \(value)")
        }
        self = date
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(iso8601DateString)
    }
}

/// App 与 Widget 共用的稳定分类身份。展示名称可以本地化或改名，持久化/筛选只认这个 ID。
enum FoodCategoryID: String, Codable, CaseIterable, Sendable {
    case vegetable
    case fruit
    case meat
    case seafood
    case dairy
    case egg
    case beverage
    case condiment
    case snack
    case nut
    case baking
    case frozen
    case other

    var displayName: String {
        switch self {
        case .vegetable: return "蔬菜"
        case .fruit: return "水果"
        case .meat: return "肉类"
        case .seafood: return "海鲜"
        case .dairy: return "乳制品"
        case .egg: return "蛋类"
        case .beverage: return "饮料"
        case .condiment: return "调味品"
        case .snack: return "零食"
        case .nut: return "坚果"
        case .baking: return "烘焙"
        case .frozen: return "速冻食品"
        case .other: return "其他"
        }
    }

    /// 兼容 1.1.0 及更早版本快照中以中文展示名充当身份的格式。
    init?(legacyDisplayName: String) {
        guard let match = Self.allCases.first(where: { $0.displayName == legacyDisplayName }) else {
            return nil
        }
        self = match
    }
}

func expiryStatusText(daysUntilExpiry days: Int) -> String {
    if days < 0 { return "已过期 \(-days) 天" }
    if days == 0 { return "今天过期" }
    return "\(days) 天后过期"
}

func expiryStatusColor(daysUntilExpiry days: Int) -> Color {
    if days < 0 { return .red }
    if days <= 3 { return .orange }
    return .green
}

struct ExpiringFoodSnapshot: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let name: String
    let category: String
    let categoryIcon: String
    let displayIcon: String
    let storageZone: String
    let storageIcon: String
    let expiryDate: Date
    let daysUntilExpiry: Int
    /// 新快照始终写入；可选是为了继续读取旧版只含中文 `category` 的 JSON。
    let categoryID: FoodCategoryID?
    /// v2 快照的权威到期日；可选仅用于读取旧版仅含 `expiryDate` 的快照。
    let expiryDayKey: LocalDate?

    init(
        id: UUID,
        name: String,
        category: String,
        categoryIcon: String,
        displayIcon: String,
        storageZone: String,
        storageIcon: String,
        expiryDate: Date,
        daysUntilExpiry: Int,
        categoryID: FoodCategoryID? = nil,
        expiryDayKey: LocalDate? = nil
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.categoryIcon = categoryIcon
        self.displayIcon = displayIcon
        self.storageZone = storageZone
        self.storageIcon = storageIcon
        self.expiryDate = expiryDate
        self.daysUntilExpiry = daysUntilExpiry
        self.categoryID = categoryID
        self.expiryDayKey = expiryDayKey
    }

    var resolvedCategoryID: FoodCategoryID? {
        categoryID ?? FoodCategoryID(legacyDisplayName: category)
    }

    var currentDaysUntilExpiry: Int {
        daysUntilExpiry(relativeTo: Date())
    }

    func daysUntilExpiry(relativeTo now: Date, calendar: Calendar = .current) -> Int {
        if let expiryDayKey {
            let today = LocalDate(date: now, timeZone: calendar.timeZone)
            return today.days(until: expiryDayKey)
        }
        return calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: now),
            to: calendar.startOfDay(for: expiryDate)
        ).day ?? daysUntilExpiry
    }

    var effectiveExpiryDay: LocalDate {
        expiryDayKey ?? LocalDate(date: expiryDate)
    }

    var expiryText: String {
        expiryStatusText(daysUntilExpiry: currentDaysUntilExpiry)
    }
}

/// v2 起用 envelope 明示协议版本；读取端仍兼容旧版顶层数组，避免升级瞬间 Widget 空白。
struct ExpiringFoodSnapshotEnvelope: Codable, Hashable, Sendable {
    static let currentVersion = 2

    let version: Int
    let items: [ExpiringFoodSnapshot]

    init(version: Int = Self.currentVersion, items: [ExpiringFoodSnapshot]) {
        self.version = version
        self.items = items
    }
}

func decodeExpiringFoodSnapshots(from data: Data, decoder: JSONDecoder = .expiringFoods) throws -> [ExpiringFoodSnapshot] {
    if let envelope = try? decoder.decode(ExpiringFoodSnapshotEnvelope.self, from: data) {
        return envelope.items
    }
    return try decoder.decode([ExpiringFoodSnapshot].self, from: data)
}

/// 最多从文件描述符读取 `maximumByteCount + 1` 字节：多出的 1 字节只用于判定超限。
/// 即使路径在元数据预检后被原子替换为更大的文件，也不会把整个新文件映射进内存。
func readBoundedExpiringFoodSnapshotData(
    from url: URL,
    maximumByteCount: Int
) throws -> Data? {
    let (readLimit, overflow) = maximumByteCount.addingReportingOverflow(1)
    guard maximumByteCount >= 0, !overflow else { return nil }

    try Task.checkCancellation()
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }

    var data = Data()
    while data.count < readLimit {
        try Task.checkCancellation()
        let remainingCount = readLimit - data.count
        guard let chunk = try handle.read(upToCount: remainingCount), !chunk.isEmpty else { break }
        data.append(chunk)
    }
    try Task.checkCancellation()
    return data.count <= maximumByteCount ? data : nil
}

/// 在独立 utility task 中完成文件预检、读取、解码和筛选排序，避免 WidgetKit 调用
/// `snapshot` / `timeline` 时把同步文件 I/O 与 JSON 工作留在调用方 actor 上。
///
/// Widget 的容错语义仍是“坏快照等同于没有快照”：文件缺失、非普通文件、超限、
/// 读取竞态、解码失败或任务取消都会返回空数组。读前、读后两次大小检查用于封住
/// 元数据检查与文件描述符读取之间文件被替换/扩大的竞态窗口。
func loadFilteredExpiringFoodSnapshots(
    from url: URL,
    categoryID: FoodCategoryID?,
    relativeTo now: Date,
    calendar: Calendar = .current,
    minimumDaysUntilExpiry: Int = -14,
    limit: Int = 50,
    maximumByteCount: Int = expiringFoodsSnapshotMaximumByteCount
) async -> [ExpiringFoodSnapshot] {
    guard maximumByteCount >= 0, !Task.isCancelled else { return [] }

    let worker = Task.detached(priority: .utility) { () -> [ExpiringFoodSnapshot] in
        do {
            try Task.checkCancellation()

            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true,
                  let fileSize = values.fileSize,
                  fileSize >= 0,
                  fileSize <= maximumByteCount else {
                return []
            }

            guard let data = try readBoundedExpiringFoodSnapshotData(
                from: url,
                maximumByteCount: maximumByteCount
            ) else { return [] }

            try Task.checkCancellation()
            let items = try decodeExpiringFoodSnapshots(from: data)
            try Task.checkCancellation()

            return filteredExpiringFoodSnapshots(
                items,
                categoryID: categoryID,
                relativeTo: now,
                calendar: calendar,
                minimumDaysUntilExpiry: minimumDaysUntilExpiry,
                limit: limit
            )
        } catch {
            return []
        }
    }

    let result = await withTaskCancellationHandler {
        await worker.value
    } onCancel: {
        worker.cancel()
    }
    return Task.isCancelled ? [] : result
}

/// Widget 每次生成 timeline 时重新计算剩余天数；分类过滤发生在截断之前。
/// 只丢弃已经过期太久的库存，未来到期日不设上限。否则坚果等长保质期食材虽然已经
/// 从 App 写入共享快照，却会被原来的 30 天上限隐藏，用户看到的结果等同于“未同步”。
func filteredExpiringFoodSnapshots(
    _ items: [ExpiringFoodSnapshot],
    categoryID: FoodCategoryID?,
    relativeTo now: Date,
    calendar: Calendar = .current,
    minimumDaysUntilExpiry: Int = -14,
    limit: Int = 50
) -> [ExpiringFoodSnapshot] {
    guard limit > 0 else { return [] }
    return Array(items.lazy
        .filter { item in
            item.daysUntilExpiry(relativeTo: now, calendar: calendar) >= minimumDaysUntilExpiry
                && (categoryID == nil || item.resolvedCategoryID == categoryID)
        }
        .sorted {
            if $0.effectiveExpiryDay != $1.effectiveExpiryDay { return $0.effectiveExpiryDay < $1.effectiveExpiryDay }
            if $0.name != $1.name { return $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return $0.id.uuidString < $1.id.uuidString
        }
        .prefix(limit))
}

extension FileManager {
    var expiringFoodsSnapshotURL: URL? {
        containerURL(forSecurityApplicationGroupIdentifier: fridgeTrackerAppGroupIdentifier)?
            .appendingPathComponent(expiringFoodsSnapshotFileName)
    }
}

extension JSONEncoder {
    static var expiringFoods: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var expiringFoods: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
