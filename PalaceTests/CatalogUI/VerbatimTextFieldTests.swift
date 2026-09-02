//
//  VerbatimTextFieldTests.swift
//  PalaceTests
//
//  PP-5021.
//

import XCTest
import SwiftUI
import UIKit
@testable import Palace

/// These tests pin the *configuration* the measurement showed is necessary.
///
/// They deliberately do NOT claim to prove the patron-visible outcome. Smart-quote
/// substitution happens inside the iOS input system, before any binding is called,
/// so no unit test can exercise it — a test that assigns `"Alice's"` to the binding
/// passes identically with the fix present or absent, and is vacuous by
/// construction. The outcome is verified on a simulator by typing through the
/// keyboard and reading the field byte-exact; see the intent file.
@MainActor
final class VerbatimTextFieldTests: XCTestCase {

    // `UIViewRepresentableContext` has no public initialiser, so the traits are
    // asserted through the seam that applies them. `makeUIView` calls this exact
    // method, so a regression in either place fails here.
    func testMakeUIView_disablesEverySubstitutingInputTrait() {
        let field = UITextField()
        VerbatimTextField.applyVerbatimInputTraits(to: field)

        XCTAssertEqual(field.smartQuotesType, .no,
                       "smart quotes substitute ' -> U+2019 in the input system; this is the trait PP-5021 exists to disable")
        XCTAssertEqual(field.smartDashesType, .no,
                       "smart dashes rewrite -- into an en/em dash, the same class of silent rewrite")
        XCTAssertEqual(field.smartInsertDeleteType, .no,
                       "smart insert/delete adjusts surrounding whitespace on paste")
        XCTAssertEqual(field.autocorrectionType, .no,
                       "autocorrection can rewrite an author's name before the search is sent")
    }

    // The field must keep its own single-line height. A UIViewRepresentable is
    // sized from the wrapped view's intrinsic size and its hugging priorities;
    // UITextField ships vertical hugging at .defaultLow (250), i.e. "willing to
    // stretch". In a ZStack that proposes the full available height the field
    // accepted it and rendered ~a quarter of the screen tall, with the
    // background and cornerRadius painting the whole expanded area.
    // Horizontal hugging must STAY low — the field is meant to fill the width.
    func testMakeUIView_pinsFieldToItsIntrinsicHeightButStillFillsWidth() {
        let field = UITextField()
        VerbatimTextField.applyFieldSizing(to: field)

        XCTAssertEqual(field.contentHuggingPriority(for: .vertical), .defaultHigh,
                       "vertical hugging must resist stretching or the search field grows to fill its container")
        XCTAssertEqual(field.contentHuggingPriority(for: .horizontal), .defaultLow,
                       "horizontal hugging must stay low so the field still spans the search bar's width")
    }

    func testApplyVerbatimInputTraits_doesNotChangeAutocapitalisation() {
        let field = UITextField()
        let before = field.autocapitalizationType

        VerbatimTextField.applyVerbatimInputTraits(to: field)

        XCTAssertEqual(field.autocapitalizationType, before,
                       "autocapitalisation also rewrites typed characters, but it is outside what PP-5021 claims — it is flagged on the ticket, not changed silently here")
    }

    func testCoordinator_editingChanged_writesTheTypedTextBackToTheBinding() {
        var stored = ""
        let binding = Binding<String>(get: { stored }, set: { stored = $0 })
        let sut = VerbatimTextField(
            placeholder: "Search Catalog",
            text: binding,
            isFocused: .constant(false)
        )
        let coordinator = sut.makeCoordinator()

        let field = UITextField()
        // A curly apostrophe here is the real-world case: whatever the input
        // system produced must reach the binding unaltered by us.
        field.text = "Alice\u{2019}s"
        coordinator.editingChanged(field)

        XCTAssertEqual(stored, "Alice\u{2019}s",
                       "the coordinator must pass the field's text through verbatim; this layer must not normalise")
        XCTAssertEqual(stored.unicodeScalars.map { $0.value }.filter { $0 == 0x2019 }.count, 1,
                       "the character must survive as U+2019 rather than being folded to U+0027 by our own code")
    }

    func testCoordinator_beginAndEndEditing_driveTheFocusBindingBothWays() {
        var focused = false
        let binding = Binding<Bool>(get: { focused }, set: { focused = $0 })
        let sut = VerbatimTextField(
            placeholder: "Search Catalog",
            text: .constant(""),
            isFocused: binding
        )
        let coordinator = sut.makeCoordinator()
        let field = UITextField()

        coordinator.textFieldDidBeginEditing(field)
        XCTAssertTrue(focused, "a wrapped field must report gaining focus; SwiftUI's @FocusState cannot see a UIViewRepresentable on its own")

        coordinator.textFieldDidEndEditing(field)
        XCTAssertFalse(focused, "and must report losing it, or the caller's focus state stays stuck true after the keyboard dismisses")
    }

    func testCoordinator_shouldReturn_invokesSubmit() {
        var submitted = false
        let sut = VerbatimTextField(
            placeholder: "Search Catalog",
            text: .constant(""),
            isFocused: .constant(false),
            onSubmit: { submitted = true }
        )
        let coordinator = sut.makeCoordinator()

        let shouldReturn = coordinator.textFieldShouldReturn(UITextField())

        XCTAssertTrue(submitted, "the search key must still submit; this is the submitLabel(.search) affordance the SwiftUI field provided for free")
        XCTAssertTrue(shouldReturn,
                      "must return true so UIKit still processes the Return key. Discarding this value is how mechanical mutation found `return true -> return false` surviving: the side effect fired, so the test passed, while the Search key stopped behaving")
    }

    // MARK: - Content sync
    //
    // These two exist because mechanical mutation reported `!=` -> `==` on both
    // guards as UNCOVERED — they lived inside `updateUIView`, which needs a
    // `UIViewRepresentableContext` that has no public initialiser. Testing them
    // required a seam, not a cleverer assertion.

    func testSyncFieldContent_writesTextWhenItDiffers() {
        let field = UITextField()
        field.text = "old"

        VerbatimTextField.syncFieldContent(field, text: "Alice's", placeholder: "Search Catalog")

        XCTAssertEqual(field.text, "Alice's",
                       "a changed query must reach the field; inverting this guard leaves the previous text on screen")
    }

    func testSyncFieldContent_writesPlaceholderWhenItDiffers() {
        let field = UITextField()
        field.placeholder = "old"

        VerbatimTextField.syncFieldContent(field, text: "", placeholder: "Search Catalog")

        XCTAssertEqual(field.placeholder, "Search Catalog",
                       "inverting this guard leaves a stale placeholder")
    }

    func testSyncFieldContent_leavesAnAlreadyCorrectFieldAlone() {
        let field = UITextField()
        field.text = "Alice's"
        field.placeholder = "Search Catalog"
        field.selectedTextRange = field.textRange(from: field.beginningOfDocument,
                                                  to: field.beginningOfDocument)
        let selectionBefore = field.selectedTextRange

        VerbatimTextField.syncFieldContent(field, text: "Alice's", placeholder: "Search Catalog")

        XCTAssertEqual(field.text, "Alice's")
        XCTAssertEqual(field.selectedTextRange, selectionBefore,
                       "re-assigning identical text resets the caret; that is what the guard prevents, and why it is a guard rather than a plain assignment")
    }
}
