import XCTest
import SwiftData
@testable import FridgeTracker

/// `HistoryMaintenance.prune` 的正确性与性能基线。
///
/// 关键契约：只删「保留期之前的处置记录」和「保留期之前完成的补货项」；
/// 待补货项（completedAt == nil）与当前库存（FoodItem）无论多老都不动；
/// retentionDays <= 0（永久保留）时是无操作。
@MainActor
final class HistoryMaintenanceTests: XCTestCase {

    private let calendar = Calendar.current
    private let now = Date()

    /// 隔离 suite，绝不写 UserDefaults.standard：单测宿主就是真实 app 进程，
    /// standard 里残留的保留期会在下次启动时静默清理真实历史数据。
    private static let defaultsSuiteName = "HistoryMaintenanceTests"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: Self.defaultsSuiteName)!
        defaults.removePersistentDomain(forName: Self.defaultsSuiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: Self.defaultsSuiteName)
        defaults = nil
        super.tearDown()
    }

    private func date(daysAgo: Int) -> Date {
        calendar.date(byAdding: .day, value: -daysAgo, to: now)!
    }

    private func makeRecord(in context: ModelContext, daysAgo: Int, name: String = "牛奶") -> FoodDispositionRecord {
        let record = FoodDispositionRecord(
            uuid: UUID(), foodName: name, category: .dairy, storageZone: .fridge,
            customIcon: nil, quantity: nil, purchaseDate: nil, expiryDate: now,
            shelfLifeDaysEstimate: 7, action: .consumed, createdAt: date(daysAgo: daysAgo)
        )
        context.insert(record)
        return record
    }

    private func makeReplenishment(in context: ModelContext, createdDaysAgo: Int, completedDaysAgo: Int?) -> ReplenishmentItem {
        let item = ReplenishmentItem(
            uuid: UUID(), name: "鸡蛋", category: .egg, storageZone: .fridge,
            customIcon: nil, quantity: nil, notes: nil, defaultShelfLifeDays: 10,
            createdAt: date(daysAgo: createdDaysAgo),
            completedAt: completedDaysAgo.map { date(daysAgo: $0) }
        )
        context.insert(item)
        return item
    }

    private func recordCount(in context: ModelContext) -> Int {
        (try? context.fetchCount(FetchDescriptor<FoodDispositionRecord>())) ?? -1
    }

    private func replenishmentCount(in context: ModelContext) -> Int {
        (try? context.fetchCount(FetchDescriptor<ReplenishmentItem>())) ?? -1
    }

    // MARK: - 处置记录

    func testPruneDeletesRecordsOlderThanRetention() throws {
        let context = try TestModelContainer.makeContext()
        makeRecord(in: context, daysAgo: 120)
        makeRecord(in: context, daysAgo: 91)
        makeRecord(in: context, daysAgo: 30)
        makeRecord(in: context, daysAgo: 0)

        let removed = HistoryMaintenance.prune(in: context, retentionDays: 90, now: now)

        XCTAssertEqual(removed.records, 2)
        XCTAssertEqual(recordCount(in: context), 2)
    }

    func testPruneKeepsRecordExactlyAtCutoff() throws {
        // cutoff 当天 0 点整的记录不算「之前」，应保留（createdAt < cutoff 为严格小于）。
        let context = try TestModelContainer.makeContext()
        let cutoff = calendar.date(byAdding: .day, value: -90, to: now)!
        let record = FoodDispositionRecord(
            uuid: UUID(), foodName: "米饭", category: .other, storageZone: .pantry,
            customIcon: nil, quantity: nil, purchaseDate: nil, expiryDate: now,
            shelfLifeDaysEstimate: 3, action: .consumed, createdAt: cutoff
        )
        context.insert(record)

        let removed = HistoryMaintenance.prune(in: context, retentionDays: 90, now: now)

        XCTAssertEqual(removed.records, 0)
        XCTAssertEqual(recordCount(in: context), 1)
    }

    // MARK: - 补货项

    func testPruneKeepsPendingReplenishmentRegardlessOfAge() throws {
        let context = try TestModelContainer.makeContext()
        makeReplenishment(in: context, createdDaysAgo: 400, completedDaysAgo: nil)

        let removed = HistoryMaintenance.prune(in: context, retentionDays: 90, now: now)

        XCTAssertEqual(removed.replenishments, 0)
        XCTAssertEqual(replenishmentCount(in: context), 1)
    }

    func testPruneDeletesOnlyStaleCompletedReplenishments() throws {
        let context = try TestModelContainer.makeContext()
        makeReplenishment(in: context, createdDaysAgo: 200, completedDaysAgo: 150) // 超龄已完成 → 删
        makeReplenishment(in: context, createdDaysAgo: 200, completedDaysAgo: 10)  // 新近完成 → 留
        makeReplenishment(in: context, createdDaysAgo: 200, completedDaysAgo: nil) // 待补货 → 留

        let removed = HistoryMaintenance.prune(in: context, retentionDays: 90, now: now)

        XCTAssertEqual(removed.replenishments, 1)
        XCTAssertEqual(replenishmentCount(in: context), 2)
    }

    // MARK: - 策略开关

    func testPruneWithNonPositiveRetentionIsNoOp() throws {
        let context = try TestModelContainer.makeContext()
        makeRecord(in: context, daysAgo: 400)

        XCTAssertEqual(HistoryMaintenance.prune(in: context, retentionDays: -1, now: now).records, 0)
        XCTAssertEqual(HistoryMaintenance.prune(in: context, retentionDays: 0, now: now).records, 0)
        XCTAssertEqual(recordCount(in: context), 1)
    }

    func testPruneIfEnabledHonorsStoredRetentionSetting() throws {
        let context = try TestModelContainer.makeContext()
        makeRecord(in: context, daysAgo: 120)
        makeRecord(in: context, daysAgo: 10)

        defaults.set(90, forKey: HistoryMaintenance.retentionDaysKey)
        HistoryMaintenance.pruneIfEnabled(in: context, defaults: defaults, now: now)

        XCTAssertEqual(recordCount(in: context), 1)
    }

    func testPruneIfEnabledDefaultsToKeepForever() throws {
        let context = try TestModelContainer.makeContext()
        makeRecord(in: context, daysAgo: 1000)

        // 未设置过保留期（干净 suite）→ 默认 -1 永久保留，不删任何数据
        HistoryMaintenance.pruneIfEnabled(in: context, defaults: defaults, now: now)

        XCTAssertEqual(recordCount(in: context), 1)
    }

    // MARK: - 性能（对应审查报告「导入 500+ 条历史记录，观察查询速度」）

    /// 3000 条记录下历史模板聚合的耗时基线；回归时该 measure 会显著变慢。
    func testHistoryTemplatePerformanceWithThousandsOfRecords() throws {
        let context = try TestModelContainer.makeContext()
        for index in 0..<3000 {
            makeRecord(in: context, daysAgo: index % 365, name: "食材\(index % 120)")
        }
        try context.save()
        let records = try context.fetch(FetchDescriptor<FoodDispositionRecord>())
        let items: [FoodItem] = []

        measure {
            _ = FoodTemplate.fromHistory(items, records: records)
        }
    }

    /// 3000 条超龄记录一次清理应在秒级完成（宽松上界，防回归不防抖动）。
    func testPruneThousandsOfRecordsCompletesQuickly() throws {
        let context = try TestModelContainer.makeContext()
        for index in 0..<3000 {
            makeRecord(in: context, daysAgo: 100 + index % 200, name: "食材\(index % 120)")
        }
        try context.save()

        let start = Date()
        let removed = HistoryMaintenance.prune(in: context, retentionDays: 90, now: now)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(removed.records, 3000)
        XCTAssertEqual(recordCount(in: context), 0)
        XCTAssertLessThan(elapsed, 5.0, "3000 条记录的清理耗时异常")
    }
}
