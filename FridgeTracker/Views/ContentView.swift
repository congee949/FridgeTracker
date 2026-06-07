import SwiftUI
import SwiftData

enum FridgeTab: CaseIterable {
    case food
    case replenishment
    case history
    case settings

    var title: String {
        switch self {
        case .food: return "食材"
        case .replenishment: return "补货"
        case .history: return "历史"
        case .settings: return "设置"
        }
    }

    var systemImage: String {
        switch self {
        case .food: return "refrigerator"
        case .replenishment: return "cart"
        case .history: return "clock.arrow.circlepath"
        case .settings: return "gearshape"
        }
    }
}

enum AppRoute: Hashable {
    case foodDetail(UUID)

    init?(url: URL) {
        guard url.scheme == "fridgetracker", url.host == "food" else { return nil }
        let pathComponents = url.pathComponents.filter { $0 != "/" }
        if pathComponents.isEmpty {
            return nil
        }
        guard pathComponents.count == 1, let id = UUID(uuidString: pathComponents[0]) else { return nil }
        self = .foodDetail(id)
    }
}

struct ContentView: View {
    @State private var selectedTab: FridgeTab = .food
    @State private var pendingFoodDetailID: UUID?

    var body: some View {
        nativeTabView
            .onOpenURL { url in
                selectedTab = .food
                if case let .foodDetail(id) = AppRoute(url: url) {
                    pendingFoodDetailID = id
                }
            }
    }

    private var nativeTabView: some View {
        TabView(selection: $selectedTab) {
            FoodListView(storageZone: nil, pendingDetailID: $pendingFoodDetailID)
                .tabItem {
                    Label(FridgeTab.food.title, systemImage: FridgeTab.food.systemImage)
                }
                .tag(FridgeTab.food)

            ReplenishmentListView()
                .tabItem {
                    Label(FridgeTab.replenishment.title, systemImage: FridgeTab.replenishment.systemImage)
                }
                .tag(FridgeTab.replenishment)

            HistoryView()
                .tabItem {
                    Label(FridgeTab.history.title, systemImage: FridgeTab.history.systemImage)
                }
                .tag(FridgeTab.history)

            SettingsView()
                .tabItem {
                    Label(FridgeTab.settings.title, systemImage: FridgeTab.settings.systemImage)
                }
                .tag(FridgeTab.settings)
        }
        .tabBarMinimizeBehavior(.onScrollDown)
    }
}

