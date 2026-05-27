//
//  PalacePDFViewTests.swift
//  PalaceTests
//
//  PP-4297: Pin the PDFView subclass that gates the system text-selection
//  edit menu (Copy, Cut, Paste, Look Up, Share, Select All, …) on a per-
//  instance `allowsCopy` flag. The PDF reader sets the flag from
//  `TPPBook.isDRMProtected` so DRM-protected titles never expose Copy on
//  long-press.
//

import XCTest
import PDFKit
@testable import Palace

final class PalacePDFViewTests: XCTestCase {

    private var pdfView: PalacePDFView!

    override func setUp() {
        super.setUp()
        pdfView = PalacePDFView()
    }

    override func tearDown() {
        pdfView = nil
        super.tearDown()
    }

    // MARK: - allowsCopy=true (non-DRM book)

    func testCanPerformCopy_whenAllowsCopyIsTrue_doesNotShortCircuit() {
        // With no selection PDFView's super returns true for `copy:`
        // (the menu can present a Copy item that's a no-op until the user
        // makes a selection). When allowsCopy=true the subclass MUST NOT
        // override that — otherwise non-DRM books would lose the Copy
        // menu they're supposed to keep.
        pdfView.allowsCopy = true
        XCTAssertTrue(pdfView.canPerformAction(#selector(UIResponderStandardEditActions.copy(_:)), withSender: nil),
                      "Non-DRM PDF must preserve PDFView's default Copy availability — subclass must not short-circuit when allowsCopy is true.")
    }

    // MARK: - allowsCopy=false (DRM book)

    func testCanPerformCopy_whenAllowsCopyIsFalse_returnsFalse() {
        pdfView.allowsCopy = false
        let allowed = pdfView.canPerformAction(#selector(UIResponderStandardEditActions.copy(_:)),
                                               withSender: nil)
        XCTAssertFalse(allowed,
                       "DRM-protected PDF must reject the Copy action on long-press.")
    }

    func testCanPerformCut_whenAllowsCopyIsFalse_returnsFalse() {
        pdfView.allowsCopy = false
        let allowed = pdfView.canPerformAction(#selector(UIResponderStandardEditActions.cut(_:)),
                                               withSender: nil)
        XCTAssertFalse(allowed,
                       "DRM-protected PDF must reject the Cut action on long-press.")
    }

    func testCanPerformPaste_whenAllowsCopyIsFalse_returnsFalse() {
        pdfView.allowsCopy = false
        let allowed = pdfView.canPerformAction(#selector(UIResponderStandardEditActions.paste(_:)),
                                               withSender: nil)
        XCTAssertFalse(allowed,
                       "DRM-protected PDF must reject the Paste action.")
    }

    func testCanPerformSelectAll_whenAllowsCopyIsFalse_returnsFalse() {
        pdfView.allowsCopy = false
        let allowed = pdfView.canPerformAction(#selector(UIResponderStandardEditActions.selectAll(_:)),
                                               withSender: nil)
        XCTAssertFalse(allowed,
                       "DRM-protected PDF must reject Select All on long-press.")
    }

    func testCanPerformShare_whenAllowsCopyIsFalse_returnsFalse() {
        pdfView.allowsCopy = false
        let allowed = pdfView.canPerformAction(Selector(("_share:")), withSender: nil)
        XCTAssertFalse(allowed,
                       "DRM-protected PDF must reject the system-private Share selector PDFView surfaces in its selection menu.")
    }

    func testCanPerformLookup_whenAllowsCopyIsFalse_returnsFalse() {
        pdfView.allowsCopy = false
        let allowed = pdfView.canPerformAction(Selector(("_lookup:")), withSender: nil)
        XCTAssertFalse(allowed,
                       "DRM-protected PDF must reject the system-private Look Up selector PDFView surfaces.")
    }

    func testCanPerformDefine_whenAllowsCopyIsFalse_returnsFalse() {
        pdfView.allowsCopy = false
        let allowed = pdfView.canPerformAction(Selector(("_define:")), withSender: nil)
        XCTAssertFalse(allowed,
                       "DRM-protected PDF must reject the system-private Define selector — without this, the iOS Define menu item bypasses suppression.")
    }

    func testCanPerformTranslate_whenAllowsCopyIsFalse_returnsFalse() {
        pdfView.allowsCopy = false
        let allowed = pdfView.canPerformAction(Selector(("_translate:")), withSender: nil)
        XCTAssertFalse(allowed,
                       "DRM-protected PDF must reject the system-private Translate selector — without this, the iOS Translate menu item bypasses suppression.")
    }

    // MARK: - Accessibility passthrough (AC #7)

    func testCanPerformAccessibilityAction_whenAllowsCopyIsFalse_defersToSuper() {
        // VoiceOver text-read-aloud relies on accessibility selectors
        // (`accessibilityActivate`, `_accessibility*`, etc.) — gating must
        // NOT trip on these or VoiceOver users lose the rotor read action
        // on DRM titles. We assert the subclass returns the same value as
        // an `allowsCopy=true` baseline for an accessibility selector.
        pdfView.allowsCopy = false
        let viaSubclass = pdfView.canPerformAction(#selector(NSObject.accessibilityActivate), withSender: nil)
        let baseline = PalacePDFView()
        baseline.allowsCopy = true
        let viaBaseline = baseline.canPerformAction(#selector(NSObject.accessibilityActivate), withSender: nil)
        XCTAssertEqual(viaSubclass, viaBaseline,
                       "Accessibility selectors must pass through unchanged regardless of allowsCopy — VoiceOver users on DRM titles need text read-aloud preserved.")
    }

    // MARK: - Non-editing selectors must not be affected

    func testCanPerformNonEditingAction_whenAllowsCopyIsFalse_defersToSuper() {
        // `printContent:` is a UIResponder selector PDFView neither
        // implements nor blocks. The gating must NOT trip on selectors
        // unrelated to text-edit operations — we only want to suppress
        // the long-press edit menu, not break unrelated responder traffic.
        pdfView.allowsCopy = false
        let viaSubclass = pdfView.canPerformAction(Selector(("printContent:")), withSender: nil)
        // Build a sibling unmodified instance to capture super's verdict.
        let baseline = PalacePDFView()
        baseline.allowsCopy = true
        let viaBaseline = baseline.canPerformAction(Selector(("printContent:")), withSender: nil)
        XCTAssertEqual(viaSubclass, viaBaseline,
                       "Non-editing selectors must pass through the gate unchanged regardless of allowsCopy.")
    }

    // MARK: - Default value

    func testAllowsCopy_defaultsToTrue() {
        XCTAssertTrue(PalacePDFView().allowsCopy,
                      "Default value preserves the existing non-DRM behavior — PalacePDFView must opt-in to suppression.")
    }
}
