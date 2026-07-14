import XCTest
// Xcode 26 runs App Intents metadata extraction for UI-test bundles. Declaring the framework
// dependency prevents its spurious "No AppIntents.framework dependency found" build warning.
import AppIntents

/// Base class for UI tests: launches the app with `-uitesting`, which makes it use a clean,
/// isolated in-memory SwiftData store (see `FridgeTrackerApp.makeModelContainer`). Each test method
/// gets a fresh launch, so tests never see each other's data or touch the real on-disk store.
@MainActor
class FridgeUITestCase: XCTestCase {
    var app: XCUIApplication!

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uitesting"]
        app.launch()
    }

    override func tearDown() async throws {
        app = nil
        try await super.tearDown()
    }
}
