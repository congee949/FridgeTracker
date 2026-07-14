import SwiftUI
import SwiftData

struct FoodDetailView: View {
    let item: FoodItem
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var showEditSheet = false
    @State private var pendingAction: DetailAction?
    @State private var showDiscardReplenishPrompt = false
    @State private var statusMessage: String?
    @State private var statusMessageToken = UUID()
    @State private var operationError: String?

    private var expiryColor: Color { expiryStatusColor(daysUntilExpiry: item.daysUntilExpiry) }
    private var expiryText: String { expiryStatusText(daysUntilExpiry: item.daysUntilExpiry) }

    /// 删除后 dismiss 动画期间视图仍可能重新求值；访问已销毁的 @Model 属性会崩溃，先用空视图顶住。
    private var isItemAlive: Bool {
        item.modelContext != nil && !item.isDeleted
    }

    var body: some View {
        Group {
            if isItemAlive {
                detailContent
            } else {
                Color.clear
            }
        }
    }

    private var detailContent: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Header
                VStack(spacing: 12) {
                    Text(item.displayIcon)
                        .font(.system(size: 64))
                    Text(item.name)
                        .font(.title)
                        .fontWeight(.bold)
                    Text(expiryText)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(expiryColor.opacity(0.15))
                        .foregroundStyle(expiryColor)
                        .clipShape(Capsule())
                }
                .padding(.top, 20)

                // Info card
                VStack(spacing: 0) {
                    InfoRow(label: "分类", value: "\(item.category.icon) \(item.category.rawValue)")
                    Divider().padding(.leading, 16)
                    InfoRow(label: "显示图标", value: item.displayIcon)
                    Divider().padding(.leading, 16)
                    InfoRow(label: "存储区域", value: "\(item.storageZone.icon) \(item.storageZone.rawValue)")
                    Divider().padding(.leading, 16)
                    if let purchaseDate = item.purchaseLocalDate?.date() {
                        InfoRow(label: "购买日期", value: purchaseDate.formatted(date: .abbreviated, time: .omitted))
                        Divider().padding(.leading, 16)
                    }
                    InfoRow(label: "保质期", value: (item.expiryLocalDate.date() ?? item.expiryDate).formatted(date: .abbreviated, time: .omitted))
                    if let quantity = item.quantityDisplayText, !quantity.isEmpty {
                        Divider().padding(.leading, 16)
                        InfoRow(label: "数量", value: quantity)
                    }
                    if let notes = item.notes, !notes.isEmpty {
                        Divider().padding(.leading, 16)
                        InfoRow(label: "备注", value: notes)
                    }
                }
                .background(Color(.systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
                .padding(.horizontal)

                VStack(spacing: 12) {
                    Button {
                        showEditSheet = true
                    } label: {
                        Label("编辑", systemImage: "pencil")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)

                    HStack(spacing: 12) {
                        Button {
                            pendingAction = .consumed
                        } label: {
                            Label("\(item.category.consumeVerb)掉", systemImage: "checkmark.circle")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.bordered)

                        Button {
                            pendingAction = .discarded
                        } label: {
                            Label("扔掉", systemImage: "xmark.bin")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.bordered)
                        .tint(.orange)
                    }

                    HStack(spacing: 12) {
                        Button {
                            addToReplenishment()
                        } label: {
                            Label("加入补货", systemImage: "cart.badge.plus")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.bordered)

                        Button {
                            pendingAction = .delete
                        } label: {
                            Label("删除", systemImage: "trash")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    }

                    if let statusMessage {
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal)
            }
        }
        .navigationTitle("食材详情")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showEditSheet) {
            AddFoodView(storageZone: item.storageZone, editItem: item)
        }
        .alert(pendingAction?.title(verb: item.category.consumeVerb) ?? "确认操作", isPresented: Binding(
            get: { pendingAction != nil },
            set: { if !$0 { pendingAction = nil } }
        )) {
            Button("取消", role: .cancel) { pendingAction = nil }
            Button(pendingAction?.confirmTitle(verb: item.category.consumeVerb) ?? "确认", role: pendingAction?.role) {
                performPendingAction()
            }
        } message: {
            Text(pendingAction?.message(
                for: item.name,
                verb: item.category.consumeVerb,
                hasFreeTextQuantity: item.quantityDisplayText != nil && !item.hasCountableQuantity
            ) ?? "")
        }
        .alert("加入补货清单？", isPresented: $showDiscardReplenishPrompt) {
            Button("不用了", role: .cancel) {
                finalizeDiscard(addToReplenishment: false)
            }
            Button("加入") {
                finalizeDiscard(addToReplenishment: true)
            }
        } message: {
            Text("是否将「\(item.name)」加入补货清单？")
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

    private func addToReplenishment() {
        do {
            let inserted = try ReplenishmentItem.addIfAbsentOrThrow(for: item, in: modelContext)
            guard inserted else {
                showStatus("已在补货清单中")
                return
            }
            if commitMutation(refreshWidget: false) {
                showStatus("已加入补货清单")
            }
        } catch {
            modelContext.rollback()
            operationError = error.localizedDescription
        }
    }

    private func showStatus(_ message: String) {
        statusMessage = message
        let token = UUID()
        statusMessageToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            guard statusMessageToken == token else { return }
            withAnimation { statusMessage = nil }
        }
    }

    private func performPendingAction() {
        guard let pendingAction else { return }
        switch pendingAction {
        case .consumed:
            modelContext.insert(FoodDispositionRecord(item: item, action: .consumed))
            do {
                try ReplenishmentItem.autoAddIfNeededOrThrow(for: item, in: modelContext)
            } catch {
                modelContext.rollback()
                operationError = error.localizedDescription
                self.pendingAction = nil
                return
            }
            if item.reduceQuantityByOne() {
                modelContext.delete(item)
                if commitMutation() { dismiss() }
            } else if commitMutation() {
                showQuantityStatus(prefix: "已\(item.category.consumeVerb)掉 1 份")
            }
        case .discarded:
            if nextDispositionRemovesBatch {
                showDiscardReplenishPrompt = true
            } else {
                modelContext.insert(FoodDispositionRecord(item: item, action: .discarded))
                _ = item.reduceQuantityByOne()
                if commitMutation() { showQuantityStatus(prefix: "已扔掉 1 份") }
            }
        case .delete:
            modelContext.delete(item)
            if commitMutation() { dismiss() }
        }
        self.pendingAction = nil
    }

    private var nextDispositionRemovesBatch: Bool {
        guard let quantity = FoodQuantity.parse(item.quantity) else { return true }
        return quantity.current <= 1
    }

    private func finalizeDiscard(addToReplenishment: Bool) {
        modelContext.insert(FoodDispositionRecord(item: item, action: .discarded))
        if addToReplenishment {
            do {
                try ReplenishmentItem.addIfAbsentOrThrow(for: item, in: modelContext)
            } catch {
                modelContext.rollback()
                operationError = error.localizedDescription
                return
            }
        }
        if item.reduceQuantityByOne() { modelContext.delete(item) }
        if commitMutation() { dismiss() }
    }

    private func showQuantityStatus(prefix: String) {
        if let quantity = item.quantityDisplayText {
            showStatus("\(prefix)，剩余 \(quantity)")
        } else {
            showStatus(prefix)
        }
    }

    @discardableResult
    private func commitMutation(refreshWidget: Bool = true) -> Bool {
        do {
            try modelContext.save()
            if refreshWidget { WidgetDataStore.refresh(using: modelContext) }
            Task { @MainActor in
                await NotificationManager.shared.reconcile(using: modelContext)
            }
            return true
        } catch {
            modelContext.rollback()
            operationError = error.localizedDescription
            return false
        }
    }
}

enum DetailAction: Identifiable {
    case consumed
    case discarded
    case delete

