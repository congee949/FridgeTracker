import SwiftUI
import UIKit
import XCTest
@testable import FridgeTracker

@MainActor
final class IMEAwareTextFieldTests: XCTestCase {
    private final class StateBox {
        var text = ""
        var hasVisibleText = false
        var isComposing = false
        var committedChanges: [String] = []
    }

    private func makeSubject(
        box: StateBox
    ) -> (IMEAwareTextField, IMEAwareTextField.Coordinator, IMETextFieldController) {
        let controller = IMETextFieldController()
        let subject = IMEAwareTextField(
            text: Binding(get: { box.text }, set: { box.text = $0 }),
            hasVisibleNonWhitespaceText: Binding(
                get: { box.hasVisibleText },
                set: { box.hasVisibleText = $0 }
            ),
            isComposing: Binding(
                get: { box.isComposing },
                set: { box.isComposing = $0 }
            ),
            placeholder: "食材名称",
            accessibilityIdentifier: "test.name",
            controller: controller,
            onCommittedTextChange: { box.committedChanges.append($0) }
        )
        return (subject, subject.makeCoordinator(), controller)
    }

    func testMarkedPinyinEnablesSaveStateWithoutPublishingCommittedName() {
        let box = StateBox()
        let (_, coordinator, _) = makeSubject(box: box)

        coordinator.synchronize(visibleText: "niunai", isComposing: true)

        XCTAssertTrue(box.hasVisibleText)
        XCTAssertTrue(box.isComposing)
        XCTAssertEqual(box.text, "")
        XCTAssertEqual(box.committedChanges, [])
    }

    func testConfirmingChineseCandidatePublishesExactlyOnce() {
        let box = StateBox()
        let (_, coordinator, _) = makeSubject(box: box)

        coordinator.synchronize(visibleText: "niunai", isComposing: true)
        coordinator.synchronize(visibleText: "牛奶", isComposing: false)
        coordinator.synchronize(visibleText: "牛奶", isComposing: false)

        XCTAssertTrue(box.hasVisibleText)
        XCTAssertFalse(box.isComposing)
        XCTAssertEqual(box.text, "牛奶")
        XCTAssertEqual(box.committedChanges, ["牛奶"])
    }

    func testWhitespaceMarkedTextDoesNotEnableSave() {
        let box = StateBox()
        let (_, coordinator, _) = makeSubject(box: box)

        coordinator.synchronize(visibleText: " \n ", isComposing: true)

        XCTAssertFalse(box.hasVisibleText)
        XCTAssertTrue(box.isComposing)
        XCTAssertEqual(box.text, "")
    }

    func testExternalReplacementWinsOverProvisionalComposition() {
        let box = StateBox()
        let (_, coordinator, controller) = makeSubject(box: box)
        let textField = UITextField()
        controller.attach(textField, coordinator: coordinator)

        coordinator.synchronize(visibleText: "jianguo", isComposing: true)
        controller.replaceText(with: "坚果")

        XCTAssertEqual(textField.text, "坚果")
        XCTAssertEqual(box.text, "坚果")
        XCTAssertFalse(box.isComposing)
        XCTAssertEqual(box.committedChanges, ["坚果"])
    }

    func testSaveControllerReturnsFinalTextOnNextMainLoopTurn() {
        let box = StateBox()
        let (_, coordinator, controller) = makeSubject(box: box)
        let textField = UITextField()
        textField.text = "牛奶"
        controller.attach(textField, coordinator: coordinator)
        coordinator.synchronize(visibleText: "niunai", isComposing: true)

        let completion = expectation(description: "commit completion")
        controller.commitAndResign(fallbackText: "") { finalText in
            XCTAssertEqual(finalText, "牛奶")
            XCTAssertEqual(box.text, "牛奶")
            XCTAssertFalse(box.isComposing)
            completion.fulfill()
        }

        wait(for: [completion], timeout: 1)
    }

    func testSaveControllerCommitsActualUIKitMarkedCandidate() throws {
        let box = StateBox()
        let (subject, coordinator, controller) = makeSubject(box: box)
        let host = UIHostingController(rootView: subject)
        let windowScene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let window = UIWindow(windowScene: windowScene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 100)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.loadViewIfNeeded()
        host.view.frame = window.bounds
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        let textField = try XCTUnwrap(findTextField(in: host.view))

        textField.setMarkedText("牛奶", selectedRange: NSRange(location: 2, length: 0))
        XCTAssertNotNil(textField.markedTextRange)
        textField.sendActions(for: .editingChanged)
        XCTAssertTrue(box.hasVisibleText)
        XCTAssertTrue(box.isComposing)
        XCTAssertEqual(box.text, "")

        let completion = expectation(description: "marked candidate committed")
        controller.attach(textField, coordinator: coordinator)
        controller.commitAndResign(fallbackText: "") { finalText in
            XCTAssertEqual(finalText, "牛奶")
            XCTAssertEqual(box.text, "牛奶")
            XCTAssertFalse(box.isComposing)
            completion.fulfill()
        }

        wait(for: [completion], timeout: 1)
        window.isHidden = true
        window.rootViewController = nil
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        _ = host // Keep the representable and its UIKit field alive through completion.
    }

    private func findTextField(in view: UIView) -> UITextField? {
        if let textField = view as? UITextField { return textField }
        for subview in view.subviews {
            if let textField = findTextField(in: subview) { return textField }
        }
        return nil
    }
}
