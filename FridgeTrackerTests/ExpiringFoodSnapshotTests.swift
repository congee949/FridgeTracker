import XCTest
import SwiftUI
@testable import FridgeTracker

/// Regression baseline for the pure helpers and the `ExpiringFoodSnapshot` value type in
/// `FridgeTracker/Utilities/ExpiringFoodSnapshot.swift`.
///
/// No SwiftData / `@Model` types are involved, so this case needs neither `TestModelContainer`
/// nor `@MainActor`. Expected strings, colors, and thresholds are taken verbatim from the source.
final class ExpiringFoodSnapshotTests: XCTestCase {

    // MARK: - expiryStatusText(daysUntilExpiry:)

    func testExpiryStatusTextNegativeReportsExpiredWithAbsoluteDays() {
        // days < 0 -> "已过期 \(-days) 天"
        XCTAssertEqual(expiryStatusText(daysUntilExpiry: -1), "已过期 1 天")
        XCTAssertEqual(expiryStatusText(daysUntilExpiry: -5), "已过期 5 天")
    }

    func testExpiryStatusTextZeroReportsToday() {
        // days == 0 -> "今天过期"
        XCTAssertEqual(expiryStatusText(daysUntilExpiry: 0), "今天过期")
    }

    func testExpiryStatusTextPositiveReportsDaysRemaining() {
        // days > 0 -> "\(days) 天后过期"
        XCTAssertEqual(expiryStatusText(daysUntilExpiry: 1), "1 天后过期")
        XCTAssertEqual(expiryStatusText(daysUntilExpiry: 3), "3 天后过期")
        XCTAssertEqual(expiryStatusText(daysUntilExpiry: 30), "30 天后过期")
    }

    // MARK: - expiryStatusColor(daysUntilExpiry:)

    func testExpiryStatusColorNegativeIsRed() {
        // days < 0 -> .red
        XCTAssertEqual(expiryStatusColor(daysUntilExpiry: -1), Color.red)
        XCTAssertEqual(expiryStatusColor(daysUntilExpiry: -10), Color.red)
    }

    func testExpiryStatusColorWithinSoonThresholdIsOrange() {
        // 0 <= days <= 3 -> .orange  (zero is orange, not red)
        XCTAssertEqual(expiryStatusColor(daysUntilExpiry: 0), Color.orange)
        XCTAssertEqual(expiryStatusColor(daysUntilExpiry: 1), Color.orange)
        XCTAssertEqual(expiryStatusColor(daysUntilExpiry: 3), Color.orange)
    }

    func testExpiryStatusColorBeyondThresholdIsGreen() {
        // days > 3 -> .green  (4 is the first green day)
        XCTAssertEqual(expiryStatusColor(daysUntilExpiry: 4), Color.green)
        XCTAssertEqual(expiryStatusColor(daysUntilExpiry: 100), Color.green)
    }

    // MARK: - Codable round-trip via JSONEncoder/JSONDecoder.expiringFoods