    var id: String {
        switch self {
        case .consumed: return "consumed"
        case .discarded: return "discarded"
        case .delete: return "delete"
        }
    }

    func title(verb: String) -> String {
        switch self {
        case .consumed: return "确认\(verb)掉"
        case .discarded: return "确认扔掉"
        case .delete: return "确认删除"
        }
    }

    func confirmTitle(verb: String) -> String {
        switch self {
        case .consumed: return "\(verb)掉"
        case .discarded: return "扔掉"
        case .delete: return "删除"
        }
    }

    var role: ButtonRole? {
        switch self {
        case .consumed: return nil
        case .discarded, .delete: return .destructive
        }
    }

    /// 数量为自由文本（如「半盒」「0.5kg」）时不参与计数，消耗会一次移除整项——
    /// 弹窗文案必须说清这一点，不能沿用「减 1 份」的说法误导用户。
    func message(for name: String, verb: String, hasFreeTextQuantity: Bool) -> String {
        switch self {
        case .consumed:
            if hasFreeTextQuantity {
                return "「\(name)」的数量是自由文本，不按份数递减；\(verb)掉会移除整项并计入历史。"
            }
            return "将「\(name)」\(verb)掉 1 份；如果是最后 1 份，会从当前库存移除。"
        case .discarded:
            if hasFreeTextQuantity {
                return "「\(name)」的数量是自由文本，不按份数递减；扔掉会移除整项并计入历史。"
            }
            return "将「\(name)」扔掉 1 份；如果是最后 1 份，会从当前库存移除。"
        case .delete:
            return "删除只用于误录入，不会记录吃掉或扔掉结果。"
        }
    }
}

struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
                .font(.subheadline)
            Spacer()
            Text(value)
                .font(.subheadline)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
