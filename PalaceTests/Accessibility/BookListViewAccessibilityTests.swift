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
//  instead of calling onSelect to open the detail view, AND made the
//  in-row action buttons unreachable in linear VoiceOver navigation.
//
//  Fix: BookListView wraps each cell in an outer SwiftUI Button (visual
//  tap = open detail — unchanged from 3.0.0) and replaces the row's
//  ACCESSIBILITY tree via `.accessibilityRepresentation { ... }`. The
//  representation returns a VStack of real SwiftUI Buttons — one for
//  "Open book details" using the canonical voiceOverLabel, then one
//  per available BookButtonType (Borrow/Read/Listen/Return). Each is a
//  structural accessibility element, so VoiceOver linear-swipe reaches
//  each and double-tap activates them. The visible BookCell /
//  NormalBookCell tree is untouched (zero diff vs the 3.0.1 baseline)
//  so the cell layout is identical to what shipped on 3.0.1.
//
//  Tests are source-level sentinels — SwiftUI accessibility trees are
//  not materialized in unit tests without VoiceOver running, so we lock
//  the contract at the source level (same pattern as PP-3980's test in
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
            "BookListView must not strip the .isButton trait (PP-4326)."
        )
    }

    /// PP-4326 fix: BookListView uses .accessibilityRepresentation to
    /// provide a custom accessibility tree without changing the visual
    /// tree. This is what makes the in-row action buttons individually
    /// focusable in VoiceOver linear navigation while preserving the
    /// 3.0.1 visual layout.
    func testBookListView_usesAccessibilityRepresentation() throws {
        let source = try Self.source(for: "Palace/MyBooks/MyBooks/BookListView.swift")
        XCTAssertTrue(
            source.contains(".accessibilityRepresentation"),
            "BookListView must apply .accessibilityRepresentation to replace the row's accessibility tree with a structural one (row-info Button + per-action Buttons). Visual tree stays unchanged (PP-4326)."
        )
    }

    /// The representation must include the canonical voiceOverLabel from
    /// TPPBook+Accessibility (PP-3968) for the row-info Button.
    func testBookListView_representationUsesCanonicalVoiceOverLabel() throws {
        let source = try Self.source(for: "Palace/MyBooks/MyBooks/BookListView.swift")
        XCTAssertTrue(
            source.contains("voiceOverLabel"),
            "BookListView's accessibility representation must use TPPBook.voiceOverLabel so VoiceOver announces the canonical 'Title, by Author' for the row-info Button (PP-3968 + PP-4326)."
        )
    }

    /// The representation must announce what double-tap will do via an
    /// .accessibilityHint that says "Opens book details".
    func testBookListView_representationAnnouncesOpenDetailsHint() throws {
        let source = try Self.source(for: "Palace/MyBooks/MyBooks/BookListView.swift")
        XCTAssertTrue(
            source.contains("opensBookDetails") || source.contains("Opens book details"),
            "BookListView's accessibility representation must announce what double-tap does — 'Opens book details' — via .accessibilityHint (PP-4326)."
        )
    }

    /// The representation must iterate over the model's available
    /// buttonTypes so VoiceOver surfaces a per-action Button (Borrow,
    /// Read, etc.) that matches the visible BookButtonsView. Each per-
    /// action Button calls model.callDelegate(for:) — the same code path
    /// as a touch on the visible button.
    func testBookListView_representationIteratesModelButtonTypes() throws {
        let source = try Self.source(for: "Palace/MyBooks/MyBooks/BookListView.swift")
        XCTAssertTrue(
            source.contains("model.buttonTypes") || source.contains("availableButtonTypes"),
            "BookListView's accessibility representation must iterate over the model's available buttonTypes so VoiceOver surfaces a per-action Button matching the visible BookButtonsView (PP-4326)."
        )
        XCTAssertTrue(
            source.contains("callDelegate(for:"),
            "Each per-action Button in the accessibility representation must call model.callDelegate(for:) — same code path as the visible BookButtonsView Button (PP-4326)."
        )
    }

    /// PP-4326 constraint from product: the cell's visual layout must be
    /// identical to 3.0.1. BookCell and NormalBookCell must therefore
    /// have zero diff vs the 3.0.1 baseline. If either acquires changes
    /// in scope of the hotfix, this test fires.
    func testBookCell_unchangedFrom3_0_1() throws {
        let bookCell = try Self.source(for: "Palace/MyBooks/MyBooks/BookCell/BookCell.swift")
        // 3.0.1 baseline: no onSelect parameter, just delegates to NormalBookCell.
        XCTAssertFalse(
            bookCell.contains("onSelect"),
            "BookCell must remain at the 3.0.1 baseline (no onSelect parameter) — the PP-4326 fix lives at the BookListView level via .accessibilityRepresentation, not by mutating BookCell."
        )
    }

    func testNormalBookCell_unchangedFrom3_0_1() throws {
        let normalBookCell = try Self.source(for: "Palace/MyBooks/MyBooks/BookCell/NormalBookCell.swift")
        // 3.0.1 baseline: no onSelect parameter, no rowInfoTapTarget helper.
        XCTAssertFalse(
            normalBookCell.contains("var onSelect"),
            "NormalBookCell must remain at the 3.0.1 baseline (no onSelect parameter) — the PP-4326 fix lives at the BookListView level via .accessibilityRepresentation, not by mutating NormalBookCell. Visual layout cannot change."
        )
    }

    // MARK: - voiceOverLabel canonical-format behavior checks

    /// Sanity check that voiceOverLabel still produces the expected
    /// "Title, by Author" form that the representation's row-info Button
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
