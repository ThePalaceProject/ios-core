//
//  BookListViewAccessibilityTests.swift
//  PalaceTests
//
//  PP-4326 (3.0.2 hotfix). Regression tests for the VoiceOver activation
//  contract on the shared BookListView row used by search, More…, MyBooks,
//  and Holds.
//
//  Bug: PP-3968's collapse-to-single-element +
//  .accessibilityRemoveTraits(.isButton) on the outer Button stripped the
//  activation contract, so VoiceOver's synthesized double-tap routed
//  through SwiftUI hit-test to the first inner action button (Borrow/Read)
//  instead of calling onSelect to open the detail view.
//
//  Fix: structural. NormalBookCell now takes an `onSelect: (() -> Void)?`
//  closure and wraps the cover + title/author area in a SwiftUI Button
//  that fires it. BookButtonsView (Borrow/Read/Listen/Return) sits as a
//  real sibling in the right column. The earlier .accessibilityActions /
//  overlay / .accessibilityElement-wrangling approaches did not register
//  their callbacks on device — only true structural siblings in the
//  SwiftUI view tree reliably surface as individually focusable VoiceOver
//  elements.
//
//  Tests below are source-level sentinels (same pattern as the existing
//  PP-3980 test in CatalogLaneRowViewAccessibilityTests) plus mocker-
//  backed behavior checks of the canonical voiceOverLabel that the fix
//  relies on.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class BookListViewAccessibilityTests: XCTestCase {

    // MARK: - Source-level sentinels (BookListView)

    /// The row wrapper must NOT remove the .isButton trait — that was the
    /// regression introduced by PP-3968 and reported as PP-4326. Removing
    /// the trait left VoiceOver's synthesized double-tap to route through
    /// SwiftUI's hit-test, which lands on the first inner action button
    /// instead of firing the row's onSelect closure.
    func testBookListView_doesNotRemoveButtonTrait() throws {
        let source = try Self.source(for: "Palace/MyBooks/MyBooks/BookListView.swift")
        XCTAssertFalse(
            source.contains(".accessibilityRemoveTraits(.isButton)"),
            "BookListView must not strip the .isButton trait — that breaks VoiceOver activation and routes the synthesized tap to the first inner action button (PP-4326)."
        )
    }

    /// PP-4326 fix: BookListView passes an onSelect closure into BookCell
    /// so NormalBookCell's row-info Button can fire it on activation.
    func testBookListView_passesOnSelectIntoBookCell() throws {
        let source = try Self.source(for: "Palace/MyBooks/MyBooks/BookListView.swift")
        XCTAssertTrue(
            source.contains("onSelect:"),
            "BookListView must pass an onSelect closure to BookCell so NormalBookCell's row-info Button can open book details on VoiceOver activation (PP-4326)."
        )
    }

    // MARK: - Source-level sentinels (BookCell + NormalBookCell)

    /// BookCell must accept and forward an onSelect closure so the
    /// callsite-supplied "open details" action reaches NormalBookCell.
    func testBookCell_acceptsAndForwardsOnSelect() throws {
        let source = try Self.source(for: "Palace/MyBooks/MyBooks/BookCell/BookCell.swift")
        XCTAssertTrue(
            source.contains("onSelect"),
            "BookCell must accept an onSelect closure and forward it to NormalBookCell (PP-4326)."
        )
    }

    /// NormalBookCell must declare an onSelect param so it can build the
    /// row-info SwiftUI Button that opens book details on activation.
    func testNormalBookCell_acceptsOnSelect() throws {
        let source = try Self.source(for: "Palace/MyBooks/MyBooks/BookCell/NormalBookCell.swift")
        XCTAssertTrue(
            source.contains("onSelect"),
            "NormalBookCell must accept an onSelect closure that drives the row-info Button's tap action (PP-4326)."
        )
    }

    /// The row-info region in NormalBookCell must be a real SwiftUI Button
    /// (not a Color.clear overlay or .accessibilityElement wrap) so the
    /// SwiftUI accessibility engine surfaces it as a focusable element in
    /// linear-swipe order, and the BookButtonsView action buttons are
    /// genuine accessibility-tree siblings.
    func testNormalBookCell_rowInfoIsRealSwiftUIButton() throws {
        let source = try Self.source(for: "Palace/MyBooks/MyBooks/BookCell/NormalBookCell.swift")
        XCTAssertTrue(
            source.contains("Button(action: onSelect"),
            "NormalBookCell must wrap the cover + title/author region in `Button(action: onSelect, label:)` so the row-info element is a real SwiftUI Button — guarantees VoiceOver focus + double-tap activation, and makes BookButtonsView's buttons real siblings in the accessibility tree (PP-4326)."
        )
    }

    /// The row-info Button must carry the canonical voiceOverLabel from
    /// TPPBook+Accessibility (PP-3968) — VoiceOver should hear
    /// "Title, by Author" rather than the raw concatenation of inner Text
    /// labels.
    func testNormalBookCell_usesCanonicalVoiceOverLabel() throws {
        let source = try Self.source(for: "Palace/MyBooks/MyBooks/BookCell/NormalBookCell.swift")
        XCTAssertTrue(
            source.contains("voiceOverLabel"),
            "NormalBookCell's row-info Button must use TPPBook.voiceOverLabel so VoiceOver announces the canonical 'Title, by Author' (PP-3968 + PP-4326)."
        )
    }

    /// The row-info Button must carry an "opens book details" hint so
    /// VoiceOver users hear what double-tap will do after the title is
    /// read.
    func testNormalBookCell_announcesOpenDetailsHint() throws {
        let source = try Self.source(for: "Palace/MyBooks/MyBooks/BookCell/NormalBookCell.swift")
        XCTAssertTrue(
            source.contains("opensBookDetails") || source.contains("Opens book details"),
            "NormalBookCell must apply an .accessibilityHint that describes the row's default action — 'Opens book details' — so VoiceOver users know what activation does (PP-4326)."
        )
    }

    /// PP-4326 cleanup: BookListView no longer wrangles accessibility-
    /// element / accessibilityActions / overlay patterns at the list
    /// level. The structural sibling-Button approach in NormalBookCell
    /// is the entire accessibility story.
    func testBookListView_noListLevelAccessibilityWrangling() throws {
        let source = try Self.source(for: "Palace/MyBooks/MyBooks/BookListView.swift")
        // Earlier attempts: .accessibilityElement(children: .ignore) +
        // .accessibilityRemoveTraits(.isButton) (PP-3968 broke things), then
        // .accessibilityElement(children: .contain) + overlay + Color.clear +
        // .accessibilityActions (didn't register callbacks on device). Today's
        // approach is purely structural — no list-level wrappers.
        XCTAssertFalse(
            source.contains(".accessibilityElement(children: "),
            "BookListView should not wrangle accessibility elements at the list level — the structural sibling-Button approach in NormalBookCell carries the row's accessibility tree (PP-4326)."
        )
        XCTAssertFalse(
            source.contains(".accessibilityActions"),
            "BookListView should not use .accessibilityActions — that pattern's callbacks did not register on device. The action Buttons in BookButtonsView are real siblings of the row-info Button and reachable via linear VoiceOver navigation (PP-4326)."
        )
    }

    // MARK: - voiceOverLabel canonical-format behavior checks

    /// Sanity check that voiceOverLabel still produces the expected
    /// "Title, by Author" form that the row-info Button announces.
    func testVoiceOverLabel_ebook_titleByAuthor() {
        let book = TPPBookMocker.mockBook(title: "Frankenstein", authors: "Mary Shelley")
        XCTAssertEqual(book.voiceOverLabel, "Frankenstein, by Mary Shelley")
    }

    /// Audiobook label must include the "audiobook" designation so
    /// VoiceOver users distinguish audiobook rows from ebook rows by ear.
    func testVoiceOverLabel_audiobook_includesAudiobookDesignation() {
        let audiobook = TPPBookMocker.snapshotAudiobook()
        XCTAssertTrue(audiobook.isAudiobook, "Test prerequisite: must be an audiobook")
        XCTAssertTrue(
            audiobook.voiceOverLabel.lowercased().contains(Strings.Generic.audiobook.lowercased()),
            "voiceOverLabel must include the 'audiobook' designation for audiobook rows (PP-3968)."
        )
    }

    // MARK: - Helpers

    private static func source(for repoRelativePath: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()        // Accessibility
            .deletingLastPathComponent()        // PalaceTests
            .deletingLastPathComponent()        // repo root
            .appendingPathComponent(repoRelativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
