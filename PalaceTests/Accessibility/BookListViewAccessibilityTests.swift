//
//  BookListViewAccessibilityTests.swift
//  PalaceTests
//
//  PP-4326 (3.0.2 hotfix). Regression tests for the VoiceOver activation
//  contract on the shared BookListView row used by search, More…, MyBooks,
//  and Holds.
//
//  Bug: PP-3968's .accessibilityElement(children: .ignore) +
//  .accessibilityRemoveTraits(.isButton) on the outer Button collapsed
//  every book row into a single non-button accessibility element. Two
//  consequences:
//    1. VoiceOver's synthesized double-tap on the row routed through
//       SwiftUI hit-test to the first inner action button (Borrow/Read)
//       instead of firing the outer Button's onSelect closure.
//    2. The inner action buttons themselves were no longer surfaced as
//       individual VoiceOver elements (because the parent told VoiceOver
//       to ignore its children).
//
//  Fix: just undo PP-3968. The outer Button + a custom .accessibilityLabel
//  + .accessibilityHint is enough — SwiftUI's natural Button accessibility
//  handles the rest. The inner action Buttons in BookButtonsView are real
//  SwiftUI Buttons with their own .accessibilityLabel, so they surface as
//  separate accessibility elements automatically. iOS routes a VoiceOver
//  tap to the topmost accessibility element at the tap location:
//    - Tap on the Borrow button area → Borrow is topmost → focus Borrow.
//    - Tap on cover or title → no inner Button there → focus the outer
//      row Button (which announces "Title, by Author. Button. Opens
//      book details.").
//
//  Tests are source-level sentinels — SwiftUI accessibility trees aren't
//  materialized in unit tests without VoiceOver running, so we lock the
//  contract at the source level (same pattern as PP-3980's test in
//  CatalogLaneRowViewAccessibilityTests).
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class BookListViewAccessibilityTests: XCTestCase {

    // MARK: - Source-level sentinels (BookListView)

    /// The row wrapper must NOT remove the .isButton trait — that was the
    /// regression introduced by PP-3968 and reported as PP-4326.
    func testBookListView_doesNotRemoveButtonTrait() throws {
        let source = try Self.source(for: "Palace/MyBooks/MyBooks/BookListView.swift")
        XCTAssertFalse(
            source.contains(".accessibilityRemoveTraits(.isButton)"),
            "BookListView must not strip the .isButton trait — that breaks VoiceOver activation and routes the synthesized tap to the first inner action button (PP-4326)."
        )
    }

    /// The row wrapper must NOT use .accessibilityElement(children: .ignore)
    /// — that collapses the cell into a single VoiceOver element and hides
    /// the inner action buttons from VoiceOver, which is exactly what
    /// PP-3968 did and the reported PP-4326 user complaint asks us to undo.
    func testBookListView_doesNotIgnoreChildren() throws {
        let source = try Self.source(for: "Palace/MyBooks/MyBooks/BookListView.swift")
        XCTAssertFalse(
            source.contains(".accessibilityElement(children: .ignore)"),
            "BookListView must not use .accessibilityElement(children: .ignore) — that hides the inner BookButtonsView Buttons from VoiceOver. Just rely on SwiftUI's natural Button accessibility (PP-4326)."
        )
    }

    /// The row must use the canonical voiceOverLabel from
    /// TPPBook+Accessibility (PP-3968) — VoiceOver announces the row as
    /// "Title, by Author" rather than the raw concatenation of inner Text
    /// labels.
    func testBookListView_usesCanonicalVoiceOverLabel() throws {
        let source = try Self.source(for: "Palace/MyBooks/MyBooks/BookListView.swift")
        XCTAssertTrue(
            source.contains("voiceOverLabel"),
            "BookListView must apply TPPBook.voiceOverLabel as the row's .accessibilityLabel so VoiceOver announces the canonical 'Title, by Author' (PP-3968 + PP-4326)."
        )
    }

    /// The row must announce what activation does via .accessibilityHint
    /// — "Opens book details" — so VoiceOver users hear the activation
    /// effect after the title is read.
    func testBookListView_announcesOpenDetailsHint() throws {
        let source = try Self.source(for: "Palace/MyBooks/MyBooks/BookListView.swift")
        XCTAssertTrue(
            source.contains("opensBookDetails") || source.contains("Opens book details"),
            "BookListView must apply .accessibilityHint(opensBookDetails) so VoiceOver announces what activating the row does (PP-4326)."
        )
    }

    /// The row wrapper IS a real SwiftUI Button — that's what gives the
    /// row its accessibility-element status, default activation, and
    /// .isButton trait, while letting the inner BookButtonsView Buttons
    /// surface as separate accessibility elements via SwiftUI's natural
    /// Button-inside-Button accessibility.
    func testBookListView_rowWrapperIsSwiftUIButton() throws {
        let source = try Self.source(for: "Palace/MyBooks/MyBooks/BookListView.swift")
        XCTAssertTrue(
            source.contains("Button(action: { onSelect(book) }"),
            "BookListView must wrap the cell in a real SwiftUI Button(action: { onSelect(book) }) — that's the row-level accessibility element with double-tap → open detail. Inner BookButtonsView Buttons surface as separate accessibility elements automatically (PP-4326)."
        )
    }

    /// PP-4326 constraint from product: the cell's visual layout must be
    /// identical to 3.0.1. BookCell and NormalBookCell must therefore
    /// have zero diff vs the 3.0.1 baseline.
    func testBookCell_unchangedFrom3_0_1() throws {
        let bookCell = try Self.source(for: "Palace/MyBooks/MyBooks/BookCell/BookCell.swift")
        XCTAssertFalse(
            bookCell.contains("onSelect"),
            "BookCell must remain at the 3.0.1 baseline (no onSelect parameter) — the PP-4326 fix lives at the BookListView level, not by mutating BookCell. Visual layout cannot change."
        )
    }

    func testNormalBookCell_unchangedFrom3_0_1() throws {
        let normalBookCell = try Self.source(for: "Palace/MyBooks/MyBooks/BookCell/NormalBookCell.swift")
        XCTAssertFalse(
            normalBookCell.contains("var onSelect"),
            "NormalBookCell must remain at the 3.0.1 baseline (no onSelect parameter) — the PP-4326 fix lives at the BookListView level, not by mutating NormalBookCell. Visual layout cannot change."
        )
    }

    // MARK: - voiceOverLabel canonical-format behavior checks

    /// Sanity check that voiceOverLabel still produces the expected
    /// "Title, by Author" form that the row's .accessibilityLabel
    /// announces.
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
