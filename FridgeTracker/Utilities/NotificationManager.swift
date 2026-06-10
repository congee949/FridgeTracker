import UIKit
import UserNotifications

class NotificationManager {
    static let shared = NotificationManager()

    private init() {}

    // MARK: - 权限

    /// 已授权（含 provisional/ephemeral）直接返回 true；notDetermined 时弹出系统授权框。
    /// 已拒绝时返回 false，不会重复打扰。
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

    // MARK: - 调度

    /// 每个食材最多两段提醒：提前 N 天 9:00 + 到期日当天 9:00。
    /// 两个时点都已错过且尚未过期时，仅在 allowsImmediateFallback（新添加场景）下补发一条即时提醒，
    /// 避免编辑、批量重排时对同一食材重复打扰。
    func scheduleNotification(for item: FoodItem, daysBefore: Int? = nil, allowsImmediateFallback: Bool = false) {
        guard UserDefaults.standard.object(forKey: "notificationsEnabled") as? Bool ?? true else { return }

        let lead = daysBefore ?? reminderDaysBefore(for: item)
        let now = Date()
        var scheduled = false

        if lead > 0,
           let advanceDate = reminderDate(byAdding: -lead, to: item.expiryDate),
           advanceDate > now {
            add(
                identifier: Self.advanceIdentifier(for: item),
                title: "食材即将过期",
                body: "\(item.name) 将在 \(lead) 天后过期",
                trigger: calendarTrigger(for: advanceDate),
                uuid: item.uuid
            )
            scheduled = true
        }

        if let expiryMorning = reminderDate(byAdding: 0, to: item.expiryDate),
           expiryMorning > now {
            add(
                identifier: Self.expiryIdentifier(for: item),
                title: "食材今天过期",
                body: "\(item.name) 今天过期，记得尽快处理",
                trigger: calendarTrigger(for: expiryMorning),
                uuid: item.uuid
            )
            scheduled = true
        }

        if !scheduled, allowsImmediateFallback, item.daysUntilExpiry >= 0 {
            let isToday = item.daysUntilExpiry == 0
            add(
                identifier: Self.expiryIdentifier(for: item),
                title: isToday ? "食材今天过期" : "食材即将过期",
                body: isToday ? "\(item.name) 今天过期，记得尽快处理" : "\(item.name) 将在 \(item.daysUntilExpiry) 天后过期",
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 60, repeats: false),
                uuid: item.uuid
            )
        }
    }

    func cancelNotification(for item: FoodItem) {
        // 同时清理旧版本使用的裸 uuid 标识符
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [
            item.uuid.uuidString,
            Self.advanceIdentifier(for: item),
            Self.expiryIdentifier(for: item)
        ])
    }

    /// 只清理本 App 的食材提醒（含已删除食材的孤儿通知），不动其他类型的待发通知。
    @MainActor
    func rescheduleAll(for items: [FoodItem]) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let ours = pending.map(\.identifier).filter(Self.isFoodReminderIdentifier)
        center.removePendingNotificationRequests(withIdentifiers: ours)
        for item in items {
            scheduleNotification(for: item)
        }
    }

    // MARK: - 标识符

    static func advanceIdentifier(for item: FoodItem) -> String { item.uuid.uuidString + ".advance" }
    static func expiryIdentifier(for item: FoodItem) -> String { item.uuid.uuidString + ".expiry" }

    static func isFoodReminderIdentifier(_ identifier: String) -> Bool {
        let uuidPart = identifier.split(separator: ".", maxSplits: 1).first.map(String.init) ?? identifier
        return UUID(uuidString: uuidPart) != nil
    }

    // MARK: - Private

    private func add(identifier: String, title: String, body: String, trigger: UNNotificationTrigger, uuid: UUID) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["foodUUID": uuid.uuidString]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
    }

    private func calendarTrigger(for date: Date) -> UNCalendarNotificationTrigger {
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
    }

    private func reminderDate(byAdding offsetDays: Int, to expiryDate: Date) -> Date? {
        guard let baseDate = Calendar.current.date(byAdding: .day, value: offsetDays, to: expiryDate) else { return nil }
        var components = Calendar.current.dateComponents([.year, .month, .day], from: baseDate)
        components.hour = 9
        components.minute = 0
        return Calendar.current.date(from: components)
    }

    private func reminderDaysBefore(for item: FoodItem) -> Int {
        let storedValue = UserDefaults.standard.object(forKey: "reminderDaysBefore") as? Int
        if let storedValue, storedValue >= 0 { return storedValue }

        switch item.category {
        case .meat, .seafood:
            return 2
        case .frozen:
            return 7
        case .dairy, .egg, .vegetable, .fruit, .beverage, .condiment, .snack, .baking, .other:
            return 1
        }
    }
}

/// 前台展示横幅 + 点击通知深链到对应食材详情。
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
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
