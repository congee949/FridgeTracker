import SwiftUI
import SwiftData

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
