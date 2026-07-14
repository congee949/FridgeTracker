import SwiftData
import UIKit
import UserNotifications

struct FoodReminderCandidate: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case expiry
        case advance

        /// 同一触发时刻优先保留“当天过期”，再保留提前提醒。
        var budgetPriority: Int { self == .expiry ? 0 : 1 }
    }

    let identifier: String
    let foodID: UUID
    let kind: Kind
    let fireDate: Date
    let title: String
    let body: String
    let trigger: ReminderTrigger
}

struct FoodReminderPlan: Equatable, Sendable {
    let candidates: [FoodReminderCandidate]
    let desiredCount: Int

    var overflowCount: Int { max(desiredCount - candidates.count, 0) }
}

struct NotificationSchedulingSummary: Equatable, Sendable {
    let desiredCount: Int
    let scheduledCount: Int
    let overflowCount: Int
    let failedCount: Int
}

/// Reconciliation must sometimes make room before adding. The system only keeps 64 pending
/// local notifications, so a completely disjoint 60 -> 60 replacement cannot be implemented as
/// an unconditional "add everything, then delete stale" transaction.
struct FoodReminderReconciliationPreflight: Equatable, Sendable {
    let identifiersToRemoveBeforeAdding: [String]
    let staleManagedIdentifiers: [String]
    let missingDesiredIdentifiers: [String]
}

/// `UNUserNotificationCenter.add` completing without an error is not proof that the daemon kept
/// the request. Success is based on a fresh pending-request snapshot, with callback failures kept
/// separately so a failed update of an already-present identifier is still visible.
struct FoodReminderReconciliationVerification: Equatable, Sendable {
    let scheduledCount: Int
    let failedIdentifiers: [String]

    var isSuccessful: Bool { failedIdentifiers.isEmpty }
}

/// Thread-safe claim gate shared by notification-center callbacks and their timeout fallback.
/// `UNUserNotificationCenter` callbacks are not guaranteed to arrive, and may also arrive after
/// the timeout has already resumed the continuation.
final class NotificationOneShotGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isClaimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isClaimed else { return false }
        isClaimed = true
        return true
    }
}

/// 所有调度入口统一在主线程读取 SwiftData，再把 Sendable 值投递给通知中心队列。
@MainActor
final class NotificationManager {
    static let shared = NotificationManager()
    static let schedulingLimit = 60
    nonisolated static let systemPendingLimit = 64
    nonisolated static let notificationCenterTimeout: TimeInterval = 10

    static let desiredCountKey = "notificationDesiredCount"
    static let scheduledCountKey = "notificationScheduledCount"
    static let overflowCountKey = "notificationOverflowCount"
    static let lastSchedulingTimestampKey = "notificationLastSchedulingTimestamp"
    static let lastSchedulingErrorKey = "notificationLastSchedulingError"

    private init() {}

    /// 新一轮 reconciliation 会令仍挂在 await 上的旧轮作废，避免旧库存覆盖新库存。
    private var rescheduleGeneration = 0

    /// usernotificationsd 在授权弹窗待决时可能阻塞同步 XPC；所有 add/remove 均留在 utility 队列。
    private static let centerQueue = DispatchQueue(label: "com.congee.FridgeTracker.notification-center", qos: .utility)

    // MARK: - 权限

