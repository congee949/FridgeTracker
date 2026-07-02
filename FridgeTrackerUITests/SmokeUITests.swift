import XCTest

/// Validates the UI-testing target + isolated launch: the app reaches the foreground and the food
/// list's add button is present (so the rest of the Page Objects have a starting point).
final class SmokeUITests: FridgeUITestCase {
    @MainActor
    func testAppLaunchesToFoodList() {
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(FoodListScreen(app: app).addButton.waitForExistence(timeout: 5))
    }
}
