import Foundation
import SwiftData

@Model
class FoodItem {
    var uuid: UUID
    var name: String
    var category: FoodCategory
    var storageZone: StorageZone
    var customIcon: String?
    var purchaseDate: Date?
    var expiryDate: Date
    var quantity: String?
    var notes: String?
    var createdAt: Date
    var originalShelfLifeDays: Int?

    init(name: String, category: FoodCategory, storageZone: StorageZone, customIcon: String? = nil, purchaseDate: Date? = nil, expiryDate: Date, quantity: String? = nil, notes: String? = nil) {
        self.uuid = UUID()
        self.name = name
        self.category = category
        self.storageZone = storageZone
        self.customIcon = customIcon
        self.purchaseDate = purchaseDate
        self.expiryDate = expiryDate
        self.quantity = quantity
        self.notes = notes
        self.createdAt = Date()
        self.originalShelfLifeDays = nil
        refreshOriginalShelfLife()
    }

    /// 无购买日期时以 createdAt 当天为入库日估算原始保质期；有购买日期时清空（实时按购买日期计算）。
    /// 创建、编辑（改保质期/增删购买日期）、从备份恢复后都应调用，保证估算不随时间衰减。
    func refreshOriginalShelfLife() {
        if purchaseDate == nil {
            let days = Calendar.current.dateComponents(
                [.day],
                from: Calendar.current.startOfDay(for: createdAt),
                to: Calendar.current.startOfDay(for: expiryDate)
            ).day ?? 1
            originalShelfLifeDays = max(days, 1)
        } else {
            originalShelfLifeDays = nil
        }
    }

    var daysUntilExpiry: Int {
        Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()), to: Calendar.current.startOfDay(for: expiryDate)).day ?? 0
    }

    var isExpired: Bool {
        daysUntilExpiry < 0
    }

    var displayIcon: String {
        let icon = customIcon?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return icon.isEmpty ? category.icon : icon
    }

    var shelfLifeDaysEstimate: Int {
        if let purchaseDate {
            let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: purchaseDate), to: Calendar.current.startOfDay(for: expiryDate)).day ?? 1
            return max(days, 1)
        }
        if let originalShelfLifeDays { return max(originalShelfLifeDays, 1) }
        return max(daysUntilExpiry, 1)
    }

    var isExpiringSoon: Bool {
        (0...3).contains(daysUntilExpiry)
    }

    var quantityDisplayText: String? {
        guard let quantity, !quantity.isEmpty else { return nil }
        return FoodQuantity.parse(quantity)?.displayText ?? quantity
    }

    /// 数量的两种模式：可解析（「3个」「1/3盒」）按份数计数、逐份消耗；
    /// 不可解析（「半盒」「0.5kg」）为自由文本，仅展示，消耗时整项移除。
    var hasCountableQuantity: Bool {
        FoodQuantity.parse(quantity) != nil
    }

    @discardableResult
    func reduceQuantityByOne() -> Bool {
        guard let parsedQuantity = FoodQuantity.parse(quantity) else { return true }
        guard let reduced = parsedQuantity.reducedByOne() else { return true }

        quantity = reduced.storageText
        return false
    }

    @discardableResult
    func mergeQuantity(from addedQuantity: String) -> Bool {
        guard
            let current = FoodQuantity.parse(quantity),
            let added = FoodQuantity.parse(addedQuantity),
            current.unit == added.unit
        else {
            return false
        }

        quantity = current.adding(added).storageText
        return true
    }
}

