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
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
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
            .task {
                // 启动时刷新小组件快照，并补排所有提醒（覆盖导入、跨设备迁移、授权后追加等场景）
                WidgetDataStore.refresh(using: modelContext)
                HistoryMaintenance.pruneIfEnabled(in: modelContext)
                guard await NotificationManager.shared.isAuthorized() else { return }
                let items = (try? modelContext.fetch(FetchDescriptor<FoodItem>())) ?? []
                await NotificationManager.shared.rescheduleAll(for: items)
            }
            // 写后投影兜底：任何 SwiftData 保存（含 autosave、未来新增的写入路径）都会触发快照刷新，
            // 不再依赖每个写入点记得显式调用 WidgetDataStore.refresh
            .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)) { _ in
                WidgetDataStore.scheduleRefresh(using: modelContext)
            }
            .onChange(of: scenePhase) { _, phase in
                // 回到前台强制刷新，覆盖跨天后快照里过期天数陈旧的情况
                if phase == .active {
                    WidgetDataStore.scheduleRefresh(using: modelContext)
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

