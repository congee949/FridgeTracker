import Foundation
import SwiftData
import WidgetKit
import os

@MainActor
enum WidgetDataStore {
    private static let logger = Logger(subsystem: "com.congee.FridgeTracker", category: "WidgetDataStore")

    /// 设置页「小组件数据同步」状态行读这两个键；仅 app 进程内使用，不需要进 App Group。
    static let lastSyncTimestampKey = "widgetLastSyncTimestamp"
    static let lastSyncErrorKey = "widgetLastSyncError"

    private static var pendingRefresh: Task<Void, Never>?

    /// UI 测试用 -uitesting 启动内存假数据库；快照文件和同步状态却是真实共享容器，
    /// 必须在这里短路，否则跑一遍 UI 测试会把测试数据写上桌面小组件。
    private static let isUITesting = ProcessInfo.processInfo.arguments.contains("-uitesting")

    static func refresh(using modelContext: ModelContext) {
        guard !isUITesting else { return }
        // 只在有未保存变更时 save：refresh 自身不再触发 didSave，避免「保存→观察→刷新→保存」自激
        if modelContext.hasChanges {
            try? modelContext.save()
        }
        let descriptor = FetchDescriptor<FoodItem>(sortBy: [SortDescriptor(\FoodItem.expiryDate)])
        let items: [FoodItem]
        do {
            items = try modelContext.fetch(descriptor)
        } catch {
            // 三条失败路径（容器缺失/读库失败/写文件失败）都要进状态，否则设置页会停留在「同步正常」假象
            recordSyncFailure("读取食材数据失败：\(error.localizedDescription)")
            return
        }
        write(items: items)
    }

    /// 写后投影的兜底入口：ModelContext.didSave 每次保存都会触发，短窗口内合并，
    /// 避免导入等批量写入时反复整写快照。显式调用 refresh 的即时路径不受影响。
    static func scheduleRefresh(using modelContext: ModelContext) {
        guard !isUITesting else { return }
        pendingRefresh?.cancel()
        pendingRefresh = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            refresh(using: modelContext)
        }
    }

    private static func write(items: [FoodItem]) {
        guard let url = FileManager.default.expiringFoodsSnapshotURL else {
            recordSyncFailure("App Group 容器不可用，无法写入小组件数据")
            return
        }

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
            recordSyncSuccess()
        } catch {
            recordSyncFailure("写入小组件快照失败：\(error.localizedDescription)")
        }
    }

    static func recordSyncSuccess(defaults: UserDefaults = .standard, now: Date = Date()) {
        defaults.set(now.timeIntervalSince1970, forKey: lastSyncTimestampKey)
        defaults.removeObject(forKey: lastSyncErrorKey)
    }

    /// 失败只写错误信息，保留上一次成功时间戳（用户仍需要知道最后一次同步成功是什么时候）。
    static func recordSyncFailure(_ message: String, defaults: UserDefaults = .standard) {
        logger.error("\(message, privacy: .public)")
        defaults.set(message, forKey: lastSyncErrorKey)
    }

    /// 设置页状态行的展示规则：错误优先于成功时间；从未同步过显示「尚未同步」。
    static func syncStatusText(error: String, timestamp: TimeInterval) -> String {
        if !error.isEmpty { return error }
        guard timestamp > 0 else { return "尚未同步" }
        return Date(timeIntervalSince1970: timestamp).formatted(date: .abbreviated, time: .shortened)
    }
}
