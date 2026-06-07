import SwiftUI
import SwiftData

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
