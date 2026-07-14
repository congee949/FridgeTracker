import SwiftUI
import SwiftData

struct FoodListView: View {
    let storageZone: StorageZone?
    @Binding var pendingDetailID: UUID?

    @Environment(\.modelContext) private var modelContext
    @Query private var allItems: [FoodItem]
    @State private var viewModel = FoodListViewModel()
    @State private var showAddSheet = false
    @State private var selectedItem: FoodItem?
    @State private var operationError: String?

    init(storageZone: StorageZone?, pendingDetailID: Binding<UUID?> = .constant(nil)) {
        self.storageZone = storageZone
        self._pendingDetailID = pendingDetailID
    }

    private var zoneItems: [FoodItem] {
        guard let storageZone else { return allItems }
        return allItems.filter { $0.storageZone == storageZone }
    }

    private var title: String {
        storageZone.map { "\($0.icon) \($0.rawValue)" } ?? "食材"
    }

    private var foodHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.largeTitle.weight(.bold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Menu {
                    ForEach(SortOption.allCases, id: \.self) { option in
                        Button {
                            viewModel.sortOption = option
                        } label: {
                            HStack {
                                Text(option.rawValue)
                                if viewModel.sortOption == option {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.title2.weight(.semibold))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("排序")
                .accessibilityValue(viewModel.sortOption.rawValue)
                Button {
                    showAddSheet = true
                } label: {
                    Image(systemName: "plus")
                        .font(.title2.weight(.semibold))
                        .frame(width: 44, height: 44)
                }
                .accessibilityIdentifier("foodList.addButton")
                .accessibilityLabel("添加食材")
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索食材...", text: $viewModel.searchText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("foodList.searchField")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    CategoryChip(title: "全部", isSelected: viewModel.selectedCategory == nil) {
                        viewModel.selectedCategory = nil
                    }
                    ForEach(FoodCategory.allCases, id: \.self) { category in
                        CategoryChip(
                            title: "\(category.icon) \(category.rawValue)",
                            isSelected: viewModel.selectedCategory == category
                        ) {
                            viewModel.selectedCategory = viewModel.selectedCategory == category ? nil : category
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
        // 同一轮渲染只筛选和排序一次，避免 List 与空态重复执行。
        let currentZoneItems = zoneItems
        let currentFilteredItems = viewModel.filteredItems(currentZoneItems)

        NavigationStack {
            VStack(spacing: 0) {
                foodHeader

                List {
                    ForEach(currentFilteredItems) { item in
                        Button {
                            selectedItem = item
                        } label: {
                            FoodRowView(item: item)
                        }
                        .accessibilityIdentifier("foodRow.\(item.name)")
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button {
                                addToReplenishment(item)
                            } label: {
                                Label("加入补货", systemImage: "cart.badge.plus")
                            }
                            .tint(.blue)
                            .accessibilityIdentifier("foodRow.replenishAction")

                            Button {
                                discardItem(item)
                            } label: {
                                Label("扔掉", systemImage: "xmark.bin")
                            }
                            .tint(.orange)
                            .accessibilityIdentifier("foodRow.discardAction")

                            Button {
                                consumeItem(item)
                            } label: {
                                Label("\(item.category.consumeVerb)掉", systemImage: "checkmark.circle")
                            }
                            .tint(.green)
                            .accessibilityIdentifier("foodRow.consumeAction")
                        }
                    }
                }
                .listStyle(.plain)
                .navigationDestination(item: $selectedItem) { item in
                    FoodDetailView(item: item)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showAddSheet) {
                AddFoodView(storageZone: storageZone ?? .fridge)
            }
            .onChange(of: pendingDetailID) { _, _ in resolvePendingDetail() }
            .onAppear { resolvePendingDetail() }
            .overlay {
                if currentZoneItems.isEmpty {
                    ContentUnavailableView(
                        "暂无食材",
                        systemImage: "refrigerator",
                        description: Text("点击右上角 + 添加食材")
                    )
                } else if currentFilteredItems.isEmpty {
                    ContentUnavailableView {
                        Label("没有匹配的食材", systemImage: "line.3.horizontal.decrease.circle")
                    } description: {
                        Text("当前搜索或分类下没有结果")
                    } actions: {
                        Button("清除筛选") {
                            viewModel.searchText = ""
                            viewModel.selectedCategory = nil
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .alert("操作未保存", isPresented: Binding(
            get: { operationError != nil },
            set: { if !$0 { operationError = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(operationError ?? "未知错误")
        }
    }

    /// 直接按 uuid 同步查库，不再等 @Query 加载后靠 allItems.count 变化重试——
    /// fetch 结果与视图更新时机无关，冷启动深链也一次到位；查不到说明食材已删，清掉即可。
    private func resolvePendingDetail() {
        guard let id = pendingDetailID else { return }
        pendingDetailID = nil
        if let item = FoodItem.find(uuid: id, in: modelContext) {
            selectedItem = item
        }
    }

    private func consumeItem(_ item: FoodItem) {
        modelContext.insert(FoodDispositionRecord(item: item, action: .consumed))
        do {
            try ReplenishmentItem.autoAddIfNeededOrThrow(for: item, in: modelContext)
        } catch {
            modelContext.rollback()
            operationError = error.localizedDescription
            return
        }
        if item.reduceQuantityByOne() { modelContext.delete(item) }
        commitInventoryMutation()
    }

    private func discardItem(_ item: FoodItem) {
        modelContext.insert(FoodDispositionRecord(item: item, action: .discarded))
        if item.reduceQuantityByOne() { modelContext.delete(item) }
        commitInventoryMutation()
    }

    private func addToReplenishment(_ item: FoodItem) {
        do {
            guard try ReplenishmentItem.addIfAbsentOrThrow(for: item, in: modelContext) else { return }
            commitInventoryMutation(refreshWidget: false)
        } catch {
            modelContext.rollback()
            operationError = error.localizedDescription
        }
    }

    private func commitInventoryMutation(refreshWidget: Bool = true) {
        do {
            try modelContext.save()
            if refreshWidget {
                WidgetDataStore.refresh(using: modelContext)
            }
            Task { @MainActor in
                await NotificationManager.shared.reconcile(using: modelContext)
            }
        } catch {
            modelContext.rollback()
            operationError = error.localizedDescription
        }
    }

}

struct CategoryChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(minHeight: 44)
                .background(isSelected ? Color.accentColor : Color(.secondarySystemBackground))
                .foregroundStyle(isSelected ? Color(.systemBackground) : .primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .contentShape(Capsule())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
