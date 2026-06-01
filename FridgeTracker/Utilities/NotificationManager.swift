import UserNotifications

class NotificationManager {
    static let shared = NotificationManager()

    private init() {}

    func requestPermission() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
        } catch {
            return false
        }
    }

    func scheduleNotification(for item: FoodItem, daysBefore: Int? = nil) {
        guard UserDefaults.standard.object(forKey: "notificationsEnabled") as? Bool ?? true else { return }

        let daysBefore = daysBefore ?? reminderDaysBefore(for: item)
        guard let triggerDate = Calendar.current.date(byAdding: .day, value: -daysBefore, to: item.expiryDate), triggerDate > Date() else { return }

        let content = UNMutableNotificationContent()
        content.title = item.daysUntilExpiry < 0 ? "食材已过期" : "食材即将过期"
        content.body = daysBefore == 0 ? "\(item.name) 今天过期" : "\(item.name) 将在 \(daysBefore) 天后过期"
        content.sound = .default

        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: triggerDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(identifier: item.uuid.uuidString, content: content, trigger: trigger)

        UNUserNotificationCenter.current().add(request)
    }

    func cancelNotification(for item: FoodItem) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [item.uuid.uuidString])
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
