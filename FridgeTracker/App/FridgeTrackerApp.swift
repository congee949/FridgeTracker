import SwiftUI
import SwiftData
import CoreData
import UIKit
import UserNotifications

/// App-hosted unit tests launch the real application process before XCTest starts executing test
/// methods. Relying only on the UI-test `-uitesting` argument lets that host open the production
/// App Group store and overwrite the Widget snapshot. Keep every automated test in memory and away
/// from cross-process user data.
enum AppRuntime {
    private static let xctestEnvironmentKeys = [
        "XCTestConfigurationFilePath",
        "XCTestBundlePath",
        "XCInjectBundleInto"
    ]

    nonisolated static func isAutomatedTest(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        if arguments.contains("-uitesting") { return true }
        if xctestEnvironmentKeys.contains(where: { environment[$0]?.isEmpty == false }) {
            return true
        }
        return environment["DYLD_INSERT_LIBRARIES"]?
            .localizedCaseInsensitiveContains("XCTest") == true
    }
}

/// SwiftData chooses the App Group store URL from the target entitlements, but on a freshly
/// installed iOS 27 app its `Library/Application Support` parent may not exist yet. Core Data does
/// not reliably create that intermediate directory itself, so prepare it before opening the store
/// while preserving SwiftData's exact URL for existing installations.
enum PersistentStorePreparation {
    nonisolated static func createParentDirectory(
        for storeURL: URL,
        fileManager: FileManager = .default
    ) throws {
        try fileManager.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }
}

@main
struct FridgeTrackerApp: App {
    @StateObject private var bootstrap: AppBootstrap

    init() {
        _bootstrap = StateObject(wrappedValue: AppBootstrap())
        configureTabBarAppearance()
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let container = bootstrap.container {
                    ContentView()
                        .modelContainer(container)
                } else {
                    StoreRecoveryView(bootstrap: bootstrap)
                }
            }
        }
    }

    private func configureTabBarAppearance() {
        let appearance = UITabBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.backgroundEffect = UIBlurEffect(style: .systemChromeMaterial)
        appearance.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.78)
        appearance.shadowColor = UIColor.separator.withAlphaComponent(0.35)

        let selectedColor = UIColor.tintColor
        let normalColor = UIColor.secondaryLabel

        [appearance.stackedLayoutAppearance, appearance.inlineLayoutAppearance, appearance.compactInlineLayoutAppearance].forEach { itemAppearance in
            itemAppearance.selected.iconColor = selectedColor
            itemAppearance.selected.titleTextAttributes = [.foregroundColor: selectedColor]
            itemAppearance.normal.iconColor = normalColor
            itemAppearance.normal.titleTextAttributes = [.foregroundColor: normalColor]
        }

        let tabBar = UITabBar.appearance()
        tabBar.standardAppearance = appearance
        tabBar.scrollEdgeAppearance = appearance
        tabBar.isTranslucent = true
    }
}

@MainActor
final class AppBootstrap: ObservableObject {
    @Published private(set) var container: ModelContainer?
    @Published private(set) var startupError: String?
    @Published private(set) var recoveryURL: URL?

    private let inMemory = AppRuntime.isAutomatedTest()

    init() {
        load()
    }

    func retry() {
        load()
    }

    func resetStore() {
        do {
            let (_, configuration) = try makeSchemaAndConfiguration()
            if !inMemory, FileManager.default.fileExists(atPath: configuration.url.path) {
                recoveryURL = try quarantineStore(at: configuration.url, reason: "manual-reset")
            }
            container = nil
            startupError = nil
            load()
        } catch {
            startupError = "无法重置数据库：\(error.localizedDescription)"
        }
    }

    private func load() {
        do {
            let (schema, configuration) = try makeSchemaAndConfiguration()
            if !inMemory {
                try prepareMigrationBackupIfNeeded(storeURL: configuration.url)
            }
            let modelContainer = try ModelContainer(
                for: schema,
                migrationPlan: FridgeTrackerMigrationPlan.self,
                configurations: configuration
            )
            modelContainer.mainContext.autosaveEnabled = false
            try backfillStableFields(in: modelContainer.mainContext)
            container = modelContainer
            startupError = nil
        } catch {
            container = nil
            startupError = "数据库无法打开或迁移失败：\(error.localizedDescription)"
        }
    }

