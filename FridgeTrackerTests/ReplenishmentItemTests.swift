import XCTest
import SwiftData
@testable import FridgeTracker

/// Regression baseline for the auto-replenishment business rules implemented as static
/// methods on `ReplenishmentItem` (`FridgeTracker/Models/FoodItem.swift`): `addIfAbsent`,
/// `autoAddIfNeeded`, the `autoReplenishThreshold`, and the 30-day consumed-records window.
@MainActor
final class ReplenishmentItemTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        try TestModelContainer.makeContext()
    }

    private func makeItem(name: String, category: FoodCategory = .other) -> FoodItem {
        FoodItem(name: name, category: category, storageZone: .fridge, expiryDate: Date())
    }

    /// Inserts a disposition record with a precise `createdAt`, using the field-level initializer.
    private func insertRecord(
        _ context: ModelContext,
        name: String,
        action: FoodDispositionAction,
        daysAgo: Int
    ) {
        let createdAt = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
        context.insert(FoodDispositionRecord(
            uuid: UUID(),
            foodName: name,
            category: .other,
            storageZone: .fridge,
            customIcon: nil,
            quantity: nil,
            purchaseDate: nil,
            expiryDate: Date(),
            shelfLifeDaysEstimate: 7,
            action: action,
            createdAt: createdAt
        ))
    }

    private func activeReplenishmentCount(_ context: ModelContext, name: String) throws -> Int {
        try context.fetch(FetchDescriptor<ReplenishmentItem>())
            .filter { $0.completedAt == nil && $0.name == name }
            .count
    }

    // MARK: - threshold constant

    func testAutoReplenishThresholdIsTwo() {
        XCTAssertEqual(ReplenishmentItem.autoReplenishThreshold, 2)
    }

    // MARK: - addIfAbsent

    func testAddIfAbsentInsertsWhenNoneExists() throws {
        let context = try makeContext()
        let inserted = ReplenishmentItem.addIfAbsent(for: makeItem(name: "牛奶"), in: context)
        XCTAssertTrue(inserted)
        XCTAssertEqual(try activeReplenishmentCount(context, name: "牛奶"), 1)
    }

    func testAddIfAbsentReturnsFalseWhenActiveExists() throws {
        let context = try makeContext()
        XCTAssertTrue(ReplenishmentItem.addIfAbsent(for: makeItem(name: "牛奶"), in: context))
        let second = ReplenishmentItem.addIfAbsent(for: makeItem(name: "牛奶"), in: context)
        XCTAssertFalse(second)
        XCTAssertEqual(try activeReplenishmentCount(context, name: "牛奶"), 1)
    }

    func testAddIfAbsentInsertsWhenExistingIsCompleted() throws {
        let context = try makeContext()
        let completed = ReplenishmentItem(item: makeItem(name: "牛奶"))
        completed.completedAt = Date()
        context.insert(completed)

        let inserted = ReplenishmentItem.addIfAbsent(for: makeItem(name: "牛奶"), in: context)
        XCTAssertTrue(inserted, "a completed item should not block a fresh active one")
        XCTAssertEqual(try activeReplenishmentCount(context, name: "牛奶"), 1)
    }

    // MARK: - autoAddIfNeeded

    func testAutoAddIfNeededAddsWhenConsumedReachesThreshold() throws {
        let context = try makeContext()
        insertRecord(context, name: "酸奶", action: .consumed, daysAgo: 1)
        insertRecord(context, name: "酸奶", action: .consumed, daysAgo: 5)

        ReplenishmentItem.autoAddIfNeeded(for: makeItem(name: "酸奶"), in: context)
        XCTAssertEqual(try activeReplenishmentCount(context, name: "酸奶"), 1)
    }

    func testAutoAddIfNeededDoesNotAddBelowThreshold() throws {
        let context = try makeContext()
        insertRecord(context, name: "酸奶", action: .consumed, daysAgo: 1)

        ReplenishmentItem.autoAddIfNeeded(for: makeItem(name: "酸奶"), in: context)
        XCTAssertEqual(try activeReplenishmentCount(context, name: "酸奶"), 0)
    }

    func testAutoAddIfNeededIgnoresRecordsOlderThan30Days() throws {
        let context = try makeContext()
        insertRecord(context, name: "酸奶", action: .consumed, daysAgo: 40)
        insertRecord(context, name: "酸奶", action: .consumed, daysAgo: 45)

        ReplenishmentItem.autoAddIfNeeded(for: makeItem(name: "酸奶"), in: context)
        XCTAssertEqual(try activeReplenishmentCount(context, name: "酸奶"), 0)
    }

    func testAutoAddIfNeededIgnoresDiscardedRecords() throws {
        let context = try makeContext()
        insertRecord(context, name: "酸奶", action: .discarded, daysAgo: 1)
        insertRecord(context, name: "酸奶", action: .discarded, daysAgo: 2)

        ReplenishmentItem.autoAddIfNeeded(for: makeItem(name: "酸奶"), in: context)
        XCTAssertEqual(try activeReplenishmentCount(context, name: "酸奶"), 0)
    }

    func testAutoAddIfNeededIsScopedByName() throws {
        let context = try makeContext()
        insertRecord(context, name: "面包", action: .consumed, daysAgo: 1)
        insertRecord(context, name: "面包", action: .consumed, daysAgo: 2)

        // Records belong to 面包; querying for 酸奶 must not trigger an add.
        ReplenishmentItem.autoAddIfNeeded(for: makeItem(name: "酸奶"), in: context)
        XCTAssertEqual(try activeReplenishmentCount(context, name: "酸奶"), 0)
    }
}
