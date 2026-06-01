import Foundation
import SwiftData
import WidgetKit

@MainActor
enum WidgetDataStore {
    static func refresh(using modelContext: ModelContext) {
        try? modelContext.save()
        let descriptor = FetchDescriptor<FoodItem>(sortBy: [SortDescriptor(\FoodItem.expiryDate)])
        guard let items = try? modelContext.fetch(descriptor) else { return }
        write(items: items)
    }

    private static func write(items: [FoodItem]) {
        guard let url = FileManager.default.expiringFoodsSnapshotURL else { return }

        let snapshots = items
            .sorted { $0.expiryDate < $1.expiryDate }
            .prefix(50)
            .map { item in
                ExpiringFoodSnapshot(
                    id: item.uuid,
                    name: item.name,
                    category: item.category.rawValue,
                    categoryIcon: item.category.icon,
                    displayIcon: item.displayIcon,
                    storageZone: item.storageZone.rawValue,
                    storageIcon: item.storageZone.icon,
                    expiryDate: item.expiryDate,
                    daysUntilExpiry: item.daysUntilExpiry
                )
            }

        do {
            let data = try JSONEncoder.expiringFoods.encode(Array(snapshots))
            try data.write(to: url, options: [.atomic])
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
        }
    }
}
