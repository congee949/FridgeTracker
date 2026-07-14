import XCTest
import SwiftData
@testable import FridgeTracker

/// Regression baseline for the expiry / shelf-life computed properties on `FoodItem`.
///
/// These pin the *current* behavior of `daysUntilExpiry`, `isExpired`, `isExpiringSoon`,
/// `shelfLifeDaysEstimate`, and `refreshOriginalShelfLife`. All dates are built relative to
/// `Calendar.current` / `Date()` to match the implementations, which floor every endpoint to
/// `startOfDay`, making day-count math deterministic regardless of the wall-clock time of day.
@MainActor
final class FoodItemExpiryTests: XCTestCase {

    private let calendar = Calendar.current

    /// Start of *today*, the anchor both `daysUntilExpiry` and `refreshOriginalShelfLife` use.
    private var todayStart: Date {
        calendar.startOfDay(for: Date())
    }

    /// `startOfDay(today) + days` (days may be negative for past dates).
    private func date(daysFromTodayStart days: Int) -> Date {
        calendar.date(byAdding: .day, value: days, to: todayStart)!
    }

    /// Build a `FoodItem` whose expiry is `expiryOffset` days from the start of today.
    /// `purchaseDate` is left nil unless supplied.
    private func makeItem(expiryOffset: Int, purchaseDate: Date? = nil) -> FoodItem {
        FoodItem(
            name: "测试",
            category: .other,
            storageZone: .fridge,
            purchaseDate: purchaseDate,
            expiryDate: date(daysFromTodayStart: expiryOffset)
        )
    }

    // MARK: - daysUntilExpiry

    func testDaysUntilExpiryFutureReturnsOffset() {
        let item = makeItem(expiryOffset: 5)
        XCTAssertEqual(item.daysUntilExpiry, 5)
    }

    func testDaysUntilExpiryTodayIsZero() {
        let item = makeItem(expiryOffset: 0)
        XCTAssertEqual(item.daysUntilExpiry, 0)
    }

    func testDaysUntilExpiryPastIsNegative() {
        let item = makeItem(expiryOffset: -3)
        XCTAssertEqual(item.daysUntilExpiry, -3)
    }

    // MARK: - isExpired (daysUntilExpiry < 0)

    func testIsExpiredFalseWhenExpiringToday() {
        // 0 is not < 0, so an item expiring today is NOT yet expired.
        let item = makeItem(expiryOffset: 0)
        XCTAssertFalse(item.isExpired)
    }

    func testIsExpiredFalseInFuture() {
        let item = makeItem(expiryOffset: 1)
        XCTAssertFalse(item.isExpired)
    }

    func testIsExpiredTrueInPast() {
        let item = makeItem(expiryOffset: -1)
        XCTAssertTrue(item.isExpired)
    }

    // MARK: - isExpiringSoon ((0...3).contains(daysUntilExpiry))

    func testIsExpiringSoonTrueAtLowerBoundZero() {
        let item = makeItem(expiryOffset: 0)
        XCTAssertTrue(item.isExpiringSoon)
    }

    func testIsExpiringSoonTrueInsideWindow() {
        let item = makeItem(expiryOffset: 2)
        XCTAssertTrue(item.isExpiringSoon)
    }

    func testIsExpiringSoonTrueAtUpperBoundThree() {
        let item = makeItem(expiryOffset: 3)
        XCTAssertTrue(item.isExpiringSoon)
    }

    func testIsExpiringSoonFalseJustAboveWindow() {
        let item = makeItem(expiryOffset: 4)
        XCTAssertFalse(item.isExpiringSoon)
    }

    func testIsExpiringSoonFalseWhenAlreadyExpired() {
        // -1 is below the 0...3 range, so an expired item is not "expiring soon".
        let item = makeItem(expiryOffset: -1)
        XCTAssertFalse(item.isExpiringSoon)
    }

    // MARK: - shelfLifeDaysEstimate

    func testShelfLifeEstimateUsesPurchaseDateWhenPresent() {
        // purchaseDate branch: startOfDay(purchaseDate) -> startOfDay(expiryDate), max(_, 1).
        // purchase 4 days ago, expiry 6 days out => 10-day span.
        let item = makeItem(expiryOffset: 6, purchaseDate: date(daysFromTodayStart: -4))
        XCTAssertEqual(item.shelfLifeDaysEstimate, 10)
    }

