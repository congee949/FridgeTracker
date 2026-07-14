import XCTest
import SwiftData
@testable import FridgeTracker

/// Regression baseline for `FoodListViewModel.filteredItems(_:)`.
///
/// `filteredItems` is a pure transform, but its inputs are `@Model` `FoodItem` instances, so the
/// suite builds them through the in-memory container helper and runs on the main actor.
///
/// Behavior pinned here (read from `FoodListViewModel.swift`):
/// - search: empty `searchText` returns all; otherwise `name.localizedCaseInsensitiveContains`.
/// - category: `nil` returns all; otherwise keeps `category == selected`.
/// - sort: `.expiryDate` ascending by `expiryDate`; `.createdDate` descending by `createdAt`;
///   `.name` ascending via `localizedCompare`.
///
/// Note: `FoodItem.init` always stamps `createdAt = Date()`, so `.createdDate` ordering is exercised
/// by mutating the `var createdAt` after construction (init takes no `createdAt` argument).
@MainActor
final class FoodListViewModelTests: XCTestCase {

    private var context: ModelContext!

    override func setUp() async throws {
        try await super.setUp()
        context = try TestModelContainer.makeContext()
    }

    override func tearDown() async throws {
        context = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    /// Builds a `FoodItem` with explicit createdAt/expiry so ordering is deterministic.
    /// `createdAt` is assigned after init because `FoodItem.init` hard-codes it to `Date()`.
    private func makeItem(
        name: String,
        category: FoodCategory = .other,
        expiryOffsetDays: Int,
        createdOffsetSeconds: TimeInterval
    ) -> FoodItem {
        let now = Date()
        let expiry = Calendar.current.date(byAdding: .day, value: expiryOffsetDays, to: now) ?? now
        let item = FoodItem(
            name: name,
            category: category,
            storageZone: .fridge,
            expiryDate: expiry
        )
        item.createdAt = now.addingTimeInterval(createdOffsetSeconds)
        context.insert(item)
        return item
    }

    private func names(_ items: [FoodItem]) -> [String] {
        items.map(\.name)
    }

    // MARK: - Search filter

    func testEmptySearchReturnsAllItems() throws {
        let sut = FoodListViewModel()
        sut.sortOption = .name

        let items = [
            makeItem(name: "牛奶", expiryOffsetDays: 1, createdOffsetSeconds: 0),
            makeItem(name: "Apple", expiryOffsetDays: 2, createdOffsetSeconds: 1),
            makeItem(name: "鸡蛋", expiryOffsetDays: 3, createdOffsetSeconds: 2),
        ]

        let result = sut.filteredItems(items)

        XCTAssertEqual(result.count, items.count)
        XCTAssertEqual(Set(names(result)), Set(["牛奶", "Apple", "鸡蛋"]))
    }

    func testSearchIsCaseInsensitiveSubstringMatch() throws {
        let sut = FoodListViewModel()
        // Pin sort so membership assertions don't depend on input order.
        sut.sortOption = .name
        sut.searchText = "app"

        let items = [
            makeItem(name: "Apple", expiryOffsetDays: 1, createdOffsetSeconds: 0),
            makeItem(name: "Pineapple", expiryOffsetDays: 2, createdOffsetSeconds: 1),
            makeItem(name: "Banana", expiryOffsetDays: 3, createdOffsetSeconds: 2),
        ]

        let result = sut.filteredItems(items)

        // "app" matches "Apple" (case-insensitive) and the "apple" inside "Pineapple"; not "Banana".
        XCTAssertEqual(Set(names(result)), Set(["Apple", "Pineapple"]))
    }

    func testSearchMatchesChineseSubstring() throws {
        let sut = FoodListViewModel()
        sut.searchText = "奶"

        let items = [
            makeItem(name: "牛奶", expiryOffsetDays: 1, createdOffsetSeconds: 0),
            makeItem(name: "酸奶", expiryOffsetDays: 2, createdOffsetSeconds: 1),
            makeItem(name: "鸡蛋", expiryOffsetDays: 3, createdOffsetSeconds: 2),
        ]

        let result = sut.filteredItems(items)

        XCTAssertEqual(Set(names(result)), Set(["牛奶", "酸奶"]))
    }

    func testSearchWithNoMatchReturnsEmpty() throws {
        let sut = FoodListViewModel()
        sut.searchText = "zzz"

        let items = [
            makeItem(name: "牛奶", expiryOffsetDays: 1, createdOffsetSeconds: 0),
            makeItem(name: "鸡蛋", expiryOffsetDays: 2, createdOffsetSeconds: 1),
        ]

        XCTAssertTrue(sut.filteredItems(items).isEmpty)
    }

    // MARK: - Category filter

    func testNilCategoryReturnsAllItems() throws {
        let sut = FoodListViewModel()
        sut.sortOption = .name
        XCTAssertNil(sut.selectedCategory)

        let items = [
            makeItem(name: "牛奶", category: .dairy, expiryOffsetDays: 1, createdOffsetSeconds: 0),
            makeItem(name: "苹果", category: .fruit, expiryOffsetDays: 2, createdOffsetSeconds: 1),
            makeItem(name: "牛肉", category: .meat, expiryOffsetDays: 3, createdOffsetSeconds: 2),
        ]

        XCTAssertEqual(sut.filteredItems(items).count, items.count)
    }

    func testSpecificCategoryFiltersToThatCategory() throws {
        let sut = FoodListViewModel()
        sut.sortOption = .name
        sut.selectedCategory = .fruit

        let items = [
            makeItem(name: "苹果", category: .fruit, expiryOffsetDays: 1, createdOffsetSeconds: 0),
            makeItem(name: "香蕉", category: .fruit, expiryOffsetDays: 2, createdOffsetSeconds: 1),
            makeItem(name: "牛奶", category: .dairy, expiryOffsetDays: 3, createdOffsetSeconds: 2),
            makeItem(name: "牛肉", category: .meat, expiryOffsetDays: 4, createdOffsetSeconds: 3),
        ]

        let result = sut.filteredItems(items)

        XCTAssertEqual(Set(names(result)), Set(["苹果", "香蕉"]))
        XCTAssertTrue(result.allSatisfy { $0.category == .fruit })
    }

    func testSearchAndCategoryCombineAsConjunction() throws {
        let sut = FoodListViewModel()
        sut.selectedCategory = .fruit
        sut.searchText = "果"

        let items = [
            makeItem(name: "苹果", category: .fruit, expiryOffsetDays: 1, createdOffsetSeconds: 0),
            makeItem(name: "香蕉", category: .fruit, expiryOffsetDays: 2, createdOffsetSeconds: 1),  // fruit, no "果"
            makeItem(name: "芒果干", category: .snack, expiryOffsetDays: 3, createdOffsetSeconds: 2), // "果" but snack
        ]

        let result = sut.filteredItems(items)

        // Only the item that is BOTH fruit AND name-contains "果" survives.
        XCTAssertEqual(names(result), ["苹果"])
    }

    // MARK: - Sort: expiry date (ascending)

    func testSortByExpiryDateAscending() throws {
        let sut = FoodListViewModel()
        sut.sortOption = .expiryDate

        // Insert out of order; createdAt order is the inverse to ensure expiry (not createdAt) drives it.
        let items = [
            makeItem(name: "中", expiryOffsetDays: 5, createdOffsetSeconds: 0),
            makeItem(name: "晚", expiryOffsetDays: 10, createdOffsetSeconds: 1),
            makeItem(name: "早", expiryOffsetDays: 1, createdOffsetSeconds: 2),
        ]

        let result = sut.filteredItems(items)

        XCTAssertEqual(names(result), ["早", "中", "晚"])
    }

    func testExpirySortUsesAuthoritativeCivilDayInsteadOfLegacyInstant() {
        let sut = FoodListViewModel()
        sut.sortOption = .expiryDate

        let civilEarlier = makeItem(name: "民用日期早", expiryOffsetDays: 10, createdOffsetSeconds: 0)
        civilEarlier.expiryDayKey = "2026-01-01"
        let civilLater = makeItem(name: "民用日期晚", expiryOffsetDays: -10, createdOffsetSeconds: 1)
        civilLater.expiryDayKey = "2026-01-02"

        XCTAssertGreaterThan(civilEarlier.expiryDate, civilLater.expiryDate, "legacy instants intentionally disagree")
        XCTAssertEqual(names(sut.filteredItems([civilLater, civilEarlier])), ["民用日期早", "民用日期晚"])
    }

    // MARK: - Sort: created date (descending)

    func testSortByCreatedDateDescending() throws {
        let sut = FoodListViewModel()
        sut.sortOption = .createdDate

        // expiry order is intentionally not aligned with createdAt order.
        let items = [
            makeItem(name: "旧", expiryOffsetDays: 1, createdOffsetSeconds: 0),
            makeItem(name: "新", expiryOffsetDays: 2, createdOffsetSeconds: 100),
            makeItem(name: "中", expiryOffsetDays: 3, createdOffsetSeconds: 50),
        ]

        let result = sut.filteredItems(items)

        // Newest createdAt first.
        XCTAssertEqual(names(result), ["新", "中", "旧"])
    }

    // MARK: - Sort: name (localizedCompare ascending)

    func testSortByNameAscending() throws {
        let sut = FoodListViewModel()
        sut.sortOption = .name

        let items = [
            makeItem(name: "Cherry", expiryOffsetDays: 3, createdOffsetSeconds: 0),
            makeItem(name: "apple", expiryOffsetDays: 2, createdOffsetSeconds: 1),
            makeItem(name: "Banana", expiryOffsetDays: 1, createdOffsetSeconds: 2),
        ]

        let result = sut.filteredItems(items)

        // localizedCompare is case-insensitive-ish & locale-aware: apple < Banana < Cherry.
        XCTAssertEqual(names(result), ["apple", "Banana", "Cherry"])
    }

    // MARK: - Empty input

    func testEmptyInputReturnsEmpty() throws {
        let sut = FoodListViewModel()
        XCTAssertTrue(sut.filteredItems([]).isEmpty)
    }
}
