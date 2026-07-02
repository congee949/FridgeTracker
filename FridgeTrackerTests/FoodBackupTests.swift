import XCTest
import SwiftData
@testable import FridgeTracker

/// Regression coverage for backup export/import (`FoodBackup.swift`).
///
/// Guards the high-severity bug where the document encoded dates as ISO-8601 but decoded with a
/// default `JSONDecoder()` that expects `Double`, so every exported file failed to re-import.
@MainActor
final class FoodBackupTests: XCTestCase {

    private let expiry = Date(timeIntervalSince1970: 1_750_000_000)
    private let created = Date(timeIntervalSince1970: 1_740_000_000)

    private func sampleBackup() -> FoodBackup {
        let item = FoodItem(
            name: "牛奶", category: .dairy, storageZone: .fridge, customIcon: "🥛",
            purchaseDate: nil, expiryDate: expiry, quantity: "2/6瓶", notes: "原味"
        )
        item.createdAt = created
        let record = FoodDispositionRecord(
            uuid: UUID(), foodName: "鸡蛋", category: .egg, storageZone: .fridge, customIcon: nil,
            quantity: nil, purchaseDate: nil, expiryDate: expiry, shelfLifeDaysEstimate: 10,
            action: .consumed, createdAt: created
        )
        let replenishment = ReplenishmentItem(
            uuid: UUID(), name: "面包", category: .baking, storageZone: .pantry, customIcon: nil,
            quantity: "1袋", notes: nil, defaultShelfLifeDays: 5, createdAt: created, completedAt: nil
        )
        return FoodBackup(
            version: 2,
            items: [FoodBackupItem(item)],
            dispositionRecords: [DispositionBackupItem(record)],
            replenishmentItems: [ReplenishmentBackupItem(replenishment)]
        )
    }

    // MARK: - Round trip (the bug guard)

    func testRoundTripPreservesDatesAndFields() throws {
        let data = try FoodBackupDocument.encode(sampleBackup())
        // Pre-fix this line threw DecodingError.typeMismatch on the first Date field.
        let decoded = try FoodBackupDocument.decode(from: data)

        let item = try XCTUnwrap(decoded.items.first)
        XCTAssertEqual(item.name, "牛奶")
        XCTAssertEqual(item.category, .dairy)
        XCTAssertEqual(item.storageZone, .fridge)
        XCTAssertEqual(item.quantity, "2/6瓶")
        XCTAssertEqual(item.expiryDate.timeIntervalSince1970, expiry.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(item.createdAt.timeIntervalSince1970, created.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(decoded.dispositionRecords?.count, 1)
        XCTAssertEqual(decoded.replenishmentItems?.count, 1)
        XCTAssertEqual(decoded.dispositionRecords?.first?.action, .consumed)
    }

    func testEncoderWritesISO8601DateStrings() throws {
        let data = try FoodBackupDocument.encode(sampleBackup())
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        // ISO-8601 dates render as "…T…Z" strings, never bare numeric seconds.
        XCTAssertTrue(json.contains("T") && json.contains("Z"), "dates should serialize as ISO-8601 strings")
    }

    // MARK: - Backwards compatibility / mapping

    func testV1BackupDecodesAndRecomputesShelfLife() throws {
        // v1: no version / uuid / originalShelfLifeDays. createdAt -> expiry spans 30 days.
        let json = """
        {"items":[{"name":"酸奶","category":"乳制品","storageZone":"冷藏",\
        "expiryDate":"2025-01-31T12:00:00Z","createdAt":"2025-01-01T12:00:00Z"}]}
        """
        let decoded = try FoodBackupDocument.decode(from: Data(json.utf8))
        let backupItem = try XCTUnwrap(decoded.items.first)
        XCTAssertNil(decoded.version)
        XCTAssertNil(backupItem.uuid)
        XCTAssertNil(backupItem.originalShelfLifeDays)

        // The `foodItem` getter recomputes originalShelfLifeDays from the real createdAt->expiry span.
        let model = backupItem.foodItem
        let shelfLife = try XCTUnwrap(model.originalShelfLifeDays)
        XCTAssertTrue((29...31).contains(shelfLife), "expected ~30 days, got \(shelfLife)")
    }

    func testDecodesChineseEnumRawValues() throws {
        let json = """
        {"version":2,"items":[{"name":"牛肉","category":"肉类","storageZone":"冷冻",\
        "expiryDate":"2025-06-01T12:00:00Z","createdAt":"2025-05-01T12:00:00Z"}]}
        """
        let decoded = try FoodBackupDocument.decode(from: Data(json.utf8))
        let item = try XCTUnwrap(decoded.items.first)
        XCTAssertEqual(item.category, .meat)       // 肉类
        XCTAssertEqual(item.storageZone, .freezer) // 冷冻
    }
}
