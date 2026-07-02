import SwiftUI
import UniformTypeIdentifiers

struct FoodBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var backup: FoodBackup

    init(items: [FoodItem], records: [FoodDispositionRecord], replenishments: [ReplenishmentItem]) {
        backup = FoodBackup(
            version: 2,
            items: items.map(FoodBackupItem.init),
            dispositionRecords: records.map(DispositionBackupItem.init),
            replenishmentItems: replenishments.map(ReplenishmentBackupItem.init)
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
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(backup)
    }

    /// Parses a backup file. Must use the same `.iso8601` date strategy as `encode(_:)`: the previous
    /// default decoder expected a `Double` and threw `typeMismatch` on the ISO-8601 date strings that
    /// `encode` writes, so every exported file failed to re-import.
    static func decode(from data: Data) throws -> FoodBackup {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(FoodBackup.self, from: data)
    }
}

/// v1：仅 items，无 version 字段。v2：增加 uuid/originalShelfLifeDays、处置记录、补货清单。
/// 新字段全部可选，旧备份文件可直接解码。
struct FoodBackup: Codable {
    let version: Int?
    let items: [FoodBackupItem]
    let dispositionRecords: [DispositionBackupItem]?
    let replenishmentItems: [ReplenishmentBackupItem]?
}

struct FoodBackupItem: Codable {
    let uuid: UUID?
    let name: String
    let category: FoodCategory
    let storageZone: StorageZone
    let customIcon: String?
    let purchaseDate: Date?
    let expiryDate: Date
    let quantity: String?
    let notes: String?
    let createdAt: Date
    let originalShelfLifeDays: Int?

    init(_ item: FoodItem) {
        uuid = item.uuid
        name = item.name
        category = item.category
        storageZone = item.storageZone
        customIcon = item.customIcon
        purchaseDate = item.purchaseDate
        expiryDate = item.expiryDate
        quantity = item.quantity
        notes = item.notes
        createdAt = item.createdAt
        originalShelfLifeDays = item.originalShelfLifeDays
    }

    var foodItem: FoodItem {
        let item = FoodItem(
            name: name,
            category: category,
            storageZone: storageZone,
            customIcon: customIcon,
            purchaseDate: purchaseDate,
            expiryDate: expiryDate,
            quantity: quantity,
            notes: notes
        )
        if let uuid {
            item.uuid = uuid
        }
        item.createdAt = createdAt
        if let originalShelfLifeDays {
            item.originalShelfLifeDays = originalShelfLifeDays
        } else {
            // v1 备份没存该字段：以原始 createdAt 重算，避免按导入当天计算导致估算失真
            item.refreshOriginalShelfLife()
        }
        return item
    }
}

struct DispositionBackupItem: Codable {
    let uuid: UUID
    let foodName: String
    let category: FoodCategory
    let storageZone: StorageZone
    let customIcon: String?
    let quantity: String?
    let purchaseDate: Date?
    let expiryDate: Date
    let shelfLifeDaysEstimate: Int
    let action: FoodDispositionAction
    let createdAt: Date

    init(_ record: FoodDispositionRecord) {
        uuid = record.uuid
        foodName = record.foodName
        category = record.category
        storageZone = record.storageZone
        customIcon = record.customIcon
        quantity = record.quantity
        purchaseDate = record.purchaseDate
        expiryDate = record.expiryDate
        shelfLifeDaysEstimate = record.shelfLifeDaysEstimate
        action = record.action
        createdAt = record.createdAt
    }

    var record: FoodDispositionRecord {
        FoodDispositionRecord(
            uuid: uuid,
            foodName: foodName,
            category: category,
            storageZone: storageZone,
            customIcon: customIcon,
            quantity: quantity,
            purchaseDate: purchaseDate,
            expiryDate: expiryDate,
            shelfLifeDaysEstimate: shelfLifeDaysEstimate,
            action: action,
            createdAt: createdAt
        )
    }
}

struct ReplenishmentBackupItem: Codable {
    let uuid: UUID
    let name: String
    let category: FoodCategory
    let storageZone: StorageZone
    let customIcon: String?
    let quantity: String?
    let notes: String?
    let defaultShelfLifeDays: Int
    let createdAt: Date
    let completedAt: Date?

    init(_ item: ReplenishmentItem) {
        uuid = item.uuid
        name = item.name
        category = item.category
        storageZone = item.storageZone
        customIcon = item.customIcon
        quantity = item.quantity
        notes = item.notes
        defaultShelfLifeDays = item.defaultShelfLifeDays
        createdAt = item.createdAt
        completedAt = item.completedAt
    }

    var replenishmentItem: ReplenishmentItem {
        ReplenishmentItem(
            uuid: uuid,
            name: name,
            category: category,
            storageZone: storageZone,
            customIcon: customIcon,
            quantity: quantity,
            notes: notes,
            defaultShelfLifeDays: defaultShelfLifeDays,
            createdAt: createdAt,
            completedAt: completedAt
        )
    }
}
