import Foundation
import SwiftData
import WidgetKit
import os

@MainActor
enum WidgetDataStore {
    private static let logger = Logger(subsystem: "com.congee.FridgeTracker", category: "WidgetDataStore")

    static func refresh(using modelContext: ModelContext) {
        try? modelContext.save()
        let descriptor = FetchDescriptor<FoodItem>(sortBy: [SortDescriptor(\FoodItem.expiryDate)])
        guard let items = try? modelContext.fetch(descriptor) else { return }
        write(items: items)
    }

    private static func write(items: [FoodItem]) {
        guard let url = FileManager.default.expiringFoodsSnapshotURL else { return }

        // 小组件定位是「快过期提醒」：只放 30 天内到期的，过期超过 14 天的也不再占位
        let snapshots = items
            .filter { (-14...30).contains($0.daysUntilExpiry) }
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
            logger.error("写入小组件快照失败：\(error.localizedDescription, privacy: .public)")
        }
    }
}
