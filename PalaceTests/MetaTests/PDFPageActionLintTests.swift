//
//  PDFPageActionLintTests.swift
//  PalaceTests
//
//  PP-3838 — the guard the original fix did not have.
//

import XCTest

/// PP-3838 shipped two things: an on-screen Previous/Next toolbar, and named
/// custom actions on the PDF document view so a Full Keyboard Access user can
/// page from the Tab-Z menu without hunting for the toolbar. Whether
/// VoiceOver's rotor also surfaces them is unverified: they sit on a
/// `UIViewRepresentable` container, UIKit reads custom actions from the focused
/// element rather than walking ancestors, and the sibling reader's equivalent
/// was refuted by a device recording (PP-4527). Only a device can settle it. `PDFAccessibilityToolbarTests`
/// covers the first and never mentions the second, so when the custom actions
/// were dropped from `TPPPDFView` the suite stayed green and the regression
/// shipped from 3.0.0 onward. It was found by reading history.
///
/// A behaviour that exists only as a view modifier cannot be reached by an
/// ordinary unit test — there is no instance to invoke and no return value to
/// assert — so the thing that regressed was also the thing nothing could pin.
/// This lint reads the production source instead.
///
/// It matches each action together with the body it runs, because the defect
/// this shape invites is not a missing action but a swapped edge: two adjacent
/// four-line modifiers differing in one word each. Asserting that both names
/// appear, and counting the handler calls, leaves `previousPage` wired to
/// `.bottom` entirely green — a Previous action that advances the page, which
/// no sighted reviewer would see.
@MainActor
final class PDFPageActionLintTests: XCTestCase {

    /// `Palace/` resolved relative to this file, so the lint works in any
    /// checkout — no env vars, no CI-specific paths.
    private static let palaceSourceRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MetaTests/
            .deletingLastPathComponent()   // PalaceTests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Palace")
    }()

    private static let pdfViewPath = palaceSourceRoot
        .appendingPathComponent("PDF/Views/TPPPDFView.swift")

    /// `named:` through the closure body, so the action and the edge it scrolls
    /// are one match. `[^}]*?` keeps the match inside the closure.
    private static func actionBoundTo(_ stringsKey: String, edge: String) -> NSRegularExpression {
        try! NSRegularExpression(
            pattern: #"accessibilityAction\(named: Text\(Strings\.Generic\."# + stringsKey
                + #"\)\)\s*\{[^}]*?handleAccessibilityScroll\(\."# + edge + #"\)"#,
            options: [.dotMatchesLineSeparators]
        )
    }

    private func pdfViewSource() throws -> String {
        let path = Self.pdfViewPath
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path),
                      "TPPPDFView.swift moved; re-point this lint rather than deleting it — \(path.path)")
        return try String(contentsOf: path, encoding: .utf8)
    }

    private func matchCount(_ regex: NSRegularExpression, in source: String) -> Int {
        regex.numberOfMatches(in: source, range: NSRange(source.startIndex..., in: source))
    }

    // MARK: - The regression, and the slip it invites

    /// Next must exist AND advance. Either half missing is the defect.
    func testNextPageAction_existsAndAdvancesThePage() throws {
        let source = try pdfViewSource()
        XCTAssertEqual(
            matchCount(Self.actionBoundTo("nextPage", edge: "bottom"), in: source), 1,
            "TPPPDFView must declare exactly one Next-page custom action whose body calls handleAccessibilityScroll(.bottom). "
            + "Missing it costs Full Keyboard Access page navigation (PP-3838); wiring it to .top makes Next go backwards."
        )
    }

    /// Previous must exist AND go back. This is the assertion a name-only lint
    /// cannot make, and the one that catches the copy-paste slip.
    func testPreviousPageAction_existsAndGoesBackAPage() throws {
        let source = try pdfViewSource()
        XCTAssertEqual(
            matchCount(Self.actionBoundTo("previousPage", edge: "top"), in: source), 1,
            "TPPPDFView must declare exactly one Previous-page custom action whose body calls handleAccessibilityScroll(.top). "
            + "Wiring it to .bottom ships a Previous action that advances the page — green under any name-only check."
        )
    }

    /// Both actions must delegate. `handleAccessibilityScroll` already clamps at
    /// the document boundaries and posts the page-scrolled announcement, so a
    /// body that computes its own page would let the named actions and the scroll
    /// action disagree about the last page.
    func testBothActions_delegateRatherThanComputeTheirOwnPage() throws {
        let source = try pdfViewSource()
        let anyAction = try NSRegularExpression(
            pattern: #"accessibilityAction\(named: Text\(Strings\.Generic\.(next|previous)Page\)\)"#
        )
        let delegating = matchCount(Self.actionBoundTo("nextPage", edge: "bottom"), in: source)
            + matchCount(Self.actionBoundTo("previousPage", edge: "top"), in: source)
        XCTAssertEqual(
            matchCount(anyAction, in: source), delegating,
            "Every page custom action must delegate to handleAccessibilityScroll with the matching edge; "
            + "an action whose body does something else is not covered by any test, because the handler is the only implementation."
        )
    }

    /// Guards the lint itself: a renamed file or a vanished anchor would make
    /// every assertion above vacuous rather than failing honestly.
    func testLintReadsTheIntendedFile() throws {
        let source = try pdfViewSource()
        XCTAssertTrue(source.contains("struct TPPPDFView"),
                      "This lint is reading a file that is not TPPPDFView")
        XCTAssertTrue(source.contains("accessibilityScrollAction"),
                      "The accessibilityScrollAction anchor is gone; the page actions' placement and this lint both need revisiting")
    }

    // Not covered here: `handleAccessibilityScroll`'s own behaviour — the
    // boundary clamps and the `.pageScrolled` post. It is `private` with no
    // seam, so no test drives it, and this commit made it the single
    // implementation behind three entry points rather than one. Extracting a
    // pure page-advance function would let a real unit test pin the clamp;
    // that is a production change beyond restoring the lost actions.
}
