import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct SettingsView: View {
    @AppStorage("notificationsEnabled") private var notificationsEnabled = true
    @AppStorage("reminderDaysBefore") private var reminderDaysBefore = -1
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \FoodItem.createdAt) private var allItems: [FoodItem]
    @ObservedObject private var historySuggestionStore = HistorySuggestionStore.shared
    @State private var exportDocument: FoodBackupDocument?
    @State private var isImporting = false
    @State private var statusMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("提醒") {
                    Toggle("开启过期提醒", isOn: $notificationsEnabled)

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

                        Text("分类默认会让肉类/海鲜提前 2 天、冷冻食品提前 7 天，其他食材提前 1 天提醒；已过期或提醒时间已错过的食材不会继续创建新通知。")
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
                        HistorySuggestionManagementView(items: allItems)
                    }
                }

                Section("数据") {
                    Button("导出数据") {
                        exportDocument = FoodBackupDocument(items: allItems)
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

                Section("关于") {
                    LabeledContent("App 名称", value: "FridgeTracker")
                    LabeledContent("版本", value: appVersion)
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: notificationsEnabled) { _, enabled in
                if enabled {
                    Task { _ = await NotificationManager.shared.requestPermission() }
                }
                NotificationManager.shared.rescheduleAll(for: allItems)
            }
            .onChange(of: reminderDaysBefore) { _, _ in
                NotificationManager.shared.rescheduleAll(for: allItems)
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
            for item in backup.items {
                modelContext.insert(item.foodItem)
            }
            WidgetDataStore.refresh(using: modelContext)
            statusMessage = "导入完成：\(backup.items.count) 条记录"
        } catch {
            statusMessage = "导入失败：\(error.localizedDescription)"
        }
    }
}

struct HistorySuggestionManagementView: View {
    let items: [FoodItem]
    @ObservedObject private var historySuggestionStore = HistorySuggestionStore.shared

    private var templates: [FoodTemplate] {
        FoodTemplate.fromHistory(items)
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

