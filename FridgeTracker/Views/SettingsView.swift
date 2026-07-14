import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import UIKit

struct SettingsView: View {
    private static let latestImportRecoveryPathKey = "latestImportRecoveryPath"
    @AppStorage("notificationsEnabled") private var notificationsEnabled = true
    @AppStorage("reminderDaysBefore") private var reminderDaysBefore = -1
    @AppStorage(HistoryMaintenance.retentionDaysKey) private var historyRetentionDays = -1
    @AppStorage(HistoryMaintenance.lastPruneErrorKey) private var historyPruneError = ""
    @AppStorage(WidgetDataStore.lastSyncTimestampKey) private var widgetSyncTimestamp = 0.0
    @AppStorage(WidgetDataStore.lastSyncErrorKey) private var widgetSyncError = ""
    @AppStorage(NotificationManager.desiredCountKey) private var notificationDesiredCount = 0
    @AppStorage(NotificationManager.scheduledCountKey) private var notificationScheduledCount = 0
    @AppStorage(NotificationManager.overflowCountKey) private var notificationOverflowCount = 0
    @AppStorage(NotificationManager.lastSchedulingErrorKey) private var notificationSchedulingError = ""
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
    @State private var notificationsNotDetermined = false
    @State private var pendingImport: FoodBackup?
    @State private var importPreviewMessage = ""
    @State private var showImportOptions = false
    @State private var isPreparingImport = false
    @State private var lastImportRecoveryURL: URL?
    @State private var lastStoreRecoveryURL: URL?

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

