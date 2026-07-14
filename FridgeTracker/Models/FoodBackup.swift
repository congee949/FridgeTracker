import SwiftUI
import UniformTypeIdentifiers

enum FoodTextConstraintViolation: Equatable, Sendable {
    case empty
    case tooLong(maximum: Int)
    case invalidCharacters
}

enum FoodTextConstraints {
    static let nameMaximum = 100
    static let quantityMaximum = 64
    static let notesMaximum = 10_000
    static let customIconMaximum = 32

    static func violation(
        in value: String?,
        maximum: Int,
        required: Bool = false
    ) -> FoodTextConstraintViolation? {
        let text = value ?? ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let containsVisibleScalar = trimmed.unicodeScalars.contains { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar)
                && !CharacterSet.controlCharacters.contains(scalar)
                && scalar.properties.generalCategory != .format
        }

        if required && (trimmed.isEmpty || !containsVisibleScalar) { return .empty }
        if text.count > maximum { return .tooLong(maximum: maximum) }
        if text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) {
            return .invalidCharacters
        }
        if !trimmed.isEmpty && !containsVisibleScalar { return .invalidCharacters }
        return nil
    }

    static func validateFoodInput(
        name: String,
        quantity: String?,
        notes: String?,
        customIcon: String?
    ) throws {
        try validate(name, field: "食材名称", maximum: nameMaximum, required: true)
        try validate(quantity, field: "数量", maximum: quantityMaximum)
        try validate(notes, field: "备注", maximum: notesMaximum)
        try validate(customIcon, field: "自定义图标", maximum: customIconMaximum)
    }

    private static func validate(
        _ value: String?,
        field: String,
        maximum: Int,
        required: Bool = false
    ) throws {
        switch violation(in: value, maximum: maximum, required: required) {
        case .empty:
            throw FoodInputValidationError.empty(field: field)
        case .tooLong(let maximum):
            throw FoodInputValidationError.tooLong(field: field, maximum: maximum)
        case .invalidCharacters:
            throw FoodInputValidationError.invalidCharacters(field: field)
        case nil:
            return
        }
    }
}

enum FoodInputValidationError: LocalizedError, Equatable {
    case empty(field: String)
    case tooLong(field: String, maximum: Int)
    case invalidCharacters(field: String)

    var field: String {
        switch self {
        case .empty(let field), .tooLong(let field, _), .invalidCharacters(let field):
            return field
        }
    }

    var isEmptyValue: Bool {
        if case .empty = self { return true }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .empty(let field):
            return "请输入\(field)。"
        case .tooLong(let field, let maximum):
            return "\(field)不能超过 \(maximum) 个字符。"
        case .invalidCharacters(let field):
            return "\(field)包含不可见或控制字符，请重新输入。"
        }
    }
}

