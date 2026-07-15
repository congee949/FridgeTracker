import Foundation
import SwiftData
import UIKit
import WidgetKit
import os

@MainActor
enum WidgetDataStore {
    private static let logger = Logger(subsystem: "com.congee.FridgeTracker", category: "WidgetDataStore")

    /// 设置页「小组件数据同步」状态行读这两个键；仅 app 进程内使用，不需要进 App Group。
    static let lastSyncTimestampKey = "widgetLastSyncTimestamp"
    static let lastSyncErrorKey = "widgetLastSyncError"
    static let pendingChangesError = "存在未提交的数据变更，已跳过小组件刷新"
    nonisolated static let maximumSnapshotSize = 10 * 1_024 * 1_024

    private static var pendingRefresh: Task<Void, Never>?
    private static var writeGeneration = 0
    private static let writeQueue = DispatchQueue(
        label: "com.congee.FridgeTracker.widget-snapshot",
        qos: .utility
    )

    static func refresh(using modelContext: ModelContext) {
        // XCTest 的宿主仍拥有正式 App Group entitlement。若不短路，单元测试启动时的空
        // 内存数据库会把用户/模拟器的真实 Widget 快照覆盖成空数组。
        guard !AppRuntime.isAutomatedTest() else { return }
        // 投影层只读已提交的主数据，绝不代替业务命令保存或吞掉保存错误。
        // 写入方必须先显式 `modelContext.save()`，成功后才能调用 refresh。
        guard refreshValidationError(hasPendingChanges: modelContext.hasChanges) == nil else {
            recordSyncFailure(pendingChangesError)
            return
        }
        let descriptor = FetchDescriptor<FoodItem>()
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
        guard !AppRuntime.isAutomatedTest() else { return }
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

        // 快照是当前库存的完整最小投影。日期窗口与分类必须由 Widget 在每次 timeline
        // 生成时按“今天”计算，否则长期不打开 App 时 31→30 天的食材永远进不了快照。
        let snapshots = items
            .map { item in
                ExpiringFoodSnapshot(
                    id: item.uuid,
                    name: item.name,
                    category: item.category.rawValue,
                    categoryIcon: item.category.icon,
                    displayIcon: item.displayIcon,
                    storageZone: item.storageZone.rawValue,
                    storageIcon: item.storageZone.icon,
                    expiryDate: item.expiryLocalDate.date() ?? item.expiryDate,
                    daysUntilExpiry: item.daysUntilExpiry,
                    categoryID: item.stableCategoryID,
                    expiryDayKey: item.expiryLocalDate
                )
            }

        writeGeneration += 1
        let generation = writeGeneration
        // Saving food and immediately returning to the Home Screen is the normal path. Protect
        // the tiny projection write from app suspension so the Widget never races a half-finished
        // refresh. The task is ended on MainActor after the serial writer finishes.
        let backgroundTask = UIApplication.shared.beginBackgroundTask(
            withName: "Refresh FridgeTracker Widget",
            expirationHandler: nil
        )
        writeQueue.async {
            let errorMessage: String?
            do {
                let data = try JSONEncoder.expiringFoods.encode(ExpiringFoodSnapshotEnvelope(items: snapshots))
                if let sizeError = snapshotSizeError(byteCount: data.count) {
                    errorMessage = sizeError
                } else {
                    // Widget may refresh while the phone is locked. Keep the shared projection
                    // available after the first unlock while retaining atomic cross-process reads.
                    try data.write(
                        to: url,
                        options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
                    )
                    errorMessage = nil
                }
            } catch {
                errorMessage = "写入小组件快照失败：\(error.localizedDescription)"
            }
            Task { @MainActor in
                if backgroundTask != .invalid {
                    UIApplication.shared.endBackgroundTask(backgroundTask)
                }
                guard generation == writeGeneration else { return }
                if let errorMessage {
                    recordSyncFailure(errorMessage)
                } else {
                    WidgetCenter.shared.reloadTimelines(ofKind: fridgeTrackerWidgetKind)
                    recordSyncSuccess()
                }
            }
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

    static func refreshValidationError(hasPendingChanges: Bool) -> String? {
        hasPendingChanges ? pendingChangesError : nil
    }

    nonisolated static func snapshotSizeError(byteCount: Int) -> String? {
        guard byteCount > maximumSnapshotSize else { return nil }
        return "小组件快照过大（\(byteCount / 1_024 / 1_024) MiB），已保留上一次有效数据"
    }
}
