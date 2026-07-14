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
        typealias DatedTemplate = (template: FoodTemplate, date: Date)
        var newestByName: [String: DatedTemplate] = [:]
        newestByName.reserveCapacity(items.count + records.count)

        func keepIfNewest(_ candidate: DatedTemplate) {
            let key = candidate.template.normalizedName
            guard !key.isEmpty else { return }
            guard newestByName[key].map({ candidate.date > $0.date }) ?? true else { return }
            newestByName[key] = candidate
        }

        for item in items {
            keepIfNewest((
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
            ))
        }

        for record in records {
            keepIfNewest((
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
            ))
        }

        // 去重由字典线性完成；这里只对唯一名称排序，避免先对全部历史做 O(N log N) 排序。
        return newestByName.values
            .sorted { lhs, rhs in
                if lhs.date != rhs.date { return lhs.date > rhs.date }
                return lhs.template.normalizedName.localizedCompare(rhs.template.normalizedName) == .orderedAscending
            }
            .map(\.template)
    }
}
