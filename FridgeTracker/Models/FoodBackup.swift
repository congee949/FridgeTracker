import SwiftUI
import UniformTypeIdentifiers

struct FoodBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var backup: FoodBackup

    init(items: [FoodItem]) {
        backup = FoodBackup(items: items.map(FoodBackupItem.init))
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        backup = try JSONDecoder().decode(FoodBackup.self, from: data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return FileWrapper(regularFileWithContents: try encoder.encode(backup))
    }
}

struct FoodBackup: Codable {
    let items: [FoodBackupItem]
}

struct FoodBackupItem: Codable {
    let name: String
    let category: FoodCategory
    let storageZone: StorageZone
    let customIcon: String?
    let purchaseDate: Date?
    let expiryDate: Date
    let quantity: String?
    let notes: String?
    let createdAt: Date

    init(_ item: FoodItem) {
        name = item.name
        category = item.category
        storageZone = item.storageZone
        customIcon = item.customIcon
        purchaseDate = item.purchaseDate
        expiryDate = item.expiryDate
        quantity = item.quantity
        notes = item.notes
        createdAt = item.createdAt
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
        item.createdAt = createdAt
        return item
    }
}
