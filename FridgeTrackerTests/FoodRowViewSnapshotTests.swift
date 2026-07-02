import XCTest
import SwiftUI
import SnapshotTesting
@testable import FridgeTracker

/// Visual regression for the food row across its three expiry states. Reference images are recorded
/// on first run under `__Snapshots__/` and committed; later runs compare against them.
///
/// References are device/OS specific — regenerate with `isRecording = true` (or delete the snapshot
/// folder) when intentionally changing the row's look. Generated on iPhone 17, iOS 26.
@MainActor
final class FoodRowViewSnapshotTests: XCTestCase {

    private func host(_ item: FoodItem) -> UIViewController {
        let row = FoodRowView(item: item)
            .frame(width: 380)
            .padding()
            .background(Color(.systemBackground))
        let controller = UIHostingController(rootView: row)
        controller.overrideUserInterfaceStyle = .light
        return controller
    }

    private func item(name: String, daysToExpiry: Int, quantity: String? = "1瓶") -> FoodItem {
        let expiry = Calendar.current.date(byAdding: .day, value: daysToExpiry, to: Date()) ?? Date()
        return FoodItem(name: name, category: .dairy, storageZone: .fridge, expiryDate: expiry, quantity: quantity)
    }

    private let imageSize = CGSize(width: 380, height: 88)

    func testFreshItemRow() {
        assertSnapshot(
            of: host(item(name: "牛奶", daysToExpiry: 10)),
            as: .image(precision: 0.95, perceptualPrecision: 0.95, size: imageSize),
            named: "fresh"
        )
    }

    func testExpiringSoonItemRow() {
        assertSnapshot(
            of: host(item(name: "酸奶", daysToExpiry: 2)),
            as: .image(precision: 0.95, perceptualPrecision: 0.95, size: imageSize),
            named: "soon"
        )
    }

    func testExpiredItemRow() {
        assertSnapshot(
            of: host(item(name: "鸡蛋", daysToExpiry: -1)),
            as: .image(precision: 0.95, perceptualPrecision: 0.95, size: imageSize),
            named: "expired"
        )
    }
}