extension FoodItem {
    /// 按 uuid 同步直查，不依赖 @Query 的加载时机；深链冷启动也能立即拿到结果。
    static func find(uuid: UUID, in context: ModelContext) -> FoodItem? {
        var descriptor = FetchDescriptor<FoodItem>(predicate: #Predicate { $0.uuid == uuid })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }
}

struct FoodQuantity {
    let current: Int
    let total: Int
    let unit: String

    var displayText: String {
        if current == total {
            return "\(current)\(unit)"
        }
        return "\(current)/\(total)\(unit)"
    }

    var storageText: String {
        displayText
    }

    static func parse(_ rawValue: String?) -> FoodQuantity? {
        guard let rawValue else { return nil }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        let firstNumber = readNumber(in: value, from: value.startIndex)
        guard let current = firstNumber.value, current > 0 else { return nil }

        let afterCurrent = firstNumber.end
        if afterCurrent < value.endIndex, value[afterCurrent] == "/" {
            let totalStart = value.index(after: afterCurrent)
            let secondNumber = readNumber(in: value, from: totalStart)
            guard let total = secondNumber.value, total >= current else { return nil }

            let unit = normalizedUnit(String(value[secondNumber.end...]))
            return FoodQuantity(current: current, total: total, unit: unit)
        }

        let unit = normalizedUnit(String(value[afterCurrent...]))
        return FoodQuantity(current: current, total: current, unit: unit)
    }

    func reducedByOne() -> FoodQuantity? {
        guard current > 1 else { return nil }
        return FoodQuantity(current: current - 1, total: total, unit: unit)
    }

    func adding(_ other: FoodQuantity) -> FoodQuantity {
        let newCurrent = current + other.current
        let newTotal = total + other.total
        return FoodQuantity(current: newCurrent, total: newTotal, unit: unit)
    }

    private static func readNumber(in value: String, from start: String.Index) -> (value: Int?, end: String.Index) {
        var index = start
        var digits = ""

        while index < value.endIndex {
            let character = value[index]
            guard character.isNumber else { break }
            digits.append(character)
            index = value.index(after: index)
        }

        return (Int(digits), index)
    }

    private static func normalizedUnit(_ rawUnit: String) -> String {
        let unit = rawUnit.trimmingCharacters(in: .whitespacesAndNewlines)
        return unit.isEmpty ? "个" : unit
    }
}

enum StorageZone: String, Codable, CaseIterable {
    case fridge = "冷藏"
    case freezer = "冷冻"
    case pantry = "常温"

    var icon: String {
        switch self {
        case .fridge: return "❄️"
        case .freezer: return "🧊"
        case .pantry: return "🏠"
        }
    }
}

enum FoodCategory: String, Codable, CaseIterable {
    case vegetable = "蔬菜"
    case fruit = "水果"
    case meat = "肉类"
    case seafood = "海鲜"
    case dairy = "乳制品"
    case egg = "蛋类"
    case beverage = "饮料"
    case condiment = "调味品"
    case snack = "零食"
    case nut = "坚果"
    case baking = "烘焙"
    case frozen = "速冻食品"
    case other = "其他"

    var icon: String {
        switch self {
        case .vegetable: return "🥬"
        case .fruit: return "🍎"
        case .meat: return "🥩"
        case .seafood: return "🦐"
        case .dairy: return "🥛"
        case .egg: return "🥚"
        case .beverage: return "🧃"
        case .condiment: return "🧂"
        case .snack: return "🍪"
        case .nut: return "🥜"
        case .baking: return "🍞"
        case .frozen: return "🧊"
        case .other: return "📦"
        }
    }

    /// 消耗动作的动词词根（吃/喝/用），用于拼接「吃掉」「已吃掉 1 份」等文案。
    var consumeVerb: String {
        switch self {
        case .beverage, .dairy: return "喝"
        case .condiment:        return "用"
        default:                return "吃"
        }
    }
}

enum FoodDispositionAction: String, Codable {
    case consumed
    case discarded

    var displayName: String {
        switch self {
        case .consumed: return "吃掉"
        case .discarded: return "扔掉"
        }
    }
}

@Model
class FoodDispositionRecord {
    var uuid: UUID
    var foodName: String
    var category: FoodCategory
    var storageZone: StorageZone
    var customIcon: String?
    var quantity: String?
    var purchaseDate: Date?
    var expiryDate: Date
    var shelfLifeDaysEstimate: Int
    var action: FoodDispositionAction
    var createdAt: Date

    init(item: FoodItem, action: FoodDispositionAction) {
        self.uuid = UUID()
        self.foodName = item.name
        self.category = item.category
        self.storageZone = item.storageZone
        self.customIcon = item.customIcon
        self.quantity = item.quantity
        self.purchaseDate = item.purchaseDate
        self.expiryDate = item.expiryDate
        self.shelfLifeDaysEstimate = item.shelfLifeDaysEstimate
        self.action = action
        self.createdAt = Date()
    }

    /// 字段级 init，供备份恢复使用。
    init(uuid: UUID, foodName: String, category: FoodCategory, storageZone: StorageZone, customIcon: String?, quantity: String?, purchaseDate: Date?, expiryDate: Date, shelfLifeDaysEstimate: Int, action: FoodDispositionAction, createdAt: Date) {
        self.uuid = uuid
        self.foodName = foodName
        self.category = category
        self.storageZone = storageZone
        self.customIcon = customIcon
        self.quantity = quantity
        self.purchaseDate = purchaseDate
        self.expiryDate = expiryDate
        self.shelfLifeDaysEstimate = shelfLifeDaysEstimate
        self.action = action
        self.createdAt = createdAt
    }
}

@Model
class ReplenishmentItem {
    var uuid: UUID
    var name: String
    var category: FoodCategory
    var storageZone: StorageZone
    var customIcon: String?
    var quantity: String?
    var notes: String?
    var defaultShelfLifeDays: Int
    var createdAt: Date
    var completedAt: Date?

    init(item: FoodItem) {
        self.uuid = UUID()
        self.name = item.name
        self.category = item.category
        self.storageZone = item.storageZone
        self.customIcon = item.customIcon
        self.quantity = item.quantity
        self.notes = item.notes
        self.defaultShelfLifeDays = item.shelfLifeDaysEstimate
        self.createdAt = Date()
    }

    init(record: FoodDispositionRecord) {
        self.uuid = UUID()
        self.name = record.foodName
        self.category = record.category
        self.storageZone = record.storageZone
        self.customIcon = record.customIcon
        self.quantity = record.quantity
        self.notes = nil
        self.defaultShelfLifeDays = record.shelfLifeDaysEstimate
        self.createdAt = Date()
    }

    /// 字段级 init，供备份恢复使用。
    init(uuid: UUID, name: String, category: FoodCategory, storageZone: StorageZone, customIcon: String?, quantity: String?, notes: String?, defaultShelfLifeDays: Int, createdAt: Date, completedAt: Date?) {
        self.uuid = uuid
        self.name = name
        self.category = category
        self.storageZone = storageZone
        self.customIcon = customIcon
        self.quantity = quantity
        self.notes = notes
        self.defaultShelfLifeDays = defaultShelfLifeDays
        self.createdAt = createdAt
        self.completedAt = completedAt
    }

    var displayIcon: String {
        let icon = customIcon?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return icon.isEmpty ? category.icon : icon
    }

}

extension ReplenishmentItem {
    static let autoReplenishThreshold = 2

    /// 若同名待补货项尚不存在则插入；返回是否新插入。
    @discardableResult
    static func addIfAbsent(for item: FoodItem, in context: ModelContext) -> Bool {
        let name = item.name
        let descriptor = FetchDescriptor<ReplenishmentItem>(
            predicate: #Predicate { $0.completedAt == nil && $0.name == name }
        )
        let existing = (try? context.fetchCount(descriptor)) ?? 0
        guard existing == 0 else { return false }
        context.insert(ReplenishmentItem(item: item))
        return true
    }

    /// 当某食材近 30 天内被「吃掉」次数达到阈值时自动加入补货（窗口与「从历史生成」一致）。
    static func autoAddIfNeeded(for item: FoodItem, in context: ModelContext) {
        let name = item.name
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        let descriptor = FetchDescriptor<FoodDispositionRecord>(
            predicate: #Predicate { $0.foodName == name && $0.createdAt >= cutoff }
        )
        let records = (try? context.fetch(descriptor)) ?? []
        let consumedCount = records.filter { $0.action == .consumed }.count
        guard consumedCount >= autoReplenishThreshold else { return }
        addIfAbsent(for: item, in: context)
    }
}

/// 历史/补货记录的保留策略：处置记录和已完成的补货项按用户设置的天数清理，
/// 待补货项与当前库存永不清理。默认「永久保留」，只有用户显式选择期限后才会删数据。
enum HistoryMaintenance {
    static let retentionDaysKey = "historyRetentionDays"
    /// -1 = 永久保留（默认）；其余为保留天数
    static let retentionOptions: [(label: String, days: Int)] = [
        ("永久", -1), ("90 天", 90), ("180 天", 180), ("1 年", 365)
    ]

    /// defaults 可注入：单测运行在真实 app 宿主进程里，若直接读写 UserDefaults.standard，
    /// 测试残留的保留期会在下次启动时触发对真实数据的静默清理。
    static func retentionDays(from defaults: UserDefaults = .standard) -> Int {
        let stored = defaults.object(forKey: retentionDaysKey) as? Int
        return stored ?? -1
    }

    /// 启动时按当前策略清理；策略为「永久」时不动任何数据。
    static func pruneIfEnabled(in context: ModelContext, defaults: UserDefaults = .standard, now: Date = Date()) {
        let days = retentionDays(from: defaults)
        guard days > 0 else { return }
        prune(in: context, retentionDays: days, now: now)
    }

    /// 删除 cutoff 之前的处置记录和 cutoff 之前完成的补货项；返回删除数量供设置页展示。
    @discardableResult
    static func prune(in context: ModelContext, retentionDays: Int, now: Date = Date()) -> (records: Int, replenishments: Int) {
        guard retentionDays > 0,
              let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: now) else {
            return (0, 0)
        }

        let recordDescriptor = FetchDescriptor<FoodDispositionRecord>(
            predicate: #Predicate { $0.createdAt < cutoff }
        )
        let staleRecords = (try? context.fetch(recordDescriptor)) ?? []
        staleRecords.forEach(context.delete)

        // completedAt 为可选值，#Predicate 里只筛「已完成」，超龄判断放到内存里做
        let completedDescriptor = FetchDescriptor<ReplenishmentItem>(
            predicate: #Predicate { $0.completedAt != nil }
        )
        let completed = (try? context.fetch(completedDescriptor)) ?? []
        let staleReplenishments = completed.filter { item in
            guard let completedAt = item.completedAt else { return false }
            return completedAt < cutoff
        }
        staleReplenishments.forEach(context.delete)

        if !staleRecords.isEmpty || !staleReplenishments.isEmpty {
            try? context.save()
        }
        return (staleRecords.count, staleReplenishments.count)
    }
}