struct FoodBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var backup: FoodBackup

    init(
        items: [FoodItem],
        records: [FoodDispositionRecord],
        replenishments: [ReplenishmentItem],
        settings: FoodBackupSettings = .current
    ) {
        backup = FoodBackup(
            version: FoodBackup.currentVersion,
            items: items.map(FoodBackupItem.init),
            dispositionRecords: records.map(DispositionBackupItem.init),
            replenishmentItems: replenishments.map(ReplenishmentBackupItem.init),
            settings: settings
        )
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        backup = try Self.decode(from: data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try Self.encode(backup))
    }

    /// Serializes a backup with ISO-8601 dates. Kept symmetric with `decode(from:)`.
    static func encode(_ backup: FoodBackup) throws -> Data {
        // An export must be guaranteed importable by this same build. Validate both before and
        // after encoding so corrupt local settings/fields and an oversized JSON document fail at
        // export time instead of producing false reassurance.
        try backup.validate()
        let minimumPayloadBytes = backup.minimumPayloadUTF8ByteCount()
        guard minimumPayloadBytes <= FoodBackup.maximumFileSize else {
            throw FoodBackupValidationError.fileTooLarge(actualBytes: minimumPayloadBytes)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(backup)
        guard data.count <= FoodBackup.maximumFileSize else {
            throw FoodBackupValidationError.fileTooLarge(actualBytes: data.count)
        }
        return data
    }

    /// Parses a backup file. Must use the same `.iso8601` date strategy as `encode(_:)`: the previous
    /// default decoder expected a `Double` and threw `typeMismatch` on the ISO-8601 date strings that
    /// `encode` writes, so every exported file failed to re-import.
    static func decode(from data: Data) throws -> FoodBackup {
        guard data.count <= FoodBackup.maximumFileSize else {
            throw FoodBackupValidationError.fileTooLarge(actualBytes: data.count)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(FoodBackup.self, from: data)
        try backup.validate()
        return backup
    }
}

/// v1：仅 items，无 version 字段。v2：增加 uuid/originalShelfLifeDays、处置记录、补货清单。
/// v3：增加 app-owned settings，并把导入改为先完整验证、再原子应用。
/// Codable 字段保持可选以读取旧文件；声明为 v3 的文件必须提供稳定身份与民用日期字段。
struct FoodBackup: Codable, Sendable {
    static let currentVersion = 3
    static let maximumFileSize = 25 * 1_024 * 1_024
    static let maximumObjectCount = 100_000
    /// Wire data must remain able to carry values produced by pre-validation releases. The current
    /// UI limits belong at edit time; applying those small limits to backups made legitimate v1/v2
    /// data impossible to restore and re-export. The file cap is the actual resource boundary.
    static let maximumWireTextCharacters = maximumFileSize

    let version: Int?
    let items: [FoodBackupItem]
    let dispositionRecords: [DispositionBackupItem]?
    let replenishmentItems: [ReplenishmentBackupItem]?
    let settings: FoodBackupSettings?

    init(
        version: Int?,
        items: [FoodBackupItem],
        dispositionRecords: [DispositionBackupItem]?,
        replenishmentItems: [ReplenishmentBackupItem]?,
        settings: FoodBackupSettings? = nil
    ) {
        self.version = version
        self.items = items
        self.dispositionRecords = dispositionRecords
        self.replenishmentItems = replenishmentItems
        self.settings = settings
    }

    var effectiveVersion: Int { version ?? 1 }

    func validate(now: Date = Date()) throws {
        guard (1...Self.currentVersion).contains(effectiveVersion) else {
            throw FoodBackupValidationError.unsupportedVersion(effectiveVersion)
        }

        let records = dispositionRecords ?? []
        let replenishments = replenishmentItems ?? []
        let totalCount = items.count + records.count + replenishments.count
        guard totalCount <= Self.maximumObjectCount else {
            throw FoodBackupValidationError.tooManyObjects(totalCount)
        }

        for (index, item) in items.enumerated() {
            try Self.validateWireText(item.name, field: "食材名称", index: index)
            try Self.validateWireText(item.quantity, field: "数量", index: index)
            try Self.validateWireText(item.notes, field: "备注", index: index)
            try Self.validateWireText(item.customIcon, field: "自定义图标", index: index)
            if effectiveVersion >= 3, let days = item.originalShelfLifeDays,
               !(1...FoodShelfLifeConstraints.maximumDays).contains(days) {
                throw FoodBackupValidationError.invalidNumber(field: "原始保质期", index: index)
            }
            try Self.validateTimestamps(
                createdAt: item.createdAt,
                updatedAt: item.updatedAt,
                completedAt: nil,
                kind: "食材",
                index: index,
                now: now
            )
        }

        for (index, record) in records.enumerated() {
            try Self.validateWireText(record.foodName, field: "历史食材名称", index: index)
            try Self.validateWireText(record.quantity, field: "历史数量", index: index)
            try Self.validateWireText(record.customIcon, field: "历史自定义图标", index: index)
            if effectiveVersion >= 3,
               !(1...FoodShelfLifeConstraints.maximumDays).contains(record.shelfLifeDaysEstimate) {
                throw FoodBackupValidationError.invalidNumber(field: "历史保质期", index: index)
            }
            try Self.validateTimestamps(
                createdAt: record.createdAt,
                updatedAt: record.updatedAt,
                completedAt: nil,
                kind: "历史记录",
                index: index,
                now: now
            )
        }

        for (index, item) in replenishments.enumerated() {
            try Self.validateWireText(item.name, field: "补货名称", index: index)
            try Self.validateWireText(item.quantity, field: "补货数量", index: index)
            try Self.validateWireText(item.notes, field: "补货备注", index: index)
            try Self.validateWireText(item.customIcon, field: "补货自定义图标", index: index)
            if effectiveVersion >= 3,
               !(1...FoodShelfLifeConstraints.maximumDays).contains(item.defaultShelfLifeDays) {
                throw FoodBackupValidationError.invalidNumber(field: "补货默认保质期", index: index)
            }
            try Self.validateTimestamps(
                createdAt: item.createdAt,
                updatedAt: item.updatedAt,
                completedAt: item.completedAt,
                kind: "补货记录",
                index: index,
                now: now
            )
        }

        try settings?.validate()
        if effectiveVersion >= 2 {
            guard dispositionRecords != nil else {
                throw FoodBackupValidationError.missingRequiredField("dispositionRecords")
            }
            guard replenishmentItems != nil else {
                throw FoodBackupValidationError.missingRequiredField("replenishmentItems")
            }
        }
        if effectiveVersion >= 3, settings == nil {
            throw FoodBackupValidationError.missingRequiredField("settings")
        }
        if effectiveVersion >= 3 {
            for (index, item) in items.enumerated() {
                try Self.validateRequiredVisibleWireText(
                    item.name,
                    field: "食材名称",
                    index: index
                )
                guard item.uuid != nil else {
                    throw FoodBackupValidationError.missingRequiredField("items[\(index)].uuid")
                }
                guard item.categoryID != nil else {
                    throw FoodBackupValidationError.missingRequiredField("items[\(index)].categoryID")
                }
                guard let expiryDay = item.expiryDayKey else {
                    throw FoodBackupValidationError.missingRequiredField("items[\(index)].expiryDayKey")
                }
                if item.purchaseDate != nil, item.purchaseDayKey == nil {
                    throw FoodBackupValidationError.missingRequiredField("items[\(index)].purchaseDayKey")
                }
                if item.purchaseDate == nil, item.purchaseDayKey == nil,
                   item.originalShelfLifeDays == nil {
                    throw FoodBackupValidationError.missingRequiredField("items[\(index)].originalShelfLifeDays")
                }
                if let purchaseDay = item.purchaseDayKey, purchaseDay > expiryDay {
                    throw FoodBackupValidationError.invalidDateOrder(kind: "食材", index: index)
                }
                guard item.updatedAt != nil else {
                    throw FoodBackupValidationError.missingRequiredField("items[\(index)].updatedAt")
                }
            }
            for (index, record) in records.enumerated() {
                try Self.validateRequiredVisibleWireText(
                    record.foodName,
                    field: "历史食材名称",
                    index: index
                )
                guard record.categoryID != nil else {
                    throw FoodBackupValidationError.missingRequiredField("dispositionRecords[\(index)].categoryID")
                }
                guard let expiryDay = record.expiryDayKey else {
                    throw FoodBackupValidationError.missingRequiredField("dispositionRecords[\(index)].expiryDayKey")
                }
                if record.purchaseDate != nil, record.purchaseDayKey == nil {
                    throw FoodBackupValidationError.missingRequiredField("dispositionRecords[\(index)].purchaseDayKey")
                }
                if let purchaseDay = record.purchaseDayKey, purchaseDay > expiryDay {
                    throw FoodBackupValidationError.invalidDateOrder(kind: "历史记录", index: index)
                }
                guard record.updatedAt != nil else {
                    throw FoodBackupValidationError.missingRequiredField("dispositionRecords[\(index)].updatedAt")
                }
            }
            for (index, item) in replenishments.enumerated() {
                try Self.validateRequiredVisibleWireText(
                    item.name,
                    field: "补货名称",
                    index: index
                )
                guard item.categoryID != nil else {
                    throw FoodBackupValidationError.missingRequiredField("replenishmentItems[\(index)].categoryID")
                }
                guard item.updatedAt != nil else {
                    throw FoodBackupValidationError.missingRequiredField("replenishmentItems[\(index)].updatedAt")
                }
            }
        }
    }

    private static func validateRequiredVisibleWireText(
        _ value: String,
        field: String,
        index: Int
    ) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let containsVisibleScalar = trimmed.unicodeScalars.contains { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar)
                && !CharacterSet.controlCharacters.contains(scalar)
                && scalar.properties.generalCategory != .format
        }
        guard !trimmed.isEmpty, containsVisibleScalar else {
            throw FoodBackupValidationError.emptyRequiredField(field: field, index: index)
        }
    }

    static func validateWireText(
        _ value: String?,
        field: String,
        index: Int
    ) throws {
        let text = value ?? ""
        guard text.count <= maximumWireTextCharacters else {
            throw FoodBackupValidationError.fieldTooLong(
                field: field,
                index: index,
                maximum: maximumWireTextCharacters
            )
        }
        // Preserve legacy tabs/newlines verbatim, but reject NUL and other embedded C0/C1 controls
        // that can truncate Objective-C/system-notification bridges. New UI input remains stricter.
        let allowedControls: Set<UInt32> = [0x09, 0x0A, 0x0D]
        if text.unicodeScalars.contains(where: { scalar in
            CharacterSet.controlCharacters.contains(scalar)
                && !allowedControls.contains(scalar.value)
        }) {
            throw FoodBackupValidationError.invalidText(field: field, index: index)
        }
    }

    /// Lower-bound size estimate used before JSONEncoder allocates the full output. JSON escaping
    /// and structural bytes only increase the final size, so exceeding the cap here is conclusive.
    func minimumPayloadUTF8ByteCount() -> Int {
        var total = 0
        func include(_ value: String?) {
            guard total <= Self.maximumFileSize, let value else { return }
            let (sum, overflow) = total.addingReportingOverflow(value.utf8.count)
            total = overflow ? Int.max : sum
        }

        for item in items {
            include(item.name); include(item.customIcon); include(item.quantity); include(item.notes)
        }
        for record in dispositionRecords ?? [] {
            include(record.foodName); include(record.customIcon); include(record.quantity)
        }
        for item in replenishmentItems ?? [] {
            include(item.name); include(item.customIcon); include(item.quantity); include(item.notes)
        }
        if let bytes = settings?.historySuggestionOverrides?.count {
            let (sum, overflow) = total.addingReportingOverflow(bytes)
            total = overflow ? Int.max : sum
        }
        return total
    }

    private static func validateTimestamps(
        createdAt: Date,
        updatedAt: Date?,
        completedAt: Date?,
        kind: String,
        index: Int,
        now: Date
    ) throws {
        let latestAllowed = now.addingTimeInterval(24 * 60 * 60)
        let earliestAllowed = Date(timeIntervalSince1970: 0)
        guard (earliestAllowed...latestAllowed).contains(createdAt),
              updatedAt.map({ createdAt <= $0 && $0 <= latestAllowed }) ?? true,
              completedAt.map({ createdAt <= $0 && $0 <= latestAllowed }) ?? true else {
            throw FoodBackupValidationError.invalidTimestamp(kind: kind, index: index)
        }
    }
}

