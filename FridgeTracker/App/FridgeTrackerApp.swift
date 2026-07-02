import SwiftUI
import SwiftData
import UIKit
import UserNotifications

@main
struct FridgeTrackerApp: App {
    init() {
        configureTabBarAppearance()
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(Self.makeModelContainer())
    }

    /// Production uses the default on-disk store. UI tests launch with `-uitesting` to get a clean,
    /// isolated in-memory store so they never read or mutate real user data.
    static func makeModelContainer() -> ModelContainer {
        let schema = Schema([FoodItem.self, FoodDispositionRecord.self, ReplenishmentItem.self])
        let inMemory = ProcessInfo.processInfo.arguments.contains("-uitesting")
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
        do {
            return try ModelContainer(for: schema, configurations: configuration)
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }

    private func configureTabBarAppearance() {
        let appearance = UITabBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.backgroundEffect = UIBlurEffect(style: .systemChromeMaterial)
        appearance.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.78)
        appearance.shadowColor = UIColor.separator.withAlphaComponent(0.35)

        let selectedColor = UIColor.tintColor
        let normalColor = UIColor.secondaryLabel

        [appearance.stackedLayoutAppearance, appearance.inlineLayoutAppearance, appearance.compactInlineLayoutAppearance].forEach { itemAppearance in
            itemAppearance.selected.iconColor = selectedColor
            itemAppearance.selected.titleTextAttributes = [.foregroundColor: selectedColor]
            itemAppearance.normal.iconColor = normalColor
            itemAppearance.normal.titleTextAttributes = [.foregroundColor: normalColor]
        }

        let tabBar = UITabBar.appearance()
        tabBar.standardAppearance = appearance
        tabBar.scrollEdgeAppearance = appearance
        tabBar.isTranslucent = true
    }
}