                    if notificationsEnabled && notificationsNotDetermined {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("尚未获得系统通知权限", systemImage: "bell.badge")
                                .font(.caption)
                                .foregroundStyle(.orange)
                            Button("授权过期提醒") {
                                Task { @MainActor in
                                    _ = await NotificationManager.shared.requestPermission()
                                    await refreshNotificationStatus()
                                    guard await NotificationManager.shared.isAuthorized() else { return }
                                    await NotificationManager.shared.reconcile(using: modelContext)
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

                        LabeledContent("安排状态") {
                            Text(notificationSchedulingStatusText)
                                .foregroundStyle(notificationSchedulingError.isEmpty ? Color.secondary : Color.orange)
                                .multilineTextAlignment(.trailing)
                        }
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
                    if !historyPruneError.isEmpty {
                        Text(historyPruneError)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Text("清理会删除保留期之前的吃掉/扔掉记录和已完成的补货记录；当前库存和待补货不受影响。选择期限后，每次启动也会自动清理超期记录。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("数据") {
                    Button("导出数据") {
                        prepareExport()
                    }
                    Button("导入数据") {
                        isImporting = true
                    }
                    .disabled(isPreparingImport)
                    if isPreparingImport {
                        ProgressView("正在验证备份…")
                            .font(.caption)
                    }
                    if let statusMessage {
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let lastImportRecoveryURL {
                        ShareLink(item: lastImportRecoveryURL) {
                            Label("导出导入前恢复点", systemImage: "arrow.uturn.backward.circle")
                        }
                    }
                    if let lastStoreRecoveryURL {
                        ShareLink(item: lastStoreRecoveryURL) {
                            Label("导出数据库恢复副本", systemImage: "externaldrive.badge.timemachine")
                        }
                        Text("包含重置或迁移前的数据库文件；确认新数据无误前请勿删除。")
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
                    Task { @MainActor in
                        await refreshNotificationStatus()
                        guard notificationsEnabled,
                              await NotificationManager.shared.isAuthorized() else { return }
                        await NotificationManager.shared.reconcile(using: modelContext)
                    }
                }
            }
            .onAppear {
                // 首次进入 + 每次切回设置页（含在别处刚被拒绝后切来）都同步一次
                lastImportRecoveryURL = Self.latestImportRecoveryURL()
                lastStoreRecoveryURL = StoreRecoveryLocation.latestAvailableURL()
                Task { await refreshNotificationStatus() }
            }
            .alert("清理历史记录？", isPresented: $showPruneConfirmation) {
                Button("取消", role: .cancel) {}
                Button("清理", role: .destructive) {
                    do {
                        let removed = try HistoryMaintenance.pruneOrThrow(
                            in: modelContext,
                            retentionDays: historyRetentionDays
                        )
                        historyPruneError = ""
                        pruneMessage = "已清理：吃掉/扔掉记录 \(removed.records) 条，已完成补货 \(removed.replenishments) 条"
                    } catch {
                        historyPruneError = "清理失败：\(error.localizedDescription)"
                        pruneMessage = "清理失败，数据未修改：\(error.localizedDescription)"
                    }
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
                prepareImport(from: result)
            }
            .confirmationDialog(
                "选择导入方式",
                isPresented: $showImportOptions,
                titleVisibility: .visible
            ) {
                Button("合并（保留本地重复项）") {
                    applyPendingImport(mode: .merge)
                }
                Button("完整替换本地数据", role: .destructive) {
                    applyPendingImport(mode: .replace)
                }
                Button("取消", role: .cancel) {
                    pendingImport = nil
                }
            } message: {
                Text(importPreviewMessage)
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

    private var notificationSchedulingStatusText: String {
        if notificationsNotDetermined { return "等待系统通知授权" }
        return NotificationManager.schedulingStatusText(
            desired: notificationDesiredCount,
            scheduled: notificationScheduledCount,
            overflow: notificationOverflowCount,
            error: notificationSchedulingError
        )
    }

    @MainActor
    private func refreshNotificationStatus() async {
        let status = await NotificationManager.shared.authorizationStatus()
        notificationsDenied = status == .denied
        notificationsNotDetermined = status == .notDetermined
    }

    private func prepareExport() {
        do {
            let items = try modelContext.fetch(FetchDescriptor<FoodItem>())
            let records = try modelContext.fetch(FetchDescriptor<FoodDispositionRecord>())
            let replenishments = try modelContext.fetch(FetchDescriptor<ReplenishmentItem>())
            exportDocument = FoodBackupDocument(
                items: items,
                records: records,
                replenishments: replenishments,
                settings: .current
            )
        } catch {
            exportDocument = nil
            statusMessage = "导出失败：无法读取完整数据（\(error.localizedDescription)）"
        }
    }

    private func prepareImport(from result: Result<URL, Error>) {
        isPreparingImport = true
        statusMessage = nil
        Task { @MainActor in
            do {
                let url = try result.get()
                let accessGranted = url.startAccessingSecurityScopedResource()
                defer {
                    if accessGranted { url.stopAccessingSecurityScopedResource() }
                    isPreparingImport = false
                }

                if let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                   fileSize > FoodBackup.maximumFileSize {
                    throw FoodBackupValidationError.fileTooLarge(actualBytes: fileSize)
                }

                let data = try await Task.detached(priority: .userInitiated) {
                    try Data(contentsOf: url, options: [.mappedIfSafe])
                }.value
                let backup = try await Task.detached(priority: .userInitiated) {
                    try FoodBackupDocument.decode(from: data)
                }.value

                let existingItems = try modelContext.fetch(FetchDescriptor<FoodItem>())
                let existingRecords = try modelContext.fetch(FetchDescriptor<FoodDispositionRecord>())
                let existingReplenishments = try modelContext.fetch(FetchDescriptor<ReplenishmentItem>())
                let incomingCount = backup.items.count
                    + (backup.dispositionRecords?.count ?? 0)
                    + (backup.replenishmentItems?.count ?? 0)
                let localCount = existingItems.count + existingRecords.count + existingReplenishments.count

                pendingImport = backup
                importPreviewMessage = "已验证 v\(backup.effectiveVersion) 备份，共 \(incomingCount) 条；本地现有 \(localCount) 条。合并会跳过相同 UUID/旧版业务批次并保留本地设置；完整替换会恢复备份内的数据与设置。"
                showImportOptions = true
            } catch {
                isPreparingImport = false
                pendingImport = nil
                statusMessage = "导入失败：\(error.localizedDescription)"
            }
        }
    }

    @MainActor
    private func applyPendingImport(mode: BackupImportMode) {
        guard let backup = pendingImport else { return }
        pendingImport = nil

        do {
            let existingItems = try modelContext.fetch(FetchDescriptor<FoodItem>())
            let existingRecords = try modelContext.fetch(FetchDescriptor<FoodDispositionRecord>())
            let existingReplenishments = try modelContext.fetch(FetchDescriptor<ReplenishmentItem>())
            if mode == .replace,
               let duplicateIdentity = BackupMergeIdentity.firstDuplicateIdentity(in: backup) {
                // A replacement promises to reproduce the backup exactly. Silently coalescing two
                // rows with the same non-nil identity breaks that promise, while restoring both
                // would poison UUID-based navigation, widgets, and notifications. Reject before
                // deleting any local data and let the user repair the malformed backup instead.
                throw BackupImportIdentityError.duplicateIdentity(duplicateIdentity)
            }
            let recoveryURL = mode == .replace
                ? try Self.createPreImportRecoveryCheckpoint(
                    items: existingItems,
                    records: existingRecords,
                    replenishments: existingReplenishments
                )
                : nil
            if let recoveryURL { lastImportRecoveryURL = recoveryURL }

            if mode == .replace {
                existingItems.forEach(modelContext.delete)
                existingRecords.forEach(modelContext.delete)
                existingReplenishments.forEach(modelContext.delete)
            }

            var itemUUIDs = mode == .merge ? Set(existingItems.map(\.uuid)) : Set<UUID>()
            // UUID-less v1 files need multiset semantics. A Set would collapse two genuinely
            // separate but byte-for-byte identical lots during their first merge. Compare each
            // incoming occurrence rank with the pre-import local multiplicity instead; this keeps
            // all lots on first import while making the same backup idempotent on later imports.
            let uuidlessInsertionMask = BackupMergeIdentity.uuidlessInsertionMask(
                existing: existingItems.map(BackupMergeIdentity.fingerprint),
                incoming: backup.items
                    .filter { $0.uuid == nil }
                    .map(BackupMergeIdentity.fingerprint),
                replacing: mode == .replace
            )
            var uuidlessInsertionIndex = 0
            var recordUUIDs = mode == .merge ? Set(existingRecords.map(\.uuid)) : Set<UUID>()
            var replenishmentUUIDs = mode == .merge ? Set(existingReplenishments.map(\.uuid)) : Set<UUID>()
            var pendingReplenishmentNames = mode == .merge
                ? Set(existingReplenishments.compactMap {
                    $0.completedAt == nil ? BackupMergeIdentity.normalizedName($0.name) : nil
                })
                : Set<String>()

            var insertedItems = 0
            var insertedRecords = 0
            var insertedReplenishments = 0
            var skipped = 0

            for backupItem in backup.items {
                let duplicate: Bool
                if let uuid = backupItem.uuid {
                    duplicate = mode == .merge && itemUUIDs.contains(uuid)
                } else {
                    duplicate = !uuidlessInsertionMask[uuidlessInsertionIndex]
                    uuidlessInsertionIndex += 1
                }
                guard !duplicate else { skipped += 1; continue }
                let item = backupItem.foodItem
                modelContext.insert(item)
                itemUUIDs.insert(item.uuid)
                insertedItems += 1
            }

            for backupRecord in backup.dispositionRecords ?? [] {
                guard !recordUUIDs.contains(backupRecord.uuid) else { skipped += 1; continue }
                modelContext.insert(backupRecord.record)
                recordUUIDs.insert(backupRecord.uuid)
                insertedRecords += 1
            }

            for backupItem in backup.replenishmentItems ?? [] {
                let normalizedPendingName = BackupMergeIdentity.normalizedName(backupItem.name)
                let duplicatesPendingName = BackupMergeIdentity.shouldSkipPendingReplenishment(
                    normalizedName: normalizedPendingName,
                    completedAt: backupItem.completedAt,
                    existingPendingNames: pendingReplenishmentNames,
                    merging: mode == .merge
                )
                guard !replenishmentUUIDs.contains(backupItem.uuid), !duplicatesPendingName else {
                    skipped += 1
                    continue
                }
                modelContext.insert(backupItem.replenishmentItem)
                replenishmentUUIDs.insert(backupItem.uuid)
                if backupItem.completedAt == nil {
                    pendingReplenishmentNames.insert(normalizedPendingName)
                }
                insertedReplenishments += 1
            }

            try modelContext.save()
            // 合并只合并业务记录，不能意外覆盖当前提醒/保留期等本地偏好；
            // 完整替换才恢复 v3 备份中的 app-owned settings。
            if mode == .replace, let settings = backup.settings {
                settings.apply()
                HistorySuggestionStore.shared.reloadFromDefaults()
            }
            WidgetDataStore.refresh(using: modelContext)

            Task { @MainActor in
                let shouldRequestPermission = UserDefaults.standard.object(forKey: "notificationsEnabled") as? Bool ?? true
                if shouldRequestPermission {
                    _ = await NotificationManager.shared.requestPermission()
                }
                await refreshNotificationStatus()
                await NotificationManager.shared.reconcile(using: modelContext)
            }

            let verb = mode == .replace ? "恢复" : "合并"
            statusMessage = "\(verb)完成：食材 \(insertedItems)，历史 \(insertedRecords)，补货 \(insertedReplenishments)"
                + (skipped > 0 ? "，跳过重复 \(skipped)" : "")
                + (recoveryURL == nil ? "" : "；导入前恢复点已保留")
        } catch {
            modelContext.rollback()
            statusMessage = "导入失败，未修改本地数据：\(error.localizedDescription)"
        }
    }

    private static func createPreImportRecoveryCheckpoint(
        items: [FoodItem],
        records: [FoodDispositionRecord],
        replenishments: [ReplenishmentItem]
    ) throws -> URL {
        let backup = FoodBackup(
            version: FoodBackup.currentVersion,
            items: items.map(FoodBackupItem.init),
            dispositionRecords: records.map(DispositionBackupItem.init),
            replenishmentItems: replenishments.map(ReplenishmentBackupItem.init),
            settings: .current
        )
        let data = try FoodBackupDocument.encode(backup)
        let fileManager = FileManager.default
        let root = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("FridgeTracker-Recovery", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let directory = root.appendingPathComponent(
            "\(stamp)-pre-import-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("FridgeTracker-PreImport.json")
        try data.write(to: url, options: [.atomic])
        UserDefaults.standard.set(url.path, forKey: latestImportRecoveryPathKey)
        pruneOldImportRecoveryDirectories(in: root, keeping: 5)
        return url
    }

    private static func latestImportRecoveryURL() -> URL? {
        let fileManager = FileManager.default
        if let path = UserDefaults.standard.string(forKey: latestImportRecoveryPathKey),
           fileManager.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        guard let root = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ).appendingPathComponent("FridgeTracker-Recovery", isDirectory: true),
        let directories = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        return directories
            .filter { $0.lastPathComponent.contains("-pre-import-") }
            .sorted {
                let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhs > rhs
            }
            .map { $0.appendingPathComponent("FridgeTracker-PreImport.json") }
            .first { fileManager.fileExists(atPath: $0.path) }
    }

    private static func pruneOldImportRecoveryDirectories(in root: URL, keeping limit: Int) {
        let fileManager = FileManager.default
        guard let directories = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let importDirectories = directories
            .filter { $0.lastPathComponent.contains("-pre-import-") }
            .sorted {
                let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhs > rhs
            }
        for directory in importDirectories.dropFirst(max(limit, 0)) {
            try? fileManager.removeItem(at: directory)
        }
    }
}

enum BackupMergeIdentity {
    struct FoodLotFingerprint: Hashable, Sendable {
        let name: String
        let categoryID: String
        let storageZone: String
        let customIcon: String?
        let purchaseDateWholeSecondBits: UInt64?
        let expiryDateWholeSecondBits: UInt64
        let quantity: String?
        let notes: String?
        let createdAtWholeSecondBits: UInt64
        let originalShelfLifeDays: Int?
    }

    enum DuplicateIdentity: Equatable, Sendable {
        case foodItem(UUID)
        case dispositionRecord(UUID)
        case replenishmentItem(UUID)
    }

    static func normalizedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
    }

    static func fingerprint(_ item: FoodItem) -> FoodLotFingerprint {
        return FoodLotFingerprint(
            name: normalizedName(item.name),
            categoryID: item.stableCategoryID.rawValue,
            storageZone: item.storageZone.rawValue,
            customIcon: normalizedOptionalText(item.customIcon),
            // v1 had no civil-day keys. Its raw timestamps are still preserved on FoodItem after
            // restore, so they are the only identity that stays stable when the user changes
            // timezone between the first and a later merge.
            purchaseDateWholeSecondBits: item.purchaseDate.map(wholeSecondBits),
            expiryDateWholeSecondBits: wholeSecondBits(item.expiryDate),
            quantity: normalizedOptionalText(item.quantity),
            notes: normalizedOptionalText(item.notes),
            createdAtWholeSecondBits: wholeSecondBits(item.createdAt),
            originalShelfLifeDays: resolvedShelfLifeDays(
                purchaseDate: item.purchaseDate,
                expiryDate: item.expiryDate,
                createdAt: item.createdAt
            )
        )
    }

    static func fingerprint(_ item: FoodBackupItem) -> FoodLotFingerprint {
        return FoodLotFingerprint(
            name: normalizedName(item.name),
            categoryID: (item.categoryID ?? item.category.stableID).rawValue,
            storageZone: item.storageZone.rawValue,
            customIcon: normalizedOptionalText(item.customIcon),
            purchaseDateWholeSecondBits: item.purchaseDate.map(wholeSecondBits),
            expiryDateWholeSecondBits: wholeSecondBits(item.expiryDate),
            quantity: normalizedOptionalText(item.quantity),
            notes: normalizedOptionalText(item.notes),
            createdAtWholeSecondBits: wholeSecondBits(item.createdAt),
            originalShelfLifeDays: resolvedShelfLifeDays(
                purchaseDate: item.purchaseDate,
                expiryDate: item.expiryDate,
                createdAt: item.createdAt
            )
        )
    }

    /// Returns one decision per incoming UUID-less fingerprint without mutating either collection.
    /// Merge computes the multiset difference `incoming - existing`, preserving occurrence order.
    /// Replace preserves the backup's exact multiplicity because identical fields do not imply the
    /// same physical inventory lot.
    static func uuidlessInsertionMask(
        existing: [FoodLotFingerprint],
        incoming: [FoodLotFingerprint],
        replacing: Bool
    ) -> [Bool] {
        if replacing {
            return Array(repeating: true, count: incoming.count)
        }

        var existingCounts: [FoodLotFingerprint: Int] = [:]
        for fingerprint in existing {
            existingCounts[fingerprint, default: 0] += 1
        }

        var incomingCounts: [FoodLotFingerprint: Int] = [:]
        return incoming.map { fingerprint in
            incomingCounts[fingerprint, default: 0] += 1
            return incomingCounts[fingerprint, default: 0]
                > existingCounts[fingerprint, default: 0]
        }
    }

    static func firstDuplicateIdentity(in backup: FoodBackup) -> DuplicateIdentity? {
        var foodItemUUIDs = Set<UUID>()
        for uuid in backup.items.compactMap(\.uuid) where !foodItemUUIDs.insert(uuid).inserted {
            return .foodItem(uuid)
        }

        var recordUUIDs = Set<UUID>()
        for uuid in (backup.dispositionRecords ?? []).map(\.uuid)
            where !recordUUIDs.insert(uuid).inserted {
            return .dispositionRecord(uuid)
        }

        var replenishmentUUIDs = Set<UUID>()
        for uuid in (backup.replenishmentItems ?? []).map(\.uuid)
            where !replenishmentUUIDs.insert(uuid).inserted {
            return .replenishmentItem(uuid)
        }
        return nil
    }

    static func shouldSkipPendingReplenishment(
        normalizedName: String,
        completedAt: Date?,
        existingPendingNames: Set<String>,
        merging: Bool
    ) -> Bool {
        merging && completedAt == nil && existingPendingNames.contains(normalizedName)
    }

    private static func normalizedOptionalText(_ value: String?) -> String? {
        value?.precomposedStringWithCanonicalMapping
    }

    private static func wholeSecondBits(_ date: Date) -> UInt64 {
        // Avoid Int64 conversion traps for a corrupted local Date while retaining the backup
        // encoder's whole-second comparison precision.
        date.timeIntervalSince1970.rounded(.down).bitPattern
    }

    private static func resolvedShelfLifeDays(
        purchaseDate: Date?,
        expiryDate: Date,
        createdAt: Date
    ) -> Int? {
        guard purchaseDate == nil else { return nil }
        let utc = TimeZone(secondsFromGMT: 0)!
        return FoodShelfLifeConstraints.clamped(
            LocalDate(date: createdAt, timeZone: utc)
                .days(until: LocalDate(date: expiryDate, timeZone: utc))
        )
    }
}

private enum BackupImportIdentityError: LocalizedError {
    case duplicateIdentity(BackupMergeIdentity.DuplicateIdentity)

    var errorDescription: String? {
        switch self {
        case .duplicateIdentity(let identity):
            switch identity {
            case .foodItem(let value):
                return duplicateIdentityMessage(kind: "食材", uuid: value)
            case .dispositionRecord(let value):
                return duplicateIdentityMessage(kind: "历史记录", uuid: value)
            case .replenishmentItem(let value):
                return duplicateIdentityMessage(kind: "补货项", uuid: value)
            }
        }
    }

    private func duplicateIdentityMessage(kind: String, uuid: UUID) -> String {
        "备份包含重复\(kind) UUID（\(uuid.uuidString)），为避免恢复出身份冲突的数据，已取消导入。"
    }
}

private enum BackupImportMode {
    case merge
    case replace
}

struct HistorySuggestionManagementView: View {
    @Query(sort: \FoodItem.createdAt, order: .reverse) private var items: [FoodItem]
    @Query(sort: \FoodDispositionRecord.createdAt, order: .reverse) private var dispositionRecords: [FoodDispositionRecord]
    @ObservedObject private var historySuggestionStore = HistorySuggestionStore.shared
    @State private var templates: [FoodTemplate] = []
    @State private var hasLoadedTemplates = false

    var body: some View {
        List {
            if hasLoadedTemplates && templates.isEmpty {
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
        .onAppear { rebuildTemplates() }
        .onChange(of: items.count) { _, _ in rebuildTemplates() }
        .onChange(of: dispositionRecords.count) { _, _ in rebuildTemplates() }
    }

    private func rebuildTemplates() {
        templates = FoodTemplate.fromHistory(items, records: dispositionRecords)
        hasLoadedTemplates = true
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
                    .lineLimit(nil)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(template.name)，\(template.category.rawValue)，\(template.storageZone.rawValue)，约 \(template.defaultShelfLifeDays) 天\(isHidden ? "，已隐藏" : "")"
        )
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
    @State private var saveErrorMessage: String?

    init(template: FoodTemplate) {
        self.template = template
        let override = HistorySuggestionStore.shared.override(for: template.normalizedName)
        let editableTemplate = template.applying(override)
        _category = State(initialValue: editableTemplate.category)
        _storageZone = State(initialValue: editableTemplate.storageZone)
        _customIcon = State(initialValue: editableTemplate.customIcon ?? "")
        _defaultShelfLifeDays = State(initialValue: editableTemplate.defaultShelfLifeDays)
        _isHidden = State(initialValue: override?.isHidden == true)
        _saveErrorMessage = State(initialValue: nil)
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
        .alert("无法保存", isPresented: Binding(
            get: { saveErrorMessage != nil },
            set: { if !$0 { saveErrorMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(saveErrorMessage ?? "请检查输入后重试。")
        }
    }

    private func save() {
        let icon = customIcon.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try historySuggestionStore.save(HistorySuggestionOverride(
                name: template.normalizedName,
                category: category,
                storageZone: storageZone,
                customIcon: icon.isEmpty ? nil : icon,
                defaultShelfLifeDays: defaultShelfLifeDays,
                isHidden: isHidden
            ))
            dismiss()
        } catch {
            saveErrorMessage = error.localizedDescription
        }
    }
}