struct FoodBackupSettings: Codable, Equatable, Sendable {
    let notificationsEnabled: Bool
    let reminderDaysBefore: Int
    let historyRetentionDays: Int
    let historySuggestionOverrides: Data?

    static var current: FoodBackupSettings {
        let defaults = UserDefaults.standard
        return FoodBackupSettings(
            notificationsEnabled: defaults.object(forKey: "notificationsEnabled") as? Bool ?? true,
            reminderDaysBefore: defaults.object(forKey: "reminderDaysBefore") as? Int ?? -1,
            historyRetentionDays: defaults.object(forKey: HistoryMaintenance.retentionDaysKey) as? Int ?? -1,
            historySuggestionOverrides: defaults.data(forKey: HistorySuggestionStore.storageKey)
        )
    }

    func validate() throws {
        guard [-1, 0, 1, 2, 3, 7].contains(reminderDaysBefore) else {
            throw FoodBackupValidationError.invalidSetting("默认提前提醒")
        }
        guard [-1, 90, 180, 365].contains(historyRetentionDays) else {
            throw FoodBackupValidationError.invalidSetting("历史保留期")
        }
        if let historySuggestionOverrides, historySuggestionOverrides.count > 1_024 * 1_024 {
            throw FoodBackupValidationError.invalidSetting("历史建议设置过大")
        }
        if let historySuggestionOverrides {
            let overrides: [String: HistorySuggestionOverride]
            do {
                overrides = try JSONDecoder().decode(
                    [String: HistorySuggestionOverride].self,
                    from: historySuggestionOverrides
                )
            } catch {
                throw FoodBackupValidationError.invalidSetting("历史建议设置损坏")
            }
            guard overrides.count <= 10_000 else {
                throw FoodBackupValidationError.invalidSetting("历史建议设置过多")
            }
            for (key, override) in overrides {
                let name = override.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard key == name, !name.isEmpty,
                      (1...FoodShelfLifeConstraints.maximumDays).contains(override.defaultShelfLifeDays),
                      key.count <= FoodBackup.maximumWireTextCharacters else {
                    throw FoodBackupValidationError.invalidSetting("历史建议设置内容")
                }
                do {
                    try FoodBackup.validateWireText(override.name, field: "历史建议名称", index: 0)
                    try FoodBackup.validateWireText(override.customIcon, field: "历史建议图标", index: 0)
                } catch {
                    throw FoodBackupValidationError.invalidSetting("历史建议设置内容")
                }
            }
        }
    }

