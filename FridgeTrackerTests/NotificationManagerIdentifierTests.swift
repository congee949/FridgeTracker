import XCTest
@testable import FridgeTracker

/// Regression baseline for `NotificationManager`'s pure static identifier helpers.
///
/// Pins today's behavior of `advanceIdentifier(for:)`, `expiryIdentifier(for:)`, and
/// `isFoodReminderIdentifier(_:)`. `advance`/`expiry` take a `FoodItem` (a `@Model`), so the
/// class runs on the main actor and builds items via the in-memory `TestModelContainer` fixture.
/// Scheduling (`scheduleNotification`/`rescheduleAll`) is intentionally out of scope: it touches
/// `UNUserNotificationCenter` and `UserDefaults`.
@MainActor
final class NotificationManagerIdentifierTests: XCTestCase {

    /// A persisted `FoodItem` with an auto-generated UUID, used to exercise the item-based helpers.
    private func makeItem() throws -> FoodItem {
        let context = try TestModelContainer.makeContext()
        let item = FoodItem(name: "牛奶", category: .dairy, storageZone: .fridge, expiryDate: .now)
        context.insert(item)
        return item
    }

    // MARK: - advanceIdentifier / expiryIdentifier suffix format

    func testAdvanceIdentifierIsUUIDPlusAdvanceSuffix() throws {
        let item = try makeItem()
        XCTAssertEqual(
            NotificationManager.advanceIdentifier(for: item),
            item.uuid.uuidString + ".advance"
        )
    }

    func testExpiryIdentifierIsUUIDPlusExpirySuffix() throws {
        let item = try makeItem()
        XCTAssertEqual(
            NotificationManager.expiryIdentifier(for: item),
            item.uuid.uuidString + ".expiry"
        )
    }

    func testAdvanceAndExpiryShareUUIDPrefixDifferOnlyBySuffix() throws {
        let item = try makeItem()
        let advance = NotificationManager.advanceIdentifier(for: item)
        let expiry = NotificationManager.expiryIdentifier(for: item)

        XCTAssertTrue(advance.hasPrefix(item.uuid.uuidString))
        XCTAssertTrue(expiry.hasPrefix(item.uuid.uuidString))
        XCTAssertTrue(advance.hasSuffix(".advance"))
        XCTAssertTrue(expiry.hasSuffix(".expiry"))
        XCTAssertNotEqual(advance, expiry)
    }

    func testDistinctItemsProduceDistinctIdentifiers() throws {
        let first = try makeItem()
        let second = try makeItem()
        // Auto-generated UUIDs differ, so identifiers must differ too.
        XCTAssertNotEqual(first.uuid, second.uuid)
        XCTAssertNotEqual(
            NotificationManager.advanceIdentifier(for: first),
            NotificationManager.advanceIdentifier(for: second)
        )
        XCTAssertNotEqual(
            NotificationManager.expiryIdentifier(for: first),
            NotificationManager.expiryIdentifier(for: second)
        )
    }

    // MARK: - isFoodReminderIdentifier: true cases

    func testIsFoodReminderIdentifierTrueForBareUUID() {
        let uuid = UUID().uuidString
        XCTAssertTrue(NotificationManager.isFoodReminderIdentifier(uuid))
    }

    func testIsFoodReminderIdentifierTrueForAdvanceSuffix() {
        let uuid = UUID().uuidString
        XCTAssertTrue(NotificationManager.isFoodReminderIdentifier(uuid + ".advance"))
    }

    func testIsFoodReminderIdentifierTrueForExpirySuffix() {
        let uuid = UUID().uuidString
        XCTAssertTrue(NotificationManager.isFoodReminderIdentifier(uuid + ".expiry"))
    }

    func testIsFoodReminderIdentifierTrueForFixedKnownUUIDString() {
        // A concrete, valid UUID string verifies the parse path without RNG.
        let uuid = "12345678-1234-1234-1234-123456789012"
        XCTAssertTrue(NotificationManager.isFoodReminderIdentifier(uuid))
        XCTAssertTrue(NotificationManager.isFoodReminderIdentifier(uuid + ".advance"))
        XCTAssertTrue(NotificationManager.isFoodReminderIdentifier(uuid + ".expiry"))
    }

    func testIsFoodReminderIdentifierTrueForHelperOutput() throws {
        // Round-trip: identifiers the helpers actually emit must be recognized as ours.
        let item = try makeItem()
        XCTAssertTrue(
            NotificationManager.isFoodReminderIdentifier(NotificationManager.advanceIdentifier(for: item))
        )
        XCTAssertTrue(
            NotificationManager.isFoodReminderIdentifier(NotificationManager.expiryIdentifier(for: item))
        )
        // The legacy bare-uuid form (cleaned up by cancelNotification) is still recognized.
        XCTAssertTrue(NotificationManager.isFoodReminderIdentifier(item.uuid.uuidString))
    }

    // MARK: - isFoodReminderIdentifier: false cases

    func testIsFoodReminderIdentifierFalseForNonUUIDPrefixWithSuffix() {
        XCTAssertFalse(NotificationManager.isFoodReminderIdentifier("notauuid.advance"))
        XCTAssertFalse(NotificationManager.isFoodReminderIdentifier("notauuid.expiry"))
    }

    func testIsFoodReminderIdentifierFalseForArbitraryStrings() {
        XCTAssertFalse(NotificationManager.isFoodReminderIdentifier("hello"))
        XCTAssertFalse(NotificationManager.isFoodReminderIdentifier("foo.bar"))
        XCTAssertFalse(NotificationManager.isFoodReminderIdentifier(""))
    }

    func testIsFoodReminderIdentifierFalseWhenUUIDIsNotTheFirstSegment() {
        // The prefix before the first "." must itself be a UUID; a trailing UUID does not count.
        let uuid = UUID().uuidString
        XCTAssertFalse(NotificationManager.isFoodReminderIdentifier("prefix." + uuid))
    }
}
