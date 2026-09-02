//
//  VerbatimTextField.swift
//  Palace
//
//  PP-5021: a text field that sends the characters the patron typed.
//

import SwiftUI
import UIKit

/// A `UITextField` wrapped so the characters typed are the characters sent.
///
/// **Why this exists.** iOS applies smart-punctuation substitution inside the
/// input system, before SwiftUI's binding is ever called. A patron typing a
/// title with a straight apostrophe gets `U+2019` substituted as they type, and
/// the search that reaches the server carries a character the catalogue record
/// does not have. Nothing indicates the text was changed on the way.
///
/// **Why it is UIKit.** SwiftUI exposes no modifier for `smartQuotesType` — only
/// `autocorrectionDisabled`, `disableAutocorrection` and
/// `textInputAutocapitalization`. Measured on iOS 26.1, `.autocorrectionDisabled()`
/// alone does **not** suppress the substitution: with it applied, the field still
/// held `U+2019` across two samples, read byte-exact through both the pasteboard
/// and the host accessibility channel. The traits are only reachable from UIKit.
///
/// **Why it is scoped rather than global.** `UITextField.appearance()` reaches
/// `smartQuotesType` in one line, but it applies to every text field in the app —
/// including the LCP passphrase field and the account forms. A DRM passphrase is
/// exactly the wrong place to discover a blast radius.
struct VerbatimTextField: UIViewRepresentable {
    let placeholder: String
    @Binding var text: String
    @Binding var isFocused: Bool
    var accessibilityIdentifier: String?
    var onSubmit: () -> Void = {}

    /// The input traits that make typing verbatim.
    ///
    /// Deliberately does **not** touch `autocapitalizationType`. Autocapitalisation
    /// also rewrites typed characters, so it arguably belongs here, but it is
    /// outside what PP-5021 claims and is flagged on the ticket rather than
    /// changed silently.
    static func applyVerbatimInputTraits(to field: UITextField) {
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.smartInsertDeleteType = .no
        field.autocorrectionType = .no
    }

    /// Pin the field to its own single-line height while still letting it span
    /// the width.
    ///
    /// A `UIViewRepresentable` is sized from the wrapped view's intrinsic content
    /// size and its hugging priorities. `UITextField` ships vertical hugging at
    /// `.defaultLow` (250) — "willing to stretch" — so in a `ZStack` that proposes
    /// the full available height the field ACCEPTED it: the search bar rendered
    /// roughly a quarter of the screen tall with the placeholder floating in the
    /// middle, and the caller's `.background(...)` + `.cornerRadius(10)` painted
    /// that whole expanded area. The previous SwiftUI `TextField` had an intrinsic
    /// single-line height and never showed this.
    ///
    /// Horizontal hugging stays `.defaultLow` deliberately: the field IS meant to
    /// fill the search bar's width. Only the vertical axis was wrong.
    ///
    /// Extracted as a static seam for the same reason as `applyVerbatimInputTraits`:
    /// `UIViewRepresentableContext` has no public initialiser, so `makeUIView`
    /// cannot be called from a test.
    static func applyFieldSizing(to field: UITextField) {
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentHuggingPriority(.defaultHigh, for: .vertical)
        field.setContentCompressionResistancePriority(.defaultHigh, for: .vertical)
    }

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        Self.applyVerbatimInputTraits(to: field)
        field.placeholder = placeholder
        field.accessibilityIdentifier = accessibilityIdentifier
        field.returnKeyType = .search
        field.delegate = context.coordinator
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        Self.applyFieldSizing(to: field)
        field.addTarget(
            context.coordinator,
            action: #selector(Coordinator.editingChanged(_:)),
            for: .editingChanged
        )
        return field
    }

    /// Sync the field's content to the current state.
    ///
    /// Extracted from `updateUIView` so it can be exercised directly:
    /// `UIViewRepresentableContext` has no public initialiser, so anything left
    /// inside `updateUIView` is unreachable from a unit test. Mechanical
    /// mutation found both guards below uncovered for exactly that reason.
    ///
    /// The guards matter: assigning unconditionally would reset the selection on
    /// every re-render, so the field would fight the caret while a patron types.
    static func syncFieldContent(_ field: UITextField, text: String, placeholder: String) {
        if field.text != text {
            field.text = text
        }
        if field.placeholder != placeholder {
            field.placeholder = placeholder
        }
    }

    func updateUIView(_ field: UITextField, context: Context) {
        Self.syncFieldContent(field, text: text, placeholder: placeholder)

        // Focus is bridged by hand. A UIViewRepresentable does not participate in
        // SwiftUI's `@FocusState`, so losing this bridge is how a wrapped field
        // silently stops responding to programmatic focus.
        if isFocused, !field.isFirstResponder {
            DispatchQueue.main.async { field.becomeFirstResponder() }
        } else if !isFocused, field.isFirstResponder {
            DispatchQueue.main.async { field.resignFirstResponder() }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        private let parent: VerbatimTextField

        init(_ parent: VerbatimTextField) {
            self.parent = parent
        }

        @objc func editingChanged(_ field: UITextField) {
            parent.text = field.text ?? ""
        }

        func textFieldDidBeginEditing(_ field: UITextField) {
            if !parent.isFocused { parent.isFocused = true }
        }

        func textFieldDidEndEditing(_ field: UITextField) {
            if parent.isFocused { parent.isFocused = false }
        }

        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            parent.onSubmit()
            return true
        }
    }
}
