import SwiftUI
import SwiftData

struct HistoryView: View {
    @Query(sort: \FoodItem.createdAt, order: .reverse) private var allItems: [FoodItem]
    @Query(sort: \FoodDispositionRecord.createdAt, order: .reverse) private var dispositionRecords: [FoodDispositionRecord]
    @ObservedObject private var historySuggestionStore = HistorySuggestionStore.shared
    @State private var searchText = ""
    @State private var selectedCategory: FoodCategory?
    @State private var selectedTemplate: FoodTemplate?
    @State private var sourceTemplates: [FoodTemplate] = []
    @State private var hasLoadedHistory = false

    private var visibleHistoryTemplates: [FoodTemplate] {
        historySuggestionStore.applyOverrides(to: sourceTemplates).filter { template in
            let matchesSearch = searchText.isEmpty || template.name.localizedCaseInsensitiveContains(searchText)
            let matchesCategory = selectedCategory == nil || template.category == selectedCategory
            return matchesSearch && matchesCategory
        }
    }

    private var hasActiveFilters: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedCategory != nil
    }

    private var historyHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("历史")
                .font(.largeTitle.weight(.bold))
                .accessibilityAddTraits(.isHeader)

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
        // 搜索词和分类变化只过滤缓存；不再为 List 和空态各做一次全量历史聚合。
        let historyTemplates = visibleHistoryTemplates

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
                                    .lineLimit(nil)
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(template.name)，\(template.category.rawValue)，\(template.storageZone.rawValue)，约 \(template.defaultShelfLifeDays) 天")
                }
                .listStyle(.plain)
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(item: $selectedTemplate) { template in
                AddFoodView(storageZone: template.storageZone, template: template)
            }
            .onAppear { rebuildHistoryTemplates() }
            .onChange(of: allItems.count) { _, _ in rebuildHistoryTemplates() }
            .onChange(of: dispositionRecords.count) { _, _ in rebuildHistoryTemplates() }
            .overlay {
                if hasLoadedHistory && sourceTemplates.isEmpty {
                    ContentUnavailableView(
                        "暂无历史",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("添加过的食材会出现在这里")
                    )
                } else if hasLoadedHistory && historyTemplates.isEmpty && hasActiveFilters {
                    ContentUnavailableView {
                        Label("没有匹配的历史", systemImage: "line.3.horizontal.decrease.circle")
                    } description: {
                        Text("当前搜索或分类下没有结果")
                    } actions: {
                        Button("清除筛选") {
                            searchText = ""
                            selectedCategory = nil
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else if hasLoadedHistory && historyTemplates.isEmpty {
                    ContentUnavailableView(
                        "历史建议均已隐藏",
                        systemImage: "eye.slash",
                        description: Text("可在设置中的“历史建议管理”重新显示")
                    )
                }
            }
        }
    }

    private func rebuildHistoryTemplates() {
        sourceTemplates = FoodTemplate.fromHistory(allItems, records: dispositionRecords)
        hasLoadedHistory = true
    }
}
