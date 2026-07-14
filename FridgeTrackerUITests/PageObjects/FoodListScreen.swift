import XCTest

/// Page Object for the food list tab (`FoodListView`).
@MainActor
struct FoodListScreen {
    let app: XCUIApplication

    var addButton: XCUIElement { app.buttons["foodList.addButton"] }
    var searchField: XCUIElement { app.textFields["foodList.searchField"] }
    var consumeAction: XCUIElement { app.buttons["foodRow.consumeAction"] }
    var discardAction: XCUIElement { app.buttons["foodRow.discardAction"] }

    func row(_ name: String) -> XCUIElement { app.buttons["foodRow.\(name)"] }

    @discardableResult
    func openAddSheet() -> AddFoodScreen {
        addButton.tap()
        return AddFoodScreen(app: app)
    }

    func hasRow(_ name: String, timeout: TimeInterval = 5) -> Bool {
        row(name).waitForExistence(timeout: timeout)
    }

    /// Waits for a row to disappear (e.g. after a single-unit consume/discard).
    func waitForRowToDisappear(_ name: String, timeout: TimeInterval = 5) -> Bool {
        let gone = NSPredicate(format: "exists == false")
        return expectationCheck(gone, for: row(name), timeout: timeout)
    }

    @discardableResult
    func swipeAndConsume(_ name: String) -> Self {
        row(name).swipeLeft()
        XCTAssertTrue(consumeAction.waitForExistence(timeout: 3), "consume action not revealed for \(name)")
        consumeAction.tap()
        return self
    }

    @discardableResult
    func swipeAndDiscard(_ name: String) -> Self {
        row(name).swipeLeft()
        XCTAssertTrue(discardAction.waitForExistence(timeout: 3), "discard action not revealed for \(name)")
        discardAction.tap()
        return self
    }

    // MARK: - Helpers

    private func expectationCheck(_ predicate: NSPredicate, for element: XCUIElement, timeout: TimeInterval) -> Bool {
        let exp = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [exp], timeout: timeout) == .completed
    }
}