    func apply(to defaults: UserDefaults = .standard) {
        defaults.set(notificationsEnabled, forKey: "notificationsEnabled")
        defaults.set(reminderDaysBefore, forKey: "reminderDaysBefore")
        defaults.set(historyRetentionDays, forKey: HistoryMaintenance.retentionDaysKey)
        if let historySuggestionOverrides {
            defaults.set(historySuggestionOverrides, forKey: HistorySuggestionStore.storageKey)
        } else {
            defaults.removeObject(forKey: HistorySuggestionStore.storageKey)
        }
    }
}

enum FoodBackupValidationError: LocalizedError, Equatable {
    case fileTooLarge(actualBytes: Int)
    case unsupportedVersion(Int)
    case tooManyObjects(Int)
    case emptyRequiredField(field: String, index: Int)
    case fieldTooLong(field: String, index: Int, maximum: Int)
    case invalidText(field: String, index: Int)
    case invalidDateOrder(kind: String, index: Int)
    case invalidTimestamp(kind: String, index: Int)
    case invalidNumber(field: String, index: Int)
    case invalidSetting(String)
    case missingRequiredField(String)

    var errorDescription: String? {
        switch self {
        case .fileTooLarge(let bytes):
            return "备份文件过大（\(bytes / 1_024 / 1_024) MiB），最大允许 25 MiB"
        case .unsupportedVersion(let version):
            return "不支持备份版本 \(version)，当前最高支持 v\(FoodBackup.currentVersion)"
        case .tooManyObjects(let count):
            return "备份包含 \(count) 条记录，超过 100000 条上限"
        case .emptyRequiredField(let field, let index):
            return "\(field)第 \(index + 1) 条为空"
        case .fieldTooLong(let field, let index, let maximum):
            return "\(field)第 \(index + 1) 条超过 \(maximum) 字符"
        case .invalidText(let field, let index):
            return "\(field)第 \(index + 1) 条包含非法控制字符"
        case .invalidDateOrder(let kind, let index):
            return "\(kind)第 \(index + 1) 条的购买日期晚于到期日期"
        case .invalidTimestamp(let kind, let index):
            return "\(kind)第 \(index + 1) 条的记录时间无效"
        case .invalidNumber(let field, let index):
            return "\(field)第 \(index + 1) 条超出允许范围"
        case .invalidSetting(let setting):
            return "备份中的\(setting)无效"
        case .missingRequiredField(let field):
            return "备份结构不完整，缺少 \(field)"
        }
    }
}