    func requestPermission() async -> Bool {
        let center = UNUserNotificationCenter.current()
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        default:
            return false
        }
    }

    func isAuthorized() async -> Bool {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        return status == .authorized || status == .provisional || status == .ephemeral
    }

    func isDenied() async -> Bool {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .denied
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    // MARK: - Reconciliation

    /// 从数据库读取失败不会被解释成“库存为空”；旧通知保持不动并记录可见错误。
    func reconcile(using modelContext: ModelContext, immediateFallbackItemID: UUID? = nil) async {
        guard !modelContext.hasChanges else {
            Self.recordSchedulingFailure(
                "存在未提交的数据变更，已跳过提醒重排",
                summary: NotificationSchedulingSummary(
                    desiredCount: 0,
                    scheduledCount: 0,
                    overflowCount: 0,
                    failedCount: 1
                )
            )
            return
        }
        let items: [FoodItem]
        do {
            items = try modelContext.fetch(FetchDescriptor<FoodItem>())
        } catch {
            Self.recordSchedulingFailure(
                "读取食材失败，已保留原提醒：\(error.localizedDescription)",
                summary: NotificationSchedulingSummary(desiredCount: 0, scheduledCount: 0, overflowCount: 0, failedCount: 1)
            )
            return
        }
        await rescheduleAll(for: items, immediateFallbackItemID: immediateFallbackItemID)
    }

    /// 先安全清理孤儿提醒并在必要时为新 ID 腾出系统槽位，再 upsert 最近 60 个目标事件。
    /// add 后以 pending 快照核验；只有全部目标都确实存在且没有 add 错误，才清理其余 stale。
    func rescheduleAll(
        for items: [FoodItem],
        immediateFallbackItemID: UUID? = nil,
        defaults: UserDefaults = .standard,
        now: Date = Date()
    ) async {
        rescheduleGeneration += 1
        let generation = rescheduleGeneration
        let notificationsEnabled = defaults.object(forKey: "notificationsEnabled") as? Bool ?? true

        if !notificationsEnabled {
            let didReadPending = await removeAllManagedReminders(generation: generation)
            guard generation == rescheduleGeneration else { return }
            guard didReadPending else {
                Self.recordSchedulingFailure(
                    "读取系统待发提醒超时（10 秒），将在下次重试",
                    summary: NotificationSchedulingSummary(
                        desiredCount: 0,
                        scheduledCount: 0,
                        overflowCount: 0,
                        failedCount: 1
                    ),
                    defaults: defaults,
                    now: now
                )
                return
            }
            Self.recordSchedulingSuccess(
                NotificationSchedulingSummary(desiredCount: 0, scheduledCount: 0, overflowCount: 0, failedCount: 0),
                defaults: defaults,
                now: now
            )
            return
        }

        let storedLead = defaults.object(forKey: "reminderDaysBefore") as? Int
        let leadOverride = storedLead.flatMap { $0 >= 0 ? $0 : nil }
        let liveItems = items.filter { $0.modelContext != nil && !$0.isDeleted }
        let plan = Self.planReminders(
            for: liveItems,
            now: now,
            daysBeforeOverride: leadOverride,
            immediateFallbackItemID: immediateFallbackItemID,
            limit: Self.schedulingLimit
        )

        guard await isAuthorized() else {
            guard generation == rescheduleGeneration else { return }
            Self.recordSchedulingFailure(
                "系统通知未授权，已保留原提醒",
                summary: NotificationSchedulingSummary(
                    desiredCount: plan.desiredCount,
                    scheduledCount: 0,
                    overflowCount: plan.overflowCount,
                    failedCount: plan.candidates.count
                ),
                defaults: defaults,
                now: now
            )
            return
        }
        guard generation == rescheduleGeneration else { return }

        let desiredIdentifiers = Set(plan.candidates.map(\.identifier))
        let liveFoodIDs = Set(liveItems.map(\.uuid))
        guard let pendingBeforeAdds = await pendingRequestIdentifiers() else {
            guard generation == rescheduleGeneration else { return }
            Self.recordSchedulingFailure(
                "读取系统待发提醒超时（10 秒），已保留现有提醒，将在下次重试",
                summary: NotificationSchedulingSummary(
                    desiredCount: plan.desiredCount,
                    scheduledCount: 0,
                    overflowCount: plan.overflowCount,
                    failedCount: max(plan.candidates.count, 1)
                ),
                defaults: defaults,
                now: now
            )
            return
        }
        guard generation == rescheduleGeneration else { return }
        let preflight = Self.reconciliationPreflight(
            pendingIdentifiers: pendingBeforeAdds,
            desiredIdentifiers: desiredIdentifiers,
            liveFoodIDs: liveFoodIDs,
            systemLimit: Self.systemPendingLimit
        )
        await removePendingNotificationRequests(withIdentifiers: preflight.identifiersToRemoveBeforeAdding)
        guard generation == rescheduleGeneration else { return }

        // removePendingNotificationRequests has no completion callback. Re-read before adding so
        // a delayed/no-op daemon removal cannot leave us colliding with the 64-request ceiling.
        guard let pendingAfterPreRemoval = await pendingRequestIdentifiers() else {
            guard generation == rescheduleGeneration else { return }
            Self.recordSchedulingFailure(
                "核验旧提醒清理结果超时（10 秒），暂未添加新提醒，将在下次重试",
                summary: NotificationSchedulingSummary(
                    desiredCount: plan.desiredCount,
                    scheduledCount: 0,
                    overflowCount: plan.overflowCount,
                    failedCount: max(preflight.identifiersToRemoveBeforeAdding.count, 1)
                ),
                defaults: defaults,
                now: now
            )
            return
        }
        guard generation == rescheduleGeneration else { return }
        let preRemovalFailures = Self.identifiersStillPending(
            expectedRemovedIdentifiers: Set(preflight.identifiersToRemoveBeforeAdding),
            pendingIdentifiers: pendingAfterPreRemoval
        )
        guard preRemovalFailures.isEmpty else {
            let scheduledCount = desiredIdentifiers.intersection(Set(pendingAfterPreRemoval)).count
            Self.recordSchedulingFailure(
                "旧提醒清理尚未生效，暂未添加新提醒，将在下次重试",
                summary: NotificationSchedulingSummary(
                    desiredCount: plan.desiredCount,
                    scheduledCount: scheduledCount,
                    overflowCount: plan.overflowCount,
                    failedCount: preRemovalFailures.count
                ),
                defaults: defaults,
                now: now
            )
            return
        }

        var addFailureMessages: [String: String] = [:]
        for candidate in plan.candidates {
            if let error = await add(candidate) {
                addFailureMessages[candidate.identifier] = error
            }
            guard generation == rescheduleGeneration else { return }
        }

        // Do not trust callback success alone. usernotificationsd may silently drop a request,
        // especially around its pending-request limit, process restarts, or daemon failures.
        guard let pendingAfterAdds = await pendingRequestIdentifiers() else {
            guard generation == rescheduleGeneration else { return }
            Self.recordSchedulingFailure(
                "核验已安排提醒超时（10 秒），无法确认结果，将在下次重试",
                summary: NotificationSchedulingSummary(
                    desiredCount: plan.desiredCount,
                    scheduledCount: 0,
                    overflowCount: plan.overflowCount,
                    failedCount: max(plan.candidates.count, 1)
                ),
                defaults: defaults,
                now: now
            )
            return
        }
        guard generation == rescheduleGeneration else { return }
        let verification = Self.verifyReconciliation(
            desiredIdentifiers: desiredIdentifiers,
            pendingIdentifiers: pendingAfterAdds,
            addFailedIdentifiers: Set(addFailureMessages.keys)
        )
        let summary = NotificationSchedulingSummary(
            desiredCount: plan.desiredCount,
            scheduledCount: verification.scheduledCount,
            overflowCount: plan.overflowCount,
            failedCount: verification.failedIdentifiers.count
        )

        guard verification.isSuccessful else {
            let message: String
            if let firstFailureID = verification.failedIdentifiers.first,
               let addError = addFailureMessages[firstFailureID] {
                let suffix = verification.failedIdentifiers.count > 1
                    ? "（共 \(verification.failedIdentifiers.count) 条失败）"
                    : ""
                message = "提醒安排失败，将在下次重试：\(addError)\(suffix)"
            } else {
                message = "系统未保留 \(verification.failedIdentifiers.count) 条提醒，将在下次重试"
            }
            Self.recordSchedulingFailure(
                message,
                summary: summary,
                defaults: defaults,
                now: now
            )
            return
        }

        // add 与 pending 核验全部成功后，清掉余下的不在目标集合中的新/旧命名空间请求。
        let staleIdentifiers = pendingAfterAdds.filter {
            Self.isManagedFoodReminderIdentifier($0) && !desiredIdentifiers.contains($0)
        }
        await removePendingNotificationRequests(withIdentifiers: staleIdentifiers)
        guard generation == rescheduleGeneration else { return }

        // The final void removal is verified too: otherwise status could claim convergence while
        // stale managed requests still consume slots. Recheck desired IDs at the same time.
        guard let finalPending = await pendingRequestIdentifiers() else {
            guard generation == rescheduleGeneration else { return }
            Self.recordSchedulingFailure(
                "核验最终提醒状态超时（10 秒），将在下次重试",
                summary: NotificationSchedulingSummary(
                    desiredCount: plan.desiredCount,
                    scheduledCount: verification.scheduledCount,
                    overflowCount: plan.overflowCount,
                    failedCount: 1
                ),
                defaults: defaults,
                now: now
            )
            return
        }
        guard generation == rescheduleGeneration else { return }
        let finalVerification = Self.verifyReconciliation(
            desiredIdentifiers: desiredIdentifiers,
            pendingIdentifiers: finalPending,
            addFailedIdentifiers: []
        )
        let remainingStale = Self.staleManagedIdentifiers(
            pendingIdentifiers: finalPending,
            desiredIdentifiers: desiredIdentifiers
        )
        let finalSummary = NotificationSchedulingSummary(
            desiredCount: plan.desiredCount,
            scheduledCount: finalVerification.scheduledCount,
            overflowCount: plan.overflowCount,
            failedCount: finalVerification.failedIdentifiers.count + remainingStale.count
        )
        guard finalVerification.isSuccessful, remainingStale.isEmpty else {
            let message = finalVerification.isSuccessful
                ? "旧提醒清理尚未生效，将在下次重试"
                : "系统未保留 \(finalVerification.failedIdentifiers.count) 条提醒，将在下次重试"
            Self.recordSchedulingFailure(message, summary: finalSummary, defaults: defaults, now: now)
            return
        }
        Self.recordSchedulingSuccess(finalSummary, defaults: defaults, now: now)
    }

    /// 删除单项时可立即清理其新旧标识符；其他变更统一走全量 reconciliation 以维持 60 条预算。
    func cancelNotification(for item: FoodItem) {
        let uuid = item.uuid
        let identifiers = [
            Self.advanceIdentifier(for: uuid),
            Self.expiryIdentifier(for: uuid),
            uuid.uuidString,
            uuid.uuidString + ".advance",
            uuid.uuidString + ".expiry"
        ]
        Self.centerQueue.async {
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
        }
    }

    // MARK: - Pure planning

    static func planReminders(
        for items: [FoodItem],
        now: Date,
        daysBeforeOverride: Int? = nil,
        immediateFallbackItemID: UUID? = nil,
        limit: Int = 60,
        calendar: Calendar = .current
    ) -> FoodReminderPlan {
        let boundedLimit = max(limit, 0)
        var nearestCandidates: [FoodReminderCandidate] = []
        var desiredCount = 0

        func isEarlier(_ lhs: FoodReminderCandidate, _ rhs: FoodReminderCandidate) -> Bool {
            if lhs.fireDate != rhs.fireDate { return lhs.fireDate < rhs.fireDate }
            if lhs.kind.budgetPriority != rhs.kind.budgetPriority {
                return lhs.kind.budgetPriority < rhs.kind.budgetPriority
            }
            return lhs.identifier < rhs.identifier
        }

        func consider(_ candidate: FoodReminderCandidate) {
            desiredCount += 1
            guard boundedLimit > 0 else { return }
            nearestCandidates.append(candidate)
            // Bound temporary memory to O(limit), rather than building/sorting 2N events for a
            // very large inventory. Periodic trimming preserves the globally nearest candidates.
            if nearestCandidates.count > max(boundedLimit * 2, boundedLimit + 1) {
                nearestCandidates.sort(by: isEarlier)
                nearestCandidates.removeSubrange(boundedLimit...)
            }
        }

        for item in items {
            let lead = daysBeforeOverride ?? reminderDaysBefore(for: item.category)
            var itemHasFutureReminder = false

            if lead > 0,
               let advanceDate = reminderDate(byAdding: -lead, to: item.expiryLocalDate, calendar: calendar),
               advanceDate > now {
                consider(FoodReminderCandidate(
                    identifier: advanceIdentifier(for: item.uuid),
                    foodID: item.uuid,
                    kind: .advance,
                    fireDate: advanceDate,
                    title: "食材即将过期",
                    body: "\(item.name) 将在 \(lead) 天后过期",
                    trigger: .calendar(reminderComponents(for: advanceDate, calendar: calendar))
                ))
                itemHasFutureReminder = true
            }

            if let expiryMorning = reminderDate(byAdding: 0, to: item.expiryLocalDate, calendar: calendar),
               expiryMorning > now {
                consider(FoodReminderCandidate(
                    identifier: expiryIdentifier(for: item.uuid),
                    foodID: item.uuid,
                    kind: .expiry,
                    fireDate: expiryMorning,
                    title: "食材今天过期",
                    body: "\(item.name) 今天过期，记得尽快处理",
                    trigger: .calendar(reminderComponents(for: expiryMorning, calendar: calendar))
                ))
                itemHasFutureReminder = true
            }

            let today = LocalDate(date: now, timeZone: calendar.timeZone)
            let daysUntilExpiry = today.days(until: item.expiryLocalDate)
            if !itemHasFutureReminder, immediateFallbackItemID == item.uuid, daysUntilExpiry >= 0 {
                let isToday = daysUntilExpiry == 0
                let fireDate = now.addingTimeInterval(60)
                consider(FoodReminderCandidate(
                    identifier: expiryIdentifier(for: item.uuid),
                    foodID: item.uuid,
                    kind: .expiry,
                    fireDate: fireDate,
                    title: isToday ? "食材今天过期" : "食材即将过期",
                    body: isToday ? "\(item.name) 今天过期，记得尽快处理" : "\(item.name) 将在 \(daysUntilExpiry) 天后过期",
                    trigger: .interval(60)
                ))
            }
        }

        nearestCandidates.sort(by: isEarlier)
        return FoodReminderPlan(
            candidates: Array(nearestCandidates.prefix(boundedLimit)),
            desiredCount: desiredCount
        )
    }

    /// Pure capacity/safety planning for the 64-request system limit.
    ///
    /// - Orphans whose food no longer exists are always safe to delete before adding.
    /// - If that is not enough, only stale identifiers owned by this food-reminder namespace are
    ///   removed, and only as many as are necessary to fit missing desired IDs.
    /// - Unrecognized notifications are counted against capacity but never selected for removal.
    static func reconciliationPreflight(
        pendingIdentifiers: [String],
        desiredIdentifiers: Set<String>,
        liveFoodIDs: Set<UUID>,
        systemLimit: Int = systemPendingLimit
    ) -> FoodReminderReconciliationPreflight {
        let pending = Set(pendingIdentifiers)
        let missingDesired = desiredIdentifiers.subtracting(pending).sorted()
        let staleManaged = pending.filter {
            isManagedFoodReminderIdentifier($0) && !desiredIdentifiers.contains($0)
        }

        let deadFoodIdentifiers = staleManaged.filter { identifier in
            guard let foodID = foodID(fromManagedReminderIdentifier: identifier) else { return false }
            return !liveFoodIDs.contains(foodID)
        }.sorted()
        let deadFoodSet = Set(deadFoodIdentifiers)

        let remainingStale = staleManaged.filter { !deadFoodSet.contains($0) }.sorted { lhs, rhs in
            let lhsIsLegacy = isLegacyFoodReminderIdentifier(lhs)
            let rhsIsLegacy = isLegacyFoodReminderIdentifier(rhs)
            if lhsIsLegacy != rhsIsLegacy { return lhsIsLegacy }
            return lhs < rhs
        }

        let boundedSystemLimit = max(systemLimit, 0)
        let pendingCountAfterDeadRemoval = max(pending.count - deadFoodIdentifiers.count, 0)
        let availableSlots = max(boundedSystemLimit - pendingCountAfterDeadRemoval, 0)
        let additionalSlotsNeeded = max(missingDesired.count - availableSlots, 0)
        let capacityRemovals = Array(remainingStale.prefix(additionalSlotsNeeded))

        return FoodReminderReconciliationPreflight(
            identifiersToRemoveBeforeAdding: deadFoodIdentifiers + capacityRemovals,
            staleManagedIdentifiers: staleManaged.sorted(),
            missingDesiredIdentifiers: missingDesired
        )
    }

    static func verifyReconciliation(
        desiredIdentifiers: Set<String>,
        pendingIdentifiers: [String],
        addFailedIdentifiers: Set<String>
    ) -> FoodReminderReconciliationVerification {
        let pending = Set(pendingIdentifiers)
        let missing = desiredIdentifiers.subtracting(pending)
        let failed = missing.union(addFailedIdentifiers.intersection(desiredIdentifiers))
        return FoodReminderReconciliationVerification(
            scheduledCount: desiredIdentifiers.intersection(pending).count,
            failedIdentifiers: failed.sorted()
        )
    }

    static func identifiersStillPending(
        expectedRemovedIdentifiers: Set<String>,
        pendingIdentifiers: [String]
    ) -> [String] {
        expectedRemovedIdentifiers.intersection(Set(pendingIdentifiers)).sorted()
    }

    static func staleManagedIdentifiers(
        pendingIdentifiers: [String],
        desiredIdentifiers: Set<String>
    ) -> [String] {
        Set(pendingIdentifiers).filter {
            isManagedFoodReminderIdentifier($0) && !desiredIdentifiers.contains($0)
        }.sorted()
    }

    // MARK: - 标识符

    static func advanceIdentifier(for item: FoodItem) -> String { advanceIdentifier(for: item.uuid) }
    static func expiryIdentifier(for item: FoodItem) -> String { expiryIdentifier(for: item.uuid) }
    static func advanceIdentifier(for uuid: UUID) -> String { "food.\(uuid.uuidString).advance" }
    static func expiryIdentifier(for uuid: UUID) -> String { "food.\(uuid.uuidString).expiry" }

    /// 新命名空间严格限制为 `food.<uuid>.advance|expiry`，不会误删其他 UUID 前缀通知。
    static func isFoodReminderIdentifier(_ identifier: String) -> Bool {
        let parts = identifier.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "food", UUID(uuidString: String(parts[1])) != nil else {
            return false
        }
        return parts[2] == "advance" || parts[2] == "expiry"
    }

    static func isLegacyFoodReminderIdentifier(_ identifier: String) -> Bool {
        if UUID(uuidString: identifier) != nil { return true }
        let parts = identifier.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, UUID(uuidString: String(parts[0])) != nil else { return false }
        return parts[1] == "advance" || parts[1] == "expiry"
    }

    static func foodID(fromManagedReminderIdentifier identifier: String) -> UUID? {
        if isFoodReminderIdentifier(identifier) {
            let parts = identifier.split(separator: ".", omittingEmptySubsequences: false)
            return UUID(uuidString: String(parts[1]))
        }
        if UUID(uuidString: identifier) != nil {
            return UUID(uuidString: identifier)
        }
        guard isLegacyFoodReminderIdentifier(identifier) else { return nil }
        let parts = identifier.split(separator: ".", omittingEmptySubsequences: false)
        return UUID(uuidString: String(parts[0]))
    }

    // MARK: - Observable status

    static func recordSchedulingSuccess(
        _ summary: NotificationSchedulingSummary,
        defaults: UserDefaults = .standard,
        now: Date = Date()
    ) {
        record(summary, error: nil, defaults: defaults, now: now)
    }

    static func recordSchedulingFailure(
        _ message: String,
        summary: NotificationSchedulingSummary,
        defaults: UserDefaults = .standard,
        now: Date = Date()
    ) {
        record(summary, error: message, defaults: defaults, now: now)
    }

    static func schedulingStatusText(desired: Int, scheduled: Int, overflow: Int, error: String) -> String {
        if !error.isEmpty { return error }
        guard desired > 0 else { return "暂无待安排提醒" }
        if overflow > 0 { return "已安排 \(scheduled) / 共 \(desired)，另有 \(overflow) 条等待重排" }
        return "已安排 \(scheduled) / \(desired)"
    }

    // MARK: - Notification center bridge

    /// Injectable callback/timeout race used by the notification-center bridges. The timeout is
    /// scheduled on an independent queue, so a stuck notification-center callback cannot prevent
    /// it from firing. The gate guarantees the checked continuation is resumed exactly once.
    nonisolated static func awaitOneShot<Value: Sendable>(
        timeout: TimeInterval,
        timeoutValue: Value,
        start: @Sendable (@escaping @Sendable (Value) -> Void) -> Void
    ) async -> Value {
        await withCheckedContinuation { continuation in
            let gate = NotificationOneShotGate()
            let finish: @Sendable (Value) -> Void = { value in
                guard gate.claim() else { return }
                continuation.resume(returning: value)
            }

            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + max(timeout, 0)
            ) {
                finish(timeoutValue)
            }
            start(finish)
        }
    }

    /// Returns nil only when usernotificationsd does not answer within the bounded interval.
    private func pendingRequestIdentifiers() async -> [String]? {
        let timeoutValue: [String]? = nil
        let queue = Self.centerQueue
        return await Self.awaitOneShot(
            timeout: Self.notificationCenterTimeout,
            timeoutValue: timeoutValue
        ) { finish in
            queue.async {
                UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
                    finish(requests.map(\.identifier))
                }
            }
        }
    }

    private func add(_ candidate: FoodReminderCandidate) async -> String? {
        let timeoutMessage: String? = "通知中心添加提醒超时（10 秒）"
        let queue = Self.centerQueue
        return await Self.awaitOneShot(
            timeout: Self.notificationCenterTimeout,
            timeoutValue: timeoutMessage
        ) { finish in
            queue.async {
                let content = UNMutableNotificationContent()
                content.title = candidate.title
                content.body = candidate.body
                content.sound = .default
                content.userInfo = ["foodUUID": candidate.foodID.uuidString]
                let request = UNNotificationRequest(
                    identifier: candidate.identifier,
                    content: content,
                    trigger: candidate.trigger.makeTrigger()
                )
                UNUserNotificationCenter.current().add(request) { error in
                    finish(error?.localizedDescription)
                }
            }
        }
    }

    private func removeAllManagedReminders(generation: Int) async -> Bool {
        guard let pending = await pendingRequestIdentifiers() else { return false }
        guard generation == rescheduleGeneration else { return true }
        await removePendingNotificationRequests(
            withIdentifiers: pending.filter(Self.isManagedFoodReminderIdentifier)
        )
        return true
    }

    private func removePendingNotificationRequests(withIdentifiers identifiers: [String]) async {
        guard !identifiers.isEmpty else { return }
        await withCheckedContinuation { continuation in
            Self.centerQueue.async {
                UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
                continuation.resume()
            }
        }
    }

    private static func isManagedFoodReminderIdentifier(_ identifier: String) -> Bool {
        isFoodReminderIdentifier(identifier) || isLegacyFoodReminderIdentifier(identifier)
    }

    private static func record(
        _ summary: NotificationSchedulingSummary,
        error: String?,
        defaults: UserDefaults,
        now: Date
    ) {
        defaults.set(summary.desiredCount, forKey: desiredCountKey)
        defaults.set(summary.scheduledCount, forKey: scheduledCountKey)
        defaults.set(summary.overflowCount, forKey: overflowCountKey)
        defaults.set(now.timeIntervalSince1970, forKey: lastSchedulingTimestampKey)
        if let error, !error.isEmpty {
            defaults.set(error, forKey: lastSchedulingErrorKey)
        } else {
            defaults.removeObject(forKey: lastSchedulingErrorKey)
        }
    }

    private static func reminderComponents(for date: Date, calendar: Calendar) -> DateComponents {
        calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    }

    private static func reminderDate(byAdding offsetDays: Int, to expiryDay: LocalDate, calendar: Calendar) -> Date? {
        expiryDay.adding(days: offsetDays)?.date(in: calendar.timeZone, hour: 9)
    }

    private static func reminderDaysBefore(for category: FoodCategory) -> Int {
        switch category {
        case .meat, .seafood:
            return 2
        case .frozen:
            return 7
        case .dairy, .egg, .vegetable, .fruit, .beverage, .condiment, .snack, .nut, .baking, .other:
            return 1
        }
    }
}

enum ReminderTrigger: Equatable, Sendable {
    case calendar(DateComponents)
    case interval(TimeInterval)

    func makeTrigger() -> UNNotificationTrigger {
        switch self {
        case .calendar(let components):
            return UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        case .interval(let seconds):
            return UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)
        }
    }
}

/// 前台展示横幅 + 点击通知深链到对应食材详情。
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NotificationDelegate()

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let uuidString = response.notification.request.content.userInfo["foodUUID"] as? String,
              let url = URL(string: "fridgetracker://food/\(uuidString)") else { return }
        await MainActor.run {
            UIApplication.shared.open(url)
        }
    }
}
