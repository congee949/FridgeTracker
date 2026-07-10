import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import UIKit

struct SettingsView: View {
    @AppStorage("notificationsEnabled") private var notificationsEnabled = true
    @AppStorage("reminderDaysBefore") private var reminderDaysBefore = -1
    @AppStorage(HistoryMaintenance.retentionDaysKey) private var historyRetentionDays = -1
    @AppStorage(WidgetDataStore.lastSyncTimestampKey) private var widgetSyncTimestamp = 0.0
    @AppStorage(WidgetDataStore.lastSyncErrorKey) private var widgetSyncError = ""
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \FoodItem.createdAt) private var allItems: [FoodItem]
    @ObservedObject private var historySuggestionStore = HistorySuggestionStore.shared
    @State private var exportDocument: FoodBackupDocument?
    @State private var isImporting = false
    @State private var statusMessage: String?
    @State private var showPruneConfirmation = false
    @State private var pruneMessage: String?
    @State private var notificationsDenied = false

    var body: some View {
        NavigationStack {
            Form {
                Section("提醒") {
                    Toggle("开启过期提醒", isOn: $notificationsEnabled)

                    if notificationsEnabled && notificationsDenied {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("系统通知已关闭，过期提醒不会触发", systemImage: "bell.slash")
                                .font(.caption)
                                .foregroundStyle(.orange)
                            Button("前往系统设置开启") {
                                if let url = URL(string: UIApplication.openSettingsURLString) {
                                    UIApplication.shared.open(url)
                                }
                            }
                            .font(.caption)
                        }
                    }

                    if notificationsEnabled {
                        Picker("默认提前提醒", selection: $reminderDaysBefore) {
                            Text("分类默认").tag(-1)
                            Text("当天").tag(0)
                            Text("1 天").tag(1)
                            Text("2 天").tag(2)
                            Text("3 天").tag(3)
                            Text("7 天").tag(7)
                        }

                        LabeledContent("肉类 / 海鲜提前提醒", value: "2 天")
                        LabeledContent("冷冻食品提前提醒", value: "7 天")

                        Text("分类默认会让肉类/海鲜提前 2 天、冷冻食品提前 7 天，其他食材提前 1 天提醒；到期日当天 9 点会再提醒一次。新添加的食材如果已错过上述时间但还没过期，会立即补一条提醒；已过期的食材不再创建新通知。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Text("食材列表的排序可在「食材」页右上角的排序菜单中切换。小组件标题会跟随每个小组件所选的分类自动变化。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("显示")
                }

                Section("建议") {
                    NavigationLink("历史建议管理") {
                        HistorySuggestionManagementView()
                    }
                }

                Section("历史") {
                    Picker("历史保留", selection: $historyRetentionDays) {
                        ForEach(HistoryMaintenance.retentionOptions, id: \.days) { option in
                            Text(option.label).tag(option.days)
                        }
                    }
                    if historyRetentionDays > 0 {
                        Button("立即清理历史", role: .destructive) {
                            showPruneConfirmation = true
                        }
                    }
                    if let pruneMessage {
                        Text(pruneMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("清理会删除保留期之前的吃掉/扔掉记录和已完成的补货记录；当前库存和待补货不受影响。选择期限后，每次启动也会自动清理超期记录。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("数据") {
                    Button("导出数据") {
                        let records = (try? modelContext.fetch(FetchDescriptor<FoodDispositionRecord>())) ?? []
                        let replenishments = (try? modelContext.fetch(FetchDescriptor<ReplenishmentItem>())) ?? []
                        exportDocument = FoodBackupDocument(items: allItems, records: records, replenishments: replenishments)
                    }
                    Button("导入数据") {
                        isImporting = true
                    }
                    if let statusMessage {
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("小组件") {
                    LabeledContent("数据同步") {
                        Text(widgetSyncStatusText)
                            .foregroundStyle(widgetSyncError.isEmpty ? Color.secondary : Color.orange)
                            .multilineTextAlignment(.trailing)
                    }
                    Button("立即刷新小组件") {
                        WidgetDataStore.refresh(using: modelContext)
                    }
                }

                Section("关于") {
                    LabeledContent("App 名称", value: "FridgeTracker")
                    LabeledContent("版本", value: appVersion)
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: notificationsEnabled) { _, enabled in
                Task { @MainActor in
                    if enabled {
                        _ = await NotificationManager.shared.requestPermission()
                    }
                    await refreshNotificationStatus()
                    await NotificationManager.shared.rescheduleAll(for: allItems)
                }
            }
            .onChange(of: reminderDaysBefore) { _, _ in
                Task { @MainActor in
                    await NotificationManager.shared.rescheduleAll(for: allItems)
                }
            }
            .onChange(of: scenePhase) { _, phase in
                // 已在设置页时，用户去系统设置改完授权切回前台 → 更新/清掉拒绝提示
                if phase == .active {
                    Task { await refreshNotificationStatus() }
                }
            }
            .onAppear {
                // 首次进入 + 每次切回设置页（含在别处刚被拒绝后切来）都同步一次
                Task { await refreshNotificationStatus() }
            }
            .alert("清理历史记录？", isPresented: $showPruneConfirmation) {
                Button("取消", role: .cancel) {}
                Button("清理", role: .destructive) {
                    let removed = HistoryMaintenance.prune(in: modelContext, retentionDays: historyRetentionDays)
                    pruneMessage = "已清理：吃掉/扔掉记录 \(removed.records) 条，已完成补货 \(removed.replenishments) 条"
                }
            } message: {
                Text("将删除保留期（\(retentionLabel)）之前的吃掉/扔掉记录与已完成的补货记录，删除后无法恢复。")
            }
            .fileExporter(
                isPresented: Binding(
                    get: { exportDocument != nil },
                    set: { if !$0 { exportDocument = nil } }
                ),
                document: exportDocument,
                contentType: .json,
                defaultFilename: "FridgeTracker-Backup"
            ) { result in
                switch result {
                case .success:
                    statusMessage = "导出完成"
                case .failure(let error):
                    statusMessage = "导出失败：\(error.localizedDescription)"
                }
                exportDocument = nil
            }
            .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json]) { result in
                importBackup(from: result)
            }
        }
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        return build.map { "\(version) (\($0))" } ?? version
    }

    private var retentionLabel: String {
        HistoryMaintenance.retentionOptions.first { $0.days == historyRetentionDays }?.label ?? "\(historyRetentionDays) 天"
    }

    private var widgetSyncStatusText: String {
        WidgetDataStore.syncStatusText(error: widgetSyncError, timestamp: widgetSyncTimestamp)
    }

    @MainActor
    private func refreshNotificationStatus() async {
        notificationsDenied = await NotificationManager.shared.isDenied()
    }

    private func importBackup(from result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let accessGranted = url.startAccessingSecurityScopedResource()
            defer {
                if accessGranted {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let backup = try decoder.decode(FoodBackup.self, from: data)

            // 按 uuid 去重，v1 备份无 uuid 时退化为「名称+创建时间」匹配，重复导入不再翻倍
            let existingItems = (try? modelContext.fetch(FetchDescriptor<FoodItem>())) ?? []
            var existingUUIDs = Set(existingItems.map(\.uuid))
            var existingNaturalKeys = Set(existingItems.map { Self.naturalKey(name: $0.name, createdAt: $0.createdAt) })

            var importedCount = 0
            var skippedCount = 0
            for backupItem in backup.items {
                let naturalKey = Self.naturalKey(name: backupItem.name, createdAt: backupItem.createdAt)
                let isDuplicate = backupItem.uuid.map { existingUUIDs.contains($0) } ?? existingNaturalKeys.contains(naturalKey)
                guard !isDuplicate else {
                    skippedCount += 1
                    continue
                }
                let item = backupItem.foodItem
                modelContext.insert(item)
                existingUUIDs.insert(item.uuid)
                existingNaturalKeys.insert(naturalKey)
                importedCount += 1
            }

            var importedRecordCount = 0
            if let records = backup.dispositionRecords, !records.isEmpty {
                let existing = (try? modelContext.fetch(FetchDescriptor<FoodDispositionRecord>())) ?? []
                var seenUUIDs = Set(existing.map(\.uuid))
                for record in records where !seenUUIDs.contains(record.uuid) {
                    modelContext.insert(record.record)
                    seenUUIDs.insert(record.uuid)
                    importedRecordCount += 1
                }
            }

            var importedReplenishmentCount = 0
            if let replenishments = backup.replenishmentItems, !replenishments.isEmpty {
                let existing = (try? modelContext.fetch(FetchDescriptor<ReplenishmentItem>())) ?? []
                var seenUUIDs = Set(existing.map(\.uuid))
                for entry in replenishments where !seenUUIDs.contains(entry.uuid) {
                    modelContext.insert(entry.replenishmentItem)
                    seenUUIDs.insert(entry.uuid)
                    importedReplenishmentCount += 1
                }
            }

            WidgetDataStore.refresh(using: modelContext)
            Task { @MainActor in
                // 导入的食材此前没有任何提醒，授权后统一补排
                guard await NotificationManager.shared.requestPermission() else { return }
                let items = (try? modelContext.fetch(FetchDescriptor<FoodItem>())) ?? []
                await NotificationManager.shared.rescheduleAll(for: items)
            }

            var parts = ["食材 +\(importedCount)"]
            if skippedCount > 0 { parts[0] += "（跳过重复 \(skippedCount)）" }
            if importedRecordCount > 0 { parts.append("历史记录 +\(importedRecordCount)") }
            if importedReplenishmentCount > 0 { parts.append("补货 +\(importedReplenishmentCount)") }
            statusMessage = "导入完成：" + parts.joined(separator: "，")
        } catch {
            statusMessage = "导入失败：\(error.localizedDescription)"
        }
    }

    private static func naturalKey(name: String, createdAt: Date) -> String {
        "\(name)|\(createdAt.timeIntervalSince1970)"
    }
}

struct HistorySuggestionManagementView: View {
    @Query(sort: \FoodItem.createdAt, order: .reverse) private var items: [FoodItem]
    @Query(sort: \FoodDispositionRecord.createdAt, order: .reverse) private var dispositionRecords: [FoodDispositionRecord]
    @ObservedObject private var historySuggestionStore = HistorySuggestionStore.shared

    private var templates: [FoodTemplate] {
        FoodTemplate.fromHistory(items, records: dispositionRecords)
    }

    var body: some View {
        List {
            if templates.isEmpty {
                ContentUnavailableView(
                    "暂无历史建议",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("添加过食材后，会在这里管理同名复用设置。")
                )
            } else {
                ForEach(templates) { template in
                    NavigationLink {
                        HistorySuggestionEditView(template: template)
                    } label: {
                        HistorySuggestionSettingsRow(
                            template: template.applying(historySuggestionStore.override(for: template.normalizedName)),
                            isHidden: historySuggestionStore.isHidden(template.normalizedName)
                        )
                    }
                }
            }
        }
        .navigationTitle("历史建议管理")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct HistorySuggestionSettingsRow: View {
    let template: FoodTemplate
    let isHidden: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(template.icon)
                .font(.title2)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(template.name)
                        .font(.headline)
                    if isHidden {
                        Text("已隐藏")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(.systemGray5))
                            .clipShape(Capsule())
                    }
                }
                Text("\(template.category.rawValue) · \(template.storageZone.rawValue) · 约 \(template.defaultShelfLifeDays) 天")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct HistorySuggestionEditView: View {
    let template: FoodTemplate
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var historySuggestionStore = HistorySuggestionStore.shared

    @State private var category: FoodCategory
    @State private var storageZone: StorageZone
    @State private var customIcon: String
    @State private var defaultShelfLifeDays: Int
    @State private var isHidden: Bool

    init(template: FoodTemplate) {
        self.template = template
        let override = HistorySuggestionStore.shared.override(for: template.normalizedName)
        let editableTemplate = template.applying(override)
        _category = State(initialValue: editableTemplate.category)
        _storageZone = State(initialValue: editableTemplate.storageZone)
        _customIcon = State(initialValue: editableTemplate.customIcon ?? "")
        _defaultShelfLifeDays = State(initialValue: editableTemplate.defaultShelfLifeDays)
        _isHidden = State(initialValue: override?.isHidden == true)
    }

    var body: some View {
        Form {
            Section("食材") {
                LabeledContent("名称", value: template.name)
                Toggle("隐藏这个历史建议", isOn: $isHidden)
                Text("隐藏后不会出现在“最近添加”和“历史”建议列表，也不会在输入同名食材时自动套用。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("复用默认值") {
                Picker("分类", selection: $category) {
                    ForEach(FoodCategory.allCases, id: \.self) { category in
                        Text("\(category.icon) \(category.rawValue)").tag(category)
                    }
                }

                TextField("显示图标", text: $customIcon)
                Text("留空时使用分类图标：\(category.icon)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("存储区域", selection: $storageZone) {
                    ForEach(StorageZone.allCases, id: \.self) { zone in
                        Text("\(zone.icon) \(zone.rawValue)").tag(zone)
                    }
                }

                Stepper("默认保质期：\(defaultShelfLifeDays) 天", value: $defaultShelfLifeDays, in: 1...365)
            }

            Section {
                Button("恢复历史默认值", role: .destructive) {
                    historySuggestionStore.removeOverride(for: template.normalizedName)
                    dismiss()
                }
            }
        }
        .navigationTitle(template.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { save() }
            }
        }
    }

    private func save() {
        let icon = customIcon.trimmingCharacters(in: .whitespacesAndNewlines)
        historySuggestionStore.save(HistorySuggestionOverride(
            name: template.normalizedName,
            category: category,
            storageZone: storageZone,
            customIcon: icon.isEmpty ? nil : icon,
            defaultShelfLifeDays: defaultShelfLifeDays,
            isHidden: isHidden
        ))
        dismiss()
    }
}