    func testShelfLifeEstimatePurchaseDateFlooredToOne() {
        // purchaseDate == expiryDate (same day) => raw span 0, clamped to max(0, 1) == 1.
        let sameDay = date(daysFromTodayStart: 2)
        let item = FoodItem(
            name: "测试",
            category: .other,
            storageZone: .fridge,
            purchaseDate: sameDay,
            expiryDate: sameDay
        )
        XCTAssertEqual(item.shelfLifeDaysEstimate, 1)
    }

    func testShelfLifeEstimateUsesStoredOriginalWhenNoPurchaseDate() throws {
        // No purchaseDate => second branch returns max(originalShelfLifeDays, 1).
        // init() populates originalShelfLifeDays from createdAt->expiry; overwrite it with a
        // sentinel that differs from the date math to prove the STORED field is read back.
        let item = makeItem(expiryOffset: 6)
        item.originalShelfLifeDays = 999
        XCTAssertEqual(item.shelfLifeDaysEstimate, 999)
    }

    func testShelfLifeEstimateStoredOriginalFlooredToOne() {
        // Stored value below 1 is clamped: max(0, 1) == 1.
        let item = makeItem(expiryOffset: 6)
        item.originalShelfLifeDays = 0
        XCTAssertEqual(item.shelfLifeDaysEstimate, 1)
    }

    func testShelfLifeEstimateCapsUntrustedStoredOriginalAtDomainMaximum() {
        let item = makeItem(expiryOffset: 6)
        item.originalShelfLifeDays = .max

        XCTAssertEqual(item.shelfLifeDaysEstimate, FoodShelfLifeConstraints.maximumDays)
    }

    func testShelfLifeEstimateFallbackToDaysUntilExpiry() {
        // Fallback (third) branch requires purchaseDate == nil AND originalShelfLifeDays == nil.
        // Since init() always sets originalShelfLifeDays when purchaseDate is nil, we must null it
        // out manually to exercise the fallback: returns max(daysUntilExpiry, 1).
        let item = makeItem(expiryOffset: 6)
        item.originalShelfLifeDays = nil
        XCTAssertEqual(item.shelfLifeDaysEstimate, 6)
    }

    func testShelfLifeEstimateFallbackFlooredToOneWhenExpired() {
        // Fallback with a past expiry: daysUntilExpiry is negative, clamped to max(_, 1) == 1.
        let item = makeItem(expiryOffset: -5)
        item.originalShelfLifeDays = nil
        XCTAssertEqual(item.shelfLifeDaysEstimate, 1)
    }

    // MARK: - refreshOriginalShelfLife

    func testRefreshComputesOriginalFromCreatedAtWhenNoPurchaseDate() throws {
        // createdAt is set to Date() inside init; refresh measures
        // startOfDay(createdAt) -> startOfDay(expiryDate). createdAt is "today", expiry +7 => 7.
        let item = makeItem(expiryOffset: 7)
        // init() already calls refreshOriginalShelfLife(); call again to assert idempotent result.
        item.refreshOriginalShelfLife()
        XCTAssertEqual(try XCTUnwrap(item.originalShelfLifeDays), 7)
    }

    func testRefreshFloorsOriginalToOneWhenExpiryNotAfterCreation() throws {
        // Expiry today (same day as createdAt) => raw span 0, clamped to max(0, 1) == 1.
        let item = makeItem(expiryOffset: 0)
        item.refreshOriginalShelfLife()
        XCTAssertEqual(try XCTUnwrap(item.originalShelfLifeDays), 1)
    }

    func testRefreshCapsFarFutureExpirySoGeneratedBackupsRemainValid() throws {
        let item = makeItem(expiryOffset: FoodShelfLifeConstraints.maximumDays + 1)

        XCTAssertEqual(
            try XCTUnwrap(item.originalShelfLifeDays),
            FoodShelfLifeConstraints.maximumDays
        )
    }

