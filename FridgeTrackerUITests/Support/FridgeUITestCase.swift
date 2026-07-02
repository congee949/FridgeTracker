import XCTest

/// Base class for UI tests: launches the app with `-uitesting`, which makes it use a clean,
/// isolated in-memory SwiftData store (see `FridgeTrackerApp.makeModelContainer`). Each test method
/// gets a fresh launch, so tests never see each other's data or touch the real on-disk store.
class FridgeUITestCase: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uitesting"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
        try super.tearDownWithError()
    }
}
