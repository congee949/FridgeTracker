import XCTest

/// Page Object for the Add/Edit Food sheet (`AddFoodView`). Wraps element queries behind intent
/// methods so tests read as user actions and element changes only need updating here.
struct AddFoodScreen {
    let app: XCUIApplication

    var nameField: XCUIElement { app.textFields["addFood.nameField"] }
    var quantityField: XCUIElement { app.textFields["addFood.quantityField"] }
    var saveButton: XCUIElement { app.buttons["addFood.saveButton"] }
    var cancelButton: XCUIElement { app.buttons["addFood.cancelButton"] }
    var expiryStepper: XCUIElement { app.steppers["addFood.expiryStepper"] }

    func categoryButton(_ rawValue: String) -> XCUIElement { app.buttons["addFood.category.\(rawValue)"] }

    @discardableResult
    func waitUntilVisible(timeout: TimeInterval = 5) -> Bool {
        nameField.waitForExistence(timeout: timeout)
    }

    @discardableResult
    func enterName(_ text: String) -> Self {
        ensureFocused(nameField)
        nameField.typeText(text)
        return self
    }

    @discardableResult
    func selectCategory(_ rawValue: String) -> Self {
        let button = categoryButton(rawValue)
        if button.waitForExistence(timeout: 2) { button.tap() }
        return self
    }

    @discardableResult
    func enterQuantity(_ text: String) -> Self {
        ensureFocused(quantityField)
        quantityField.typeText(text)
        return self
    }

    /// Taps the stepper's increment button `times` times.
    @discardableResult
    func incrementExpiry(_ times: Int = 1) -> Self {
        scrollToHittable(expiryStepper)
        let increment = expiryStepper.buttons["Increment"].exists
            ? expiryStepper.buttons["Increment"]
            : expiryStepper.buttons.element(boundBy: 1)
        for _ in 0..<times { increment.tap() }
        return self
    }

    /// The "还有 N 天过期" / "保质期 N 天" text. SwiftUI folds the Stepper's label into the stepper's
    /// own accessibility label, so read it there (with fallbacks) rather than as a standalone text.
    var expiryDaysText: String {
        scrollToHittable(expiryStepper)
        let candidates = [expiryStepper.label, (expiryStepper.value as? String) ?? ""]
        if let withDays = candidates.first(where: { $0.contains("天") }) { return withDays }
        let staticText = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "天")).firstMatch
        return staticText.exists ? staticText.label : expiryStepper.label
    }

    func save() {
        saveButton.tap()
    }

    /// Scrolls the form until the target control is hittable, trying both directions (a control may be
    /// above or below the current scroll position).
    private func scrollToHittable(_ element: XCUIElement, maxSwipes: Int = 6) {
        // Don't guard on `.exists`: in a lazy Form an off-screen control isn't in the tree until
        // scrolled near, so we must swipe to reveal it. Try down (reveal below) then up (reveal above).
        var swipes = 0
        while !element.isHittable && swipes < maxSwipes { app.swipeUp(); swipes += 1 }
        swipes = 0
        while !element.isHittable && swipes < maxSwipes { app.swipeDown(); swipes += 1 }
    }

    /// Brings a field on-screen, taps it, and confirms the keyboard appeared (i.e. it has focus),
    /// retrying because a tap right after a scroll occasionally lands before focus attaches.
    private func ensureFocused(_ field: XCUIElement, retries: Int = 4) {
        for _ in 0..<retries {
            scrollToHittable(field)
            // A coordinate tap at the field's center is more reliable at acquiring focus than a
            // plain element tap, which sometimes only settles a scroll right after stepper use.
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            if app.keyboards.element.waitForExistence(timeout: 1.5) { return }
        }
    }
}