    func testRefreshClearsOriginalWhenPurchaseDatePresent() {
        // With a purchaseDate, refresh sets originalShelfLifeDays back to nil
        // (the estimate is then computed live from purchaseDate instead of a stored snapshot).
        let item = makeItem(expiryOffset: 7, purchaseDate: date(daysFromTodayStart: -2))
        // Seed a non-nil value first to prove refresh actively clears it.
        item.originalShelfLifeDays = 42
        item.refreshOriginalShelfLife()
        XCTAssertNil(item.originalShelfLifeDays)
    }

    func testInitSetsOriginalShelfLifeWhenNoPurchaseDate() throws {
        // Guards the init -> refreshOriginalShelfLife wiring for the no-purchaseDate path.
        let item = makeItem(expiryOffset: 4)
        XCTAssertEqual(try XCTUnwrap(item.originalShelfLifeDays), 4)
    }

    func testInitLeavesOriginalNilWhenPurchaseDatePresent() {
        // init -> refreshOriginalShelfLife clears the field whenever a purchaseDate is supplied.
        let item = makeItem(expiryOffset: 4, purchaseDate: date(daysFromTodayStart: -1))
        XCTAssertNil(item.originalShelfLifeDays)
    }

    func testTimezoneOnlyCivilDateUpdatePreservesDayAndOriginalShelfLife() throws {
        let utcPlus14 = try XCTUnwrap(TimeZone(secondsFromGMT: 14 * 3_600))
        let utcMinus11 = try XCTUnwrap(TimeZone(secondsFromGMT: -11 * 3_600))
        let expiryDay = try XCTUnwrap(LocalDate(year: 2026, month: 8, day: 10))
        let originalInstant = try XCTUnwrap(expiryDay.date(in: utcPlus14))
        let editingInstant = try XCTUnwrap(expiryDay.date(in: utcMinus11))
        let item = FoodItem(
            name: "跨时区坚果",
            category: .nut,
            storageZone: .pantry,
            expiryDate: originalInstant
        )
        item.expiryDayKey = expiryDay.iso8601DateString
        item.originalShelfLifeDays = 30

        item.updateCivilDates(purchaseDate: nil, expiryDate: editingInstant, timeZone: utcMinus11)

        XCTAssertEqual(item.expiryDayKey, "2026-08-10")
        XCTAssertEqual(item.originalShelfLifeDays, 30)
    }

    func testExplicitExpiryCivilDayChangeAdjustsStoredShelfLifeByDayDelta() throws {
        let timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 8 * 3_600))
        let oldDay = try XCTUnwrap(LocalDate(year: 2026, month: 8, day: 10))
        let newDay = try XCTUnwrap(LocalDate(year: 2026, month: 8, day: 12))
        let item = FoodItem(
            name: "核桃",
            category: .nut,
            storageZone: .pantry,
            expiryDate: try XCTUnwrap(oldDay.date(in: timeZone))
        )
        item.expiryDayKey = oldDay.iso8601DateString
        item.originalShelfLifeDays = 30

        item.updateCivilDates(
            purchaseDate: nil,
            expiryDate: try XCTUnwrap(newDay.date(in: timeZone)),
            timeZone: timeZone
        )

        XCTAssertEqual(item.expiryDayKey, "2026-08-12")
        XCTAssertEqual(item.originalShelfLifeDays, 32)
    }

    func testCivilDateAdjustmentCannotOverflowOrEscapeShelfLifeDomain() throws {
        let timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let oldDay = try XCTUnwrap(LocalDate(year: 2026, month: 1, day: 1))
        let newDay = try XCTUnwrap(LocalDate(year: 2036, month: 1, day: 2))
        let item = FoodItem(
            name: "长期储存",
            category: .other,
            storageZone: .freezer,
            expiryDate: try XCTUnwrap(oldDay.date(in: timeZone))
        )
        item.expiryDayKey = oldDay.iso8601DateString
        item.originalShelfLifeDays = .max

        item.updateCivilDates(
            purchaseDate: nil,
            expiryDate: try XCTUnwrap(newDay.date(in: timeZone)),
            timeZone: timeZone
        )

        XCTAssertEqual(item.originalShelfLifeDays, FoodShelfLifeConstraints.maximumDays)
    }
}