    func testCodableRoundTripPreservesAllFields() throws {
        let original = ExpiringFoodSnapshot(
            id: UUID(),
            name: "牛奶",
            category: "乳制品",
            categoryIcon: "🥛",
            displayIcon: "🥛",
            storageZone: "冷藏",
            storageIcon: "❄️",
            // .iso8601 strategy has whole-second resolution, so use a sub-second-free date.
            expiryDate: Date(timeIntervalSince1970: 1_700_000_000),
            daysUntilExpiry: 2
        )

        let data = try JSONEncoder.expiringFoods.encode(original)
        let decoded = try JSONDecoder.expiringFoods.decode(ExpiringFoodSnapshot.self, from: data)

        // Hashable/Equatable round-trip equality (covers every stored property).
        XCTAssertEqual(decoded, original)

        // Spot-check fields explicitly to localize any future regression.
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.name, "牛奶")
        XCTAssertEqual(decoded.category, "乳制品")
        XCTAssertEqual(decoded.categoryIcon, "🥛")
        XCTAssertEqual(decoded.displayIcon, "🥛")
        XCTAssertEqual(decoded.storageZone, "冷藏")
        XCTAssertEqual(decoded.storageIcon, "❄️")
        XCTAssertEqual(decoded.expiryDate, original.expiryDate)
        XCTAssertEqual(decoded.daysUntilExpiry, 2)
    }

    func testEncoderUsesISO8601DateStrategy() throws {
        // The stored `expiryDate` must serialize as an ISO-8601 string (the contract both
        // encoder and decoder rely on). Confirm the encoded payload contains an ISO-8601 form.
        let snapshot = ExpiringFoodSnapshot(
            id: UUID(),
            name: "鸡蛋",
            category: "蛋类",
            categoryIcon: "🥚",
            displayIcon: "🥚",
            storageZone: "冷藏",
            storageIcon: "❄️",
            expiryDate: Date(timeIntervalSince1970: 1_700_000_000),
            daysUntilExpiry: 0
        )

        let data = try JSONEncoder.expiringFoods.encode(snapshot)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        // ISO8601DateFormatter renders 1_700_000_000 as "2023-11-14T22:13:20Z".
        XCTAssertTrue(json.contains("2023-11-14T22:13:20Z"),
                      "expiryDate should be encoded as an ISO-8601 string, got: \(json)")
    }

    // MARK: - currentDaysUntilExpiry (clock-relative)

    func testCurrentDaysUntilExpiryForFutureDateMatchesCalendarDayDiff() throws {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let future = try XCTUnwrap(calendar.date(byAdding: .day, value: 5, to: today))

        let snapshot = makeSnapshot(expiryDate: future, daysUntilExpiry: 999)

        // Computed live from the clock; the stale stored `daysUntilExpiry` (999) is ignored.
        XCTAssertEqual(snapshot.currentDaysUntilExpiry, 5)
    }

    func testCurrentDaysUntilExpiryForTodayIsZero() throws {
        let snapshot = makeSnapshot(expiryDate: Date(), daysUntilExpiry: 42)
        XCTAssertEqual(snapshot.currentDaysUntilExpiry, 0)
    }

    func testCurrentDaysUntilExpiryForPastDateIsNegative() throws {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let past = try XCTUnwrap(calendar.date(byAdding: .day, value: -3, to: today))

        let snapshot = makeSnapshot(expiryDate: past, daysUntilExpiry: 0)
        XCTAssertEqual(snapshot.currentDaysUntilExpiry, -3)
    }

    // MARK: - expiryText (derived from currentDaysUntilExpiry)

    func testExpiryTextUsesLiveDayCountForFutureDate() throws {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let future = try XCTUnwrap(calendar.date(byAdding: .day, value: 2, to: today))

        let snapshot = makeSnapshot(expiryDate: future, daysUntilExpiry: 999)
        XCTAssertEqual(snapshot.expiryText, "2 天后过期")
    }

    func testExpiryTextForTodayIsToday() throws {
        let snapshot = makeSnapshot(expiryDate: Date(), daysUntilExpiry: 999)
        XCTAssertEqual(snapshot.expiryText, "今天过期")
    }

    func testExpiryTextForPastDateReportsExpired() throws {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let past = try XCTUnwrap(calendar.date(byAdding: .day, value: -2, to: today))

        let snapshot = makeSnapshot(expiryDate: past, daysUntilExpiry: 999)
        XCTAssertEqual(snapshot.expiryText, "已过期 2 天")
    }

    // MARK: - Helpers

    private func makeSnapshot(expiryDate: Date, daysUntilExpiry: Int) -> ExpiringFoodSnapshot {
        ExpiringFoodSnapshot(
            id: UUID(),
            name: "测试",
            category: "其他",
            categoryIcon: "📦",
            displayIcon: "📦",
            storageZone: "冷藏",
            storageIcon: "❄️",
            expiryDate: expiryDate,
            daysUntilExpiry: daysUntilExpiry
        )
    }
}