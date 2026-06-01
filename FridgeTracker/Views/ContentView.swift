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

struct ReplenishmentListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ReplenishmentItem.createdAt, order: .reverse) private var allItems: [ReplenishmentItem]
    @State private var selectedItem: ReplenishmentItem?
    @State private var generatedCount: Int?

    private var pendingItems: [ReplenishmentItem] {
        allItems.filter { $0.completedAt == nil }
    }

    private var replenishmentHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("补货")
                .font(.largeTitle.weight(.bold))
            HStack {
                Text("只放用完后下次要买回来的食材。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    generateFromHistory()
                } label: {
                    Label("从历史生成", systemImage: "clock.arrow.2.circlepath")
                        .font(.subheadline)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .background(Color(.systemBackground))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                replenishmentHeader

                List(pendingItems) { item in
                    Button {
                        selectedItem = item
                    } label: {
                        HStack(spacing: 12) {
                            Text(item.displayIcon)
                                .font(.title2)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.name)
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                Text("\(item.category.rawValue) · \(item.storageZone.rawValue) · 约 \(item.defaultShelfLifeDays) 天")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if let quantity = item.quantity, !quantity.isEmpty {
                                    Text(quantity)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(item: $selectedItem) { item in
                AddFoodView(storageZone: item.storageZone, template: item.template) {
                    item.completedAt = Date()
                }
            }
            .overlay {
                if pendingItems.isEmpty && generatedCount == nil {
                    ContentUnavailableView(
                        "暂无待补货",
                        systemImage: "cart",
                        description: Text("在食材详情里点「加入补货」或「从历史生成」后会出现在这里")
                    )
                }
                if let count = generatedCount, count > 0 {
                    VStack {
                        Spacer()
                        Text("已从历史生成 \(count) 项补货")
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(.ultraThinMaterial)
                            .clipShape(Capsule())
                            .padding(.bottom, 20)
                    }
                    .transition(.opacity)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            withAnimation { generatedCount = nil }
                        }
                    }
                }
            }
        }
    }

    private func generateFromHistory() {
        let threshold = ReplenishmentItem.autoReplenishThreshold
        let thirtyDaysAgo = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        let existingNames = Set(allItems.filter { $0.completedAt == nil }.map { $0.name })

        let descriptor = FetchDescriptor<FoodDispositionRecord>(
            predicate: #Predicate<FoodDispositionRecord> { $0.createdAt >= thirtyDaysAgo }
        )
        guard let allRecords = try? modelContext.fetch(descriptor) else { return }
        let records = allRecords.filter { $0.action == .consumed }

        var counts: [String: Int] = [:]
        var latestRecord: [String: FoodDispositionRecord] = [:]
        for record in records {
            let name = record.foodName
            counts[name, default: 0] += 1
            if latestRecord[name] == nil || record.createdAt > latestRecord[name]!.createdAt {
                latestRecord[name] = record
            }
        }

        var added = 0
        for (name, count) in counts {
            guard count >= threshold, !existingNames.contains(name),
                  let record = latestRecord[name] else { continue }
            modelContext.insert(ReplenishmentItem(record: record))
            added += 1
        }

        withAnimation { generatedCount = added }
    }
}

private extension ReplenishmentItem {
    var template: FoodTemplate {
        FoodTemplate(
            name: name,
            category: category,
            storageZone: storageZone,
            customIcon: customIcon,
            defaultShelfLifeDays: defaultShelfLifeDays,
            quantity: quantity,
            notes: notes,
            purchaseDate: nil
        )
    }
}

struct HistoryView: View {
    @Query(sort: \FoodItem.createdAt, order: .reverse) private var allItems: [FoodItem]
    @ObservedObject private var historySuggestionStore = HistorySuggestionStore.shared
    @State private var searchText = ""
    @State private var selectedCategory: FoodCategory?
    @State private var selectedTemplate: FoodTemplate?

    private var historyTemplates: [FoodTemplate] {
        historySuggestionStore.applyOverrides(to: FoodTemplate.fromHistory(allItems)).filter { template in
            let matchesSearch = searchText.isEmpty || template.name.localizedCaseInsensitiveContains(searchText)
            let matchesCategory = selectedCategory == nil || template.category == selectedCategory
            return matchesSearch && matchesCategory
        }
    }

    private var historyHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("历史")
                .font(.largeTitle.weight(.bold))

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索历史食材...", text: $searchText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    CategoryChip(title: "全部", isSelected: selectedCategory == nil) {
                        selectedCategory = nil
                    }
                    ForEach(FoodCategory.allCases, id: \.self) { category in
                        CategoryChip(
                            title: "\(category.icon) \(category.rawValue)",
                            isSelected: selectedCategory == category
                        ) {
                            selectedCategory = selectedCategory == category ? nil : category
                        }
                    }
                }
            }
        }
        .padding(.horizontal)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .background(Color(.systemBackground))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                historyHeader

                List(historyTemplates) { template in
                    Button {
                        selectedTemplate = template
                    } label: {
                        HStack(spacing: 12) {
                            Text(template.icon)
                                .font(.title2)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(template.name)
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                Text("\(template.category.rawValue) · \(template.storageZone.rawValue) · 约 \(template.defaultShelfLifeDays) 天")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(item: $selectedTemplate) { template in
                AddFoodView(storageZone: template.storageZone, template: template)
            }
            .overlay {
                if historyTemplates.isEmpty {
                    ContentUnavailableView(
                        "暂无历史",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("添加过的食材会出现在这里")
                    )
                }
            }
        }
    }
}