    private func makeSchemaAndConfiguration() throws -> (Schema, ModelConfiguration) {
        let schema = Schema(versionedSchema: FridgeTrackerSchemaV2.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
        if !inMemory {
            try PersistentStorePreparation.createParentDirectory(for: configuration.url)
        }
        return (schema, configuration)
    }

    private func backfillStableFields(in context: ModelContext) throws {
        // This stays a full, idempotent scan for migration safety. Complex optional-field
        // #Predicates currently make the Swift compiler time out; conditional assignments below
        // ensure subsequent launches do not dirty or resave unchanged rows.
        for item in try context.fetch(FetchDescriptor<FoodItem>()) {
            item.synchronizeStableFields()
            if item.purchaseLocalDate == nil {
                let normalized = FoodShelfLifeConstraints.clamped(
                    item.originalShelfLifeDays
                        ?? LocalDate(date: item.createdAt).days(until: item.expiryLocalDate)
                )
                if item.originalShelfLifeDays != normalized {
                    item.originalShelfLifeDays = normalized
                }
            } else if item.originalShelfLifeDays != nil {
                item.originalShelfLifeDays = nil
            }
        }
        for record in try context.fetch(FetchDescriptor<FoodDispositionRecord>()) {
            if record.purchaseDayKey == nil {
                record.purchaseDayKey = record.purchaseDate.map { LocalDate(date: $0).iso8601DateString }
            }
            if record.expiryDayKey == nil {
                record.expiryDayKey = LocalDate(date: record.expiryDate).iso8601DateString
            }
            if record.categoryIDRaw == nil { record.categoryIDRaw = record.category.stableID.rawValue }
            if record.updatedAt == nil { record.updatedAt = record.createdAt }
            let normalizedShelfLife = FoodShelfLifeConstraints.clamped(record.shelfLifeDaysEstimate)
            if record.shelfLifeDaysEstimate != normalizedShelfLife {
                record.shelfLifeDaysEstimate = normalizedShelfLife
            }
        }
        for item in try context.fetch(FetchDescriptor<ReplenishmentItem>()) {
            if item.categoryIDRaw == nil { item.categoryIDRaw = item.category.stableID.rawValue }
            if item.updatedAt == nil { item.updatedAt = item.completedAt ?? item.createdAt }
            let normalizedShelfLife = FoodShelfLifeConstraints.clamped(item.defaultShelfLifeDays)
            if item.defaultShelfLifeDays != normalizedShelfLife {
                item.defaultShelfLifeDays = normalizedShelfLife
            }
        }
        if context.hasChanges { try context.save() }
    }

    private func prepareMigrationBackupIfNeeded(storeURL: URL) throws {
        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            return
        }

        do {
            let identifiers = try validateStoreIdentity(at: storeURL)
            // Migration truth belongs to the store metadata. A global defaults marker can
            // outlive a file replacement, so every recognized non-current store gets its own
            // recovery copy immediately before SwiftData opens and migrates it.
            if identifiers != ["2.0.0"], recoveryURL == nil {
                recoveryURL = try copyStore(at: storeURL, reason: "pre-migration")
            }
        } catch {
            if recoveryURL == nil {
                recoveryURL = try copyStore(at: storeURL, reason: "identity-rejected")
            }
            throw error
        }
    }

    /// SwiftData/Core Data can treat a valid but unrelated SQLite store as a migratable source and
    /// create empty FridgeTracker tables.  Verify the published entity set before allowing any
    /// automatic migration; a rejected store has already been copied to the recovery directory.
    private func validateStoreIdentity(at storeURL: URL) throws -> Set<String> {
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
            ofType: NSSQLiteStoreType,
            at: storeURL,
            options: [NSReadOnlyPersistentStoreOption: true]
        )
        guard let hashes = metadata[NSStoreModelVersionHashesKey] as? [String: Any] else {
            throw StoreIdentityError.missingModelMetadata
        }
        let expectedEntities: Set<String> = ["FoodItem", "FoodDispositionRecord", "ReplenishmentItem"]
        guard Set(hashes.keys) == expectedEntities else {
            throw StoreIdentityError.unrecognizedEntities(Set(hashes.keys))
        }

