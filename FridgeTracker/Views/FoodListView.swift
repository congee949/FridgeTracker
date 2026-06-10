import SwiftUI
import SwiftData

struct FoodListView: View {
    let storageZone: StorageZone?
    @Binding var pendingDetailID: UUID?

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \FoodItem.expiryDate) private var allItems: [FoodItem]
    @State private var viewModel = FoodListViewModel()
    @State private var showAddSheet = false
    @State private var selectedItem: FoodItem?

    init(storageZone: StorageZone?, pendingDetailID: Binding<UUID?> = .constant(nil)) {
        self.storageZone = storageZone
        self._pendingDetailID = pendingDetailID
    }

    private var zoneItems: [FoodItem] {
        guard let storageZone else { return allItems }
        return allItems.filter { $0.storageZone == storageZone }
    }

    private var filteredItems: [FoodItem] {
        viewModel.filteredItems(zoneItems)
    }

    private var title: String {
        storageZone.map { "\($0.icon) \($0.rawValue)" } ?? "食材"
    }

    private var foodHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.largeTitle.weight(.bold))
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
                Button {
                    showAddSheet = true
                } label: {
                    Image(systemName: "plus")
                        .font(.title2.weight(.semibold))
                        .frame(width: 44, height: 44)
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索食材...", text: $viewModel.searchText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
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
        NavigationStack {
            VStack(spacing: 0) {
                foodHeader

                List {
                    ForEach(filteredItems) { item in
                        Button {
                            selectedItem = item
                        } label: {
                            FoodRowView(item: item)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button {
                                addToReplenishment(item)
                            } label: {
                                Label("加入补货", systemImage: "cart.badge.plus")
                            }
                            .tint(.blue)

                            Button {
                                discardItem(item)
                            } label: {
                                Label("扔掉", systemImage: "xmark.bin")
                            }
                            .tint(.orange)

                            Button {
                                consumeItem(item)
                            } label: {
                                Label("\(item.category.consumeVerb)掉", systemImage: "checkmark.circle")
                            }
                            .tint(.green)
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
            .onChange(of: allItems.count) { _, _ in resolvePendingDetail() }
            .onAppear { resolvePendingDetail() }
            .overlay {
                if filteredItems.isEmpty {
                    ContentUnavailableView(
                        "暂无食材",
                        systemImage: "refrigerator",
                        description: Text("点击右上角 + 添加食材")
                    )
                }
            }
        }
    }

    private func resolvePendingDetail() {
        guard let id = pendingDetailID, !allItems.isEmpty else { return }
        selectedItem = allItems.first { $0.uuid == id }
        pendingDetailID = nil
    }

    private func consumeItem(_ item: FoodItem) {
        modelContext.insert(FoodDispositionRecord(item: item, action: .consumed))
        ReplenishmentItem.autoAddIfNeeded(for: item, in: modelContext)
        reduceQuantityOrRemove(item)
    }

    private func discardItem(_ item: FoodItem) {
        modelContext.insert(FoodDispositionRecord(item: item, action: .discarded))
        reduceQuantityOrRemove(item)
    }

    private func addToReplenishment(_ item: FoodItem) {
        ReplenishmentItem.addIfAbsent(for: item, in: modelContext)
        WidgetDataStore.refresh(using: modelContext)
    }

    private func reduceQuantityOrRemove(_ item: FoodItem) {
        if item.reduceQuantityByOne() {
            removeFromInventory(item)
        } else {
            NotificationManager.shared.cancelNotification(for: item)
            NotificationManager.shared.scheduleNotification(for: item)
            WidgetDataStore.refresh(using: modelContext)
        }
    }

    private func removeFromInventory(_ item: FoodItem) {
        NotificationManager.shared.cancelNotification(for: item)
        modelContext.delete(item)
        WidgetDataStore.refresh(using: modelContext)
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
                .padding(.vertical, 6)
                .background(isSelected ? Color.accentColor : Color(.secondarySystemBackground))
                .foregroundStyle(isSelected ? .white : .primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
