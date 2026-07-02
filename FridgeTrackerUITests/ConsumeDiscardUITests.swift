import XCTest

/// E2E coverage of the consume / discard flow — the app's most central action, and the one whose
/// decrement-vs-remove decision drives history + auto-replenish.
@MainActor
final class ConsumeDiscardUITests: FridgeUITestCase {

    private func addItem(_ name: String, category: String, quantity: String? = nil) {
        let list = FoodListScreen(app: app)
        let add = list.openAddSheet()
        XCTAssertTrue(add.waitUntilVisible(), "add sheet did not appear for \(name)")
        add.enterName(name).selectCategory(category)
        if let quantity { add.enterQuantity(quantity) }
        add.save()
        XCTAssertTrue(list.hasRow(name), "\(name) should be in the list after adding")
    }

    func testConsumingMultiUnitItemDecrementsAndKeepsRow() {
        addItem("苹果", category: "水果", quantity: "3个")

        let list = FoodListScreen(app: app)
        list.swipeAndConsume("苹果")

        // 3个 -> 2个: the item is decremented, not removed.
        XCTAssertTrue(list.hasRow("苹果"), "a multi-unit item should remain after one consume")
    }

    func testConsumingUntrackedItemRemovesIt() {
        addItem("西瓜", category: "水果") // no quantity -> consume removes it

        let list = FoodListScreen(app: app)
        list.swipeAndConsume("西瓜")

        XCTAssertTrue(list.waitForRowToDisappear("西瓜"), "an untracked item should be removed on consume")
    }

    func testDiscardingItemRemovesIt() {
        addItem("酸奶", category: "乳制品")

        let list = FoodListScreen(app: app)
        list.swipeAndDiscard("酸奶")

        XCTAssertTrue(list.waitForRowToDisappear("酸奶"), "discarded item should be removed from the list")
    }
}
