import SwiftUI
import SwiftData

struct ReplenishmentListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(
        filter: #Predicate<ReplenishmentItem> { $0.completedAt == nil },
        sort: \ReplenishmentItem.createdAt,
        order: .reverse
    ) private var pendingItems: [ReplenishmentItem]
    @State private var selectedItem: ReplenishmentItem?
    @State private var generatedCount: Int?
    @State private var operationError: String?

    private var generateButton: some View {
        Button {
            generateFromHistory()
        } label: {
            Label("从历史生成", systemImage: "clock.arrow.2.circlepath")
                .font(.subheadline)
                .frame(minHeight: 44)
        }
    }

    private var replenishmentHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("补货")
                .font(.largeTitle.weight(.bold))
                .accessibilityAddTraits(.isHeader)
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text("只放用完后下次要买回来的食材。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    generateButton
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("只放用完后下次要买回来的食材。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    generateButton
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
                                    .lineLimit(nil)
                                if let quantity = item.quantity, !quantity.isEmpty {
                                    Text(quantity)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(nil)
                                }
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(replenishmentAccessibilityLabel(for: item))
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            deletePendingItem(item)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
                .listStyle(.plain)
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(item: $selectedItem) { item in
                AddFoodView(
                    storageZone: item.storageZone,
                    template: item.template,
                    prepareSave: {
                        // 与新增库存共用 AddFoodView 内唯一一次 modelContext.save()。
                        item.completedAt = Date()
                        item.updatedAt = item.completedAt
                    },
                    onSave: {
                        // 只有数据库提交成功才关闭 sheet；失败时保留表单供用户重试。
                        selectedItem = nil
                    }
                )
            }
            .overlay {
                if pendingItems.isEmpty {
                    ContentUnavailableView(
                        "暂无待补货",
                        systemImage: "cart",
                        description: Text(
                            generatedCount == 0
                                ? "近 30 天没有达到生成条件的食材"
                                : "在食材详情里点「加入补货」或「从历史生成」后会出现在这里"
                        )
                    )
                }
                if let count = generatedCount {
                    VStack {
                        Spacer()
                        Text(count > 0 ? "已从历史生成 \(count) 项补货" : "没有可生成的补货项")
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
            .alert("操作未保存", isPresented: Binding(
                get: { operationError != nil },
                set: { if !$0 { operationError = nil } }
            )) {
                Button("好", role: .cancel) {}
            } message: {
                Text(operationError ?? "未知错误")
            }
        }
    }

    private func generateFromHistory() {
        let threshold = ReplenishmentItem.autoReplenishThreshold
        let thirtyDaysAgo = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        let existingNames = Set(pendingItems.map { $0.name })

        let descriptor = FetchDescriptor<FoodDispositionRecord>(
            predicate: #Predicate<FoodDispositionRecord> { $0.createdAt >= thirtyDaysAgo }
        )
        let allRecords: [FoodDispositionRecord]
        do {
            allRecords = try modelContext.fetch(descriptor)
        } catch {
            operationError = "读取历史失败：\(error.localizedDescription)"
            return
        }
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

        do {
            if added > 0 { try modelContext.save() }
            withAnimation { generatedCount = added }
        } catch {
            modelContext.rollback()
            operationError = "生成补货项失败：\(error.localizedDescription)"
        }
    }

    private func deletePendingItem(_ item: ReplenishmentItem) {
        modelContext.delete(item)
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            operationError = "删除失败：\(error.localizedDescription)"
        }
    }

    private func replenishmentAccessibilityLabel(for item: ReplenishmentItem) -> String {
        var components = [
            item.name,
            item.category.rawValue,
            item.storageZone.rawValue,
            "约 \(item.defaultShelfLifeDays) 天"
        ]
        if let quantity = item.quantity?.trimmingCharacters(in: .whitespacesAndNewlines), !quantity.isEmpty {
            components.append("数量 \(quantity)")
        }
        return components.joined(separator: "，")
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