struct FoodBackupItem: Codable, Sendable {
    let uuid: UUID?
    let name: String
    let category: FoodCategory
    let categoryID: FoodCategoryID?
    let storageZone: StorageZone
    let customIcon: String?
    let purchaseDate: Date?
    let expiryDate: Date
    let purchaseDayKey: LocalDate?
    let expiryDayKey: LocalDate?
    let quantity: String?
    let notes: String?
    let createdAt: Date
    let updatedAt: Date?
    let originalShelfLifeDays: Int?

    init(_ item: FoodItem) {
        uuid = item.uuid
        name = item.name
        category = item.category
        categoryID = item.stableCategoryID
        storageZone = item.storageZone
        customIcon = item.customIcon
        purchaseDate = item.purchaseDate
        expiryDate = item.expiryDate
        purchaseDayKey = item.purchaseLocalDate
        expiryDayKey = item.expiryLocalDate
        quantity = item.quantity
        notes = item.notes
        createdAt = item.createdAt
        updatedAt = item.updatedAt
        originalShelfLifeDays = item.originalShelfLifeDays
    }

    var foodItem: FoodItem {
        let resolvedPurchaseDate = purchaseDayKey?.date() ?? purchaseDate
        let resolvedExpiryDate = expiryDayKey?.date() ?? expiryDate
        let item = FoodItem(
            name: name,
            category: categoryID.map(FoodCategory.init(stableID:)) ?? category,
            storageZone: storageZone,
            customIcon: customIcon,
            purchaseDate: resolvedPurchaseDate,
            expiryDate: resolvedExpiryDate,
            quantity: quantity,
            notes: notes
        )
        if let uuid {
            item.uuid = uuid
        }
        item.createdAt = createdAt
        item.updatedAt = updatedAt ?? createdAt
        item.purchaseDayKey = purchaseDayKey?.iso8601DateString
            ?? purchaseDate.map { LocalDate(date: $0).iso8601DateString }
        item.expiryDayKey = expiryDayKey?.iso8601DateString
            ?? LocalDate(date: expiryDate).iso8601DateString
        item.categoryIDRaw = categoryID?.rawValue ?? category.stableID.rawValue
        if let originalShelfLifeDays {
            item.originalShelfLifeDays = FoodShelfLifeConstraints.clamped(originalShelfLifeDays)
        } else {
            // v1 备份没存该字段：以原始 createdAt 重算，避免按导入当天计算导致估算失真
            item.refreshOriginalShelfLife()
        }
        return item
    }
}

