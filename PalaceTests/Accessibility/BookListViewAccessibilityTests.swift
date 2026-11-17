//
//  BookListViewAccessibilityTests.swift
//
//  PP-4326: VoiceOver activation contract on the shared BookListView row
//  (search, More…, MyBooks, Holds). PP-3968's `.accessibilityElement(children:
//  .ignore)` + `.accessibilityRemoveTraits(.isButton)` collapsed each row into
//  one element, so double-tap hit the inner Borrow/Read button and the inner
//  buttons were hidden. Source-level sentinels, because SwiftUI accessibility
//  trees are not materialized in unit tests (same pattern as PP-3980).
//

import XCTest
@testable import Palace
import PalaceBookModel

@MainActor
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
