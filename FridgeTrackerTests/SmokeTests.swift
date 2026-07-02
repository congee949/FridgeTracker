import XCTest
import SwiftData
@testable import FridgeTracker

/// Pipeline sanity check: `@testable import` reaches app symbols and the in-memory SwiftData
/// fixture builds, inserts, and fetches. The substantive coverage lives in the per-unit test files.
final class SmokeTests: XCTestCase {
    func testFoodQuantityParsesSimpleCount() throws {
        let quantity = try XCTUnwrap(FoodQuantity.parse("3个"))
        XCTAssertEqual(quantity.current, 3)
        XCTAssertEqual(quantity.total, 3)
        XCTAssertEqual(quantity.unit, "个")
    }

    @MainActor
    func testInMemoryContainerInsertsAndFetches() throws {
        let context = try TestModelContainer.makeContext()
        context.insert(FoodItem(name: "牛奶", category: .dairy, storageZone: .fridge, expiryDate: .now))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FoodItem>()), 1)
    }
}