struct DispositionBackupItem: Codable, Sendable {
    let uuid: UUID
    let foodName: String
    let category: FoodCategory
    let categoryID: FoodCategoryID?
    let storageZone: StorageZone
    let customIcon: String?
    let quantity: String?
    let purchaseDate: Date?
    let expiryDate: Date
    let purchaseDayKey: LocalDate?
    let expiryDayKey: LocalDate?
    let shelfLifeDaysEstimate: Int
    let action: FoodDispositionAction
    let createdAt: Date
    let updatedAt: Date?

    init(_ record: FoodDispositionRecord) {
        uuid = record.uuid
        foodName = record.foodName
        category = record.category
        categoryID = record.stableCategoryID
        storageZone = record.storageZone
        customIcon = record.customIcon
        quantity = record.quantity
        purchaseDate = record.purchaseDate
        expiryDate = record.expiryDate
        purchaseDayKey = record.purchaseDayKey.flatMap(LocalDate.init(iso8601DateString:))
            ?? record.purchaseDate.map { LocalDate(date: $0) }
        expiryDayKey = record.expiryDayKey.flatMap(LocalDate.init(iso8601DateString:))
            ?? LocalDate(date: record.expiryDate)
        shelfLifeDaysEstimate = record.shelfLifeDaysEstimate
        action = record.action
        createdAt = record.createdAt
        updatedAt = record.updatedAt
    }

    var record: FoodDispositionRecord {
        FoodDispositionRecord(
            uuid: uuid,
            foodName: foodName,
            category: categoryID.map(FoodCategory.init(stableID:)) ?? category,
            storageZone: storageZone,
            customIcon: customIcon,
            quantity: quantity,
            purchaseDate: purchaseDayKey?.date() ?? purchaseDate,
            expiryDate: expiryDayKey?.date() ?? expiryDate,
            shelfLifeDaysEstimate: FoodShelfLifeConstraints.clamped(shelfLifeDaysEstimate),
            action: action,
            createdAt: createdAt,
            purchaseDayKey: purchaseDayKey?.iso8601DateString,
            expiryDayKey: expiryDayKey?.iso8601DateString,
            categoryIDRaw: categoryID?.rawValue,
            updatedAt: updatedAt
        )
    }
}

struct ReplenishmentBackupItem: Codable, Sendable {
    let uuid: UUID
    let name: String
    let category: FoodCategory
    let categoryID: FoodCategoryID?
    let storageZone: StorageZone
    let customIcon: String?
    let quantity: String?
    let notes: String?
    let defaultShelfLifeDays: Int
    let createdAt: Date
    let completedAt: Date?
    let updatedAt: Date?

    init(_ item: ReplenishmentItem) {
        uuid = item.uuid
        name = item.name
        category = item.category
        categoryID = item.stableCategoryID
        storageZone = item.storageZone
        customIcon = item.customIcon
        quantity = item.quantity
        notes = item.notes
        defaultShelfLifeDays = item.defaultShelfLifeDays
        createdAt = item.createdAt
        completedAt = item.completedAt
        updatedAt = item.updatedAt
    }

    var replenishmentItem: ReplenishmentItem {
        ReplenishmentItem(
            uuid: uuid,
            name: name,
            category: categoryID.map(FoodCategory.init(stableID:)) ?? category,
            storageZone: storageZone,
            customIcon: customIcon,
            quantity: quantity,
            notes: notes,
            defaultShelfLifeDays: FoodShelfLifeConstraints.clamped(defaultShelfLifeDays),
            createdAt: createdAt,
            completedAt: completedAt,
            categoryIDRaw: categoryID?.rawValue,
            updatedAt: updatedAt
        )
    }
}
