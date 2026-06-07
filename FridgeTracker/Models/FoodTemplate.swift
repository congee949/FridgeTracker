import Foundation

struct FoodTemplate: Identifiable {
    let id = UUID()
    let name: String
    let category: FoodCategory
    let storageZone: StorageZone
    let customIcon: String?
    let defaultShelfLifeDays: Int
    let quantity: String?
    let notes: String?
    let purchaseDate: Date?

    var icon: String {
        customIcon ?? category.icon
    }

    var normalizedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func applying(_ override: HistorySuggestionOverride?) -> FoodTemplate {
        guard let override else { return self }
        return FoodTemplate(
            name: name,
            category: override.category,
            storageZone: override.storageZone,
            customIcon: override.customIcon,
            defaultShelfLifeDays: override.defaultShelfLifeDays,
            quantity: quantity,
            notes: notes,
            purchaseDate: purchaseDate
        )
    }

    static let common: [FoodTemplate] = [
        FoodTemplate(name: "牛奶", category: .dairy, storageZone: .fridge, customIcon: "🥛", defaultShelfLifeDays: 7, quantity: nil, notes: nil, purchaseDate: nil),
        FoodTemplate(name: "鸡蛋", category: .egg, storageZone: .fridge, customIcon: "🥚", defaultShelfLifeDays: 21, quantity: nil, notes: nil, purchaseDate: nil),
        FoodTemplate(name: "草莓", category: .fruit, storageZone: .fridge, customIcon: "🍓", defaultShelfLifeDays: 3, quantity: nil, notes: nil, purchaseDate: nil),
        FoodTemplate(name: "鸡胸肉", category: .meat, storageZone: .freezer, customIcon: "🥩", defaultShelfLifeDays: 30, quantity: nil, notes: nil, purchaseDate: nil),
        FoodTemplate(name: "厚椰乳", category: .beverage, storageZone: .fridge, customIcon: "🥥", defaultShelfLifeDays: 7, quantity: nil, notes: nil, purchaseDate: nil),
        FoodTemplate(name: "速冻饺子", category: .frozen, storageZone: .freezer, customIcon: "🥟", defaultShelfLifeDays: 60, quantity: nil, notes: nil, purchaseDate: nil)
    ]

    static func fromHistory(_ items: [FoodItem]) -> [FoodTemplate] {
        var seen = Set<String>()
        return items.compactMap { item in
            let key = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !seen.contains(key) else { return nil }
            seen.insert(key)

            return FoodTemplate(
                name: item.name,
                category: item.category,
                storageZone: item.storageZone,
                customIcon: item.customIcon,
                defaultShelfLifeDays: item.shelfLifeDaysEstimate,
                quantity: item.quantity,
                notes: item.notes,
                purchaseDate: item.purchaseDate
            )
        }
    }
}
