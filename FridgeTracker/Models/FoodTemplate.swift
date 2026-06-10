import Foundation

struct FoodTemplate: Identifiable {
    // 以名称为身份，避免每次重新生成模板时 List/ForEach 全量刷新
    var id: String { normalizedName }
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

    /// 聚合当前库存与吃掉/扔掉记录生成历史模板：同名取时间最新的一条，
    /// 因此吃完下架的食材依然保留在历史建议里，且结果与调用方的查询排序无关。
    static func fromHistory(_ items: [FoodItem], records: [FoodDispositionRecord] = []) -> [FoodTemplate] {
        var candidates: [(template: FoodTemplate, date: Date)] = items.map { item in
            (
                FoodTemplate(
                    name: item.name,
                    category: item.category,
                    storageZone: item.storageZone,
                    customIcon: item.customIcon,
                    defaultShelfLifeDays: item.shelfLifeDaysEstimate,
                    quantity: item.quantity,
                    notes: item.notes,
                    purchaseDate: item.purchaseDate
                ),
                item.createdAt
            )
        }
        candidates.append(contentsOf: records.map { record in
            (
                FoodTemplate(
                    name: record.foodName,
                    category: record.category,
                    storageZone: record.storageZone,
                    customIcon: record.customIcon,
                    defaultShelfLifeDays: max(record.shelfLifeDaysEstimate, 1),
                    quantity: record.quantity,
                    notes: nil,
                    purchaseDate: record.purchaseDate
                ),
                record.createdAt
            )
        })

        var seen = Set<String>()
        return candidates
            .sorted { $0.date > $1.date }
            .compactMap { candidate in
                let key = candidate.template.normalizedName
                guard !key.isEmpty, !seen.contains(key) else { return nil }
                seen.insert(key)
                return candidate.template
            }
    }
}
