import SwiftUI
import UIKit

/// A single-line text field that keeps UIKit's marked-text lifecycle visible to SwiftUI.
///
/// SwiftUI's `TextField` binding can lag behind what a Chinese IME is visibly composing.  In
/// particular, a toolbar button driven only by the committed binding may remain disabled while the
/// user can already see a candidate in the field.  This wrapper publishes visible/non-empty state
/// during composition, but only publishes `text` after the IME commits its marked text.
struct IMEAwareTextField: UIViewRepresentable {
    @Binding var text: String
    @Binding var hasVisibleNonWhitespaceText: Bool
    @Binding var isComposing: Bool

    let placeholder: String
    let accessibilityIdentifier: String
    let controller: IMETextFieldController
    var onCommittedTextChange: (String) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UITextField {
        let textField = UITextField(frame: .zero)
        textField.placeholder = placeholder
        textField.font = .preferredFont(forTextStyle: .body)
        textField.adjustsFontForContentSizeCategory = true
        textField.clearButtonMode = .whileEditing
        textField.returnKeyType = .done
        textField.accessibilityIdentifier = accessibilityIdentifier
        textField.accessibilityLabel = placeholder
        textField.delegate = context.coordinator
        textField.addTarget(
            context.coordinator,
            action: #selector(Coordinator.editingChanged(_:)),
            for: .editingChanged
        )
        controller.attach(textField, coordinator: context.coordinator)
        return textField
    }

    func updateUIView(_ textField: UITextField, context: Context) {
        context.coordinator.update(parent: self)
        controller.attach(textField, coordinator: context.coordinator)

        // Never replace the backing UIKit text while an IME owns a marked range.  Doing so cancels
        // or corrupts the candidate session (the root cause of several SwiftUI + Pinyin glitches).
        guard textField.markedTextRange == nil else { return }
        if textField.text != text {
            textField.text = text
        }
    }

    @MainActor
    final class Coordinator: NSObject, UITextFieldDelegate {
        private var parent: IMEAwareTextField

        init(parent: IMEAwareTextField) {
            self.parent = parent
        }

        func update(parent: IMEAwareTextField) {
            self.parent = parent
        }

        @objc func editingChanged(_ textField: UITextField) {
            synchronize(from: textField)
        }

        func synchronize(from textField: UITextField) {
            synchronize(
                visibleText: textField.text ?? "",
                isComposing: textField.markedTextRange != nil
            )
        }

        /// Kept separate from UIKit lookup so the marked/committed contract has deterministic tests.
        func synchronize(visibleText: String, isComposing: Bool) {
            let hasVisibleText = !visibleText
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty

            if parent.hasVisibleNonWhitespaceText != hasVisibleText {
                parent.hasVisibleNonWhitespaceText = hasVisibleText
            }
            if parent.isComposing != isComposing {
                parent.isComposing = isComposing
            }

            // Marked text is provisional.  Publishing it into SwiftUI would feed the intermediate
            // Pinyin back through updateUIView and can make the IME lose its selected candidate.
            guard !isComposing else { return }
            guard parent.text != visibleText else { return }

            parent.text = visibleText
            parent.onCommittedTextChange(visibleText)
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            textField.unmarkText()
            synchronize(from: textField)
            textField.resignFirstResponder()
            return true
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            synchronize(from: textField)
            // Some third-party keyboards finalize their candidate as focus leaves. Re-read on the
            // next run-loop turn; the equality guard keeps normal keyboards from double-publishing.
            DispatchQueue.main.async { [weak self, weak textField] in
                guard let self, let textField else { return }
                self.synchronize(from: textField)
            }
        }
    }
}

/// Imperative bridge for the two operations that cannot be expressed safely by a SwiftUI binding
/// while an IME owns marked text: committing before Save, and replacing text from a template/OCR.
@MainActor
final class IMETextFieldController: ObservableObject {
    private weak var textField: UITextField?
    private weak var coordinator: IMEAwareTextField.Coordinator?

    func attach(
        _ textField: UITextField,
        coordinator: IMEAwareTextField.Coordinator
    ) {
        self.textField = textField
        self.coordinator = coordinator
    }

    func commitAndResign(
        fallbackText: String,
        completion: @escaping (String) -> Void
    ) {
        guard let textField else {
            DispatchQueue.main.async {
                completion(fallbackText)
            }
            return
        }

        textField.unmarkText()
        coordinator?.synchronize(from: textField)
        textField.resignFirstResponder()
        let committedFallback = textField.text ?? fallbackText

        // Resigning can itself make a keyboard finalize text.  Read on the next main-loop turn so
        // validation and persistence always see the final committed value.
        DispatchQueue.main.async { [weak self, weak textField] in
            guard let textField else {
                completion(committedFallback)
                return
            }
            self?.coordinator?.synchronize(from: textField)
            completion(textField.text ?? fallbackText)
        }
    }

    /// An explicit template/OCR choice wins over an in-progress composition without allowing an
    /// older marked candidate to overwrite that choice later.
    func replaceText(with newText: String) {
        guard let textField else { return }
        textField.unmarkText()
        textField.text = newText
        coordinator?.synchronize(from: textField)
    }

    func focus() {
        DispatchQueue.main.async { [weak textField] in
            textField?.becomeFirstResponder()
        }
    }
}