        let identifiers: [String]
        if let values = metadata[NSStoreModelVersionIdentifiersKey] as? [String] {
            identifiers = values
        } else if let values = metadata[NSStoreModelVersionIdentifiersKey] as? Set<String> {
            identifiers = Array(values)
        } else {
            identifiers = []
        }
        let knownIdentifiers: Set<String> = ["1.0.0", "2.0.0"]
        guard !identifiers.isEmpty, Set(identifiers).isSubset(of: knownIdentifiers) else {
            throw StoreIdentityError.unrecognizedVersion(identifiers)
        }
        return Set(identifiers)
    }

    private func copyStore(at storeURL: URL, reason: String) throws -> URL {
        let directory = try makeRecoveryDirectory(reason: reason)
        try copyStoreFamily(at: storeURL, to: directory)
        StoreRecoveryLocation.record(directory)
        return directory
    }

    private func quarantineStore(at storeURL: URL, reason: String) throws -> URL {
        let directory = try makeRecoveryDirectory(reason: reason)
        // Copy the complete family first. If copying fails, the original is untouched. Once the
        // recovery copy exists, remove the primary store before its sidecars: if primary removal
        // fails the original family is still complete; if a later sidecar removal fails there is
        // no truncated primary database left at the live URL for Retry to reopen accidentally.
        try copyStoreFamily(at: storeURL, to: directory)
        recoveryURL = directory
        StoreRecoveryLocation.record(directory)
        try removeOriginalStoreFamily(at: storeURL)
        return directory
    }

    private func makeRecoveryDirectory(reason: String) throws -> URL {
        let fileManager = FileManager.default
        let root = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("FridgeTracker-Recovery", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        let timestamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let directory = root.appendingPathComponent("\(timestamp)-\(reason)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func copyStoreFamily(at storeURL: URL, to directory: URL) throws {
        let fileManager = FileManager.default
        let candidates = [
            storeURL,
            URL(fileURLWithPath: storeURL.path + "-wal"),
            URL(fileURLWithPath: storeURL.path + "-shm")
        ]
        for source in candidates where fileManager.fileExists(atPath: source.path) {
            let destination = directory.appendingPathComponent(source.lastPathComponent)
            try fileManager.copyItem(at: source, to: destination)
        }
    }

    private func removeOriginalStoreFamily(at storeURL: URL) throws {
        let fileManager = FileManager.default
        let candidates = [
            storeURL,
            URL(fileURLWithPath: storeURL.path + "-wal"),
            URL(fileURLWithPath: storeURL.path + "-shm")
        ]
        for source in candidates where fileManager.fileExists(atPath: source.path) {
            try fileManager.removeItem(at: source)
        }
    }
}

/// Store-family recovery copies must remain reachable after a successful reset switches the root
/// UI back to ContentView. Persisting only AppBootstrap.recoveryURL made the sole ShareLink vanish.
enum StoreRecoveryLocation {
    nonisolated static let latestPathKey = "latestStoreRecoveryPath"

    @MainActor
    static func record(_ url: URL, defaults: UserDefaults = .standard) {
        defaults.set(url.path, forKey: latestPathKey)
    }

    @MainActor
    static func latestAvailableURL(defaults: UserDefaults = .standard) -> URL? {
        guard let path = defaults.string(forKey: latestPathKey),
              FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}

private enum StoreIdentityError: LocalizedError {
    case missingModelMetadata
    case unrecognizedEntities(Set<String>)
    case unrecognizedVersion([String])

    var errorDescription: String? {
        switch self {
        case .missingModelMetadata:
            return "数据库缺少可验证的模型信息，已停止迁移"
        case .unrecognizedEntities(let entities):
            return "数据库模型不属于 FridgeTracker（\(entities.sorted().joined(separator: ", "))），已停止迁移"
        case .unrecognizedVersion(let identifiers):
            return "数据库版本无法识别（\(identifiers.joined(separator: ", "))），已停止迁移"
        }
    }
}

enum FridgeTrackerSchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [FoodItem.self, FoodDispositionRecord.self, ReplenishmentItem.self]
    }
}

enum FridgeTrackerMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [FridgeTrackerSchemaV2.self] }
    static var stages: [MigrationStage] { [] }
}

private struct StoreRecoveryView: View {
    @ObservedObject var bootstrap: AppBootstrap
    @State private var showResetConfirmation = false

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("无法打开数据", systemImage: "externaldrive.badge.exclamationmark")
            } description: {
                Text(bootstrap.startupError ?? "数据库暂时不可用。原始文件仍被保留，没有创建空数据库覆盖它。")
            } actions: {
                VStack(spacing: 12) {
                    Button("重试") { bootstrap.retry() }
                        .buttonStyle(.borderedProminent)
                    if let recoveryURL = bootstrap.recoveryURL {
                        ShareLink(item: recoveryURL) {
                            Label("导出恢复副本", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.bordered)
                    }
                    Button("隔离原库并重新开始", role: .destructive) {
                        showResetConfirmation = true
                    }
                }
            }
            .padding()
            .navigationTitle("数据恢复")
            .alert("确认重新开始？", isPresented: $showResetConfirmation) {
                Button("取消", role: .cancel) {}
                Button("隔离并重置", role: .destructive) { bootstrap.resetStore() }
            } message: {
                Text("原数据库会移动到恢复目录，不会直接删除；App 随后创建新的空数据库。")
            }
        }
    }
}
