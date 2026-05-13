//
//  BookListViewAccessibilityTests.swift
//  PalaceTests
//
//  PP-4326 (3.0.2 hotfix). Regression tests for the VoiceOver activation
//  contract on the shared BookListView row used by search, More…, MyBooks,
//  and Holds. The bug: PP-3968's collapse-to-single-element +
//  .accessibilityRemoveTraits(.isButton) on the outer Button stripped the
//  activation contract, so VoiceOver's synthesized double-tap routed
//  through SwiftUI hit-test to the first inner action button (Borrow/Read)
//  instead of calling onSelect to open the detail view.
//
//  The fix keeps the outer Button (so visual taps still work and the row
//  is announced as a button), restores the .isButton trait by NOT removing
//  it, and exposes the in-row action buttons (Borrow/Read/Listen/Return)
//  as VoiceOver rotor custom actions — the Apple-canonical pattern used by
//  Mail, Reminders, and Messages for list rows with auxiliary actions.
//
//  SwiftUI's accessibility tree is not materialized in unit tests without
//  VoiceOver running, so these tests are source-level sentinels (same
//  pattern as the existing PP-3980 test in
//  CatalogLaneRowViewAccessibilityTests) plus mocker-backed behavior
//  checks of the canonical voiceOverLabel that the fix relies on.
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
            "BookListView must not strip the .isButton trait from the row — that breaks VoiceOver activation and routes the synthesized tap to the first inner action button (PP-4326)."
        )
    }

    /// The row must use the canonical voiceOverLabel from
    /// TPPBook+Accessibility (PP-3968) — VoiceOver should hear
    /// "Title, by Author" rather than the raw concatenation of the cell's
    /// inner Text views.
    func testBookListView_usesCanonicalVoiceOverLabel() throws {
        let source = try Self.source(for: "Palace/MyBooks/MyBooks/BookListView.swift")
        XCTAssertTrue(
            source.contains("voiceOverLabel"),
            "BookListView must apply TPPBook.voiceOverLabel as the row's accessibilityLabel so VoiceOver announces the canonical 'Title, by Author' (PP-3968 + PP-4326)."
        )
    }

    /// The row must announce its activation effect via an
    /// .accessibilityHint so VoiceOver users hear what double-tap does
    /// after the title is read.
    func testBookListView_announcesOpenDetailsHint() throws {
        let source = try Self.source(for: "Palace/MyBooks/MyBooks/BookListView.swift")
        XCTAssertTrue(
            source.contains("opensBookDetails") || source.contains("Opens book details"),
            "BookListView must apply an .accessibilityHint that describes the row's default action — 'Opens book details' — so VoiceOver users know what activation does (PP-4326)."
        )
    }

    /// The row must expose its in-row action buttons (Borrow/Read/Listen/
    /// Return, etc.) as VoiceOver rotor actions via .accessibilityActions
    /// so screen-reader users can perform them without leaving the row in
    /// linear navigation. This is the Apple-canonical pattern for list
    /// rows with auxiliary actions.
    func testBookListView_exposesRotorActionsForInRowButtons() throws {
        let source = try Self.source(for: "Palace/MyBooks/MyBooks/BookListView.swift")
        XCTAssertTrue(
            source.contains(".accessibilityActions"),
            "BookListView must apply .accessibilityActions to expose in-row Borrow/Read/Listen/Return actions as VoiceOver rotor custom actions (PP-4326)."
        )
    }

    /// The rotor actions block must drive the actions via the cell's
    /// model (handleAction(for:)) so each action type fires the correct
    /// behavior — the same path as a touch on the visible button.
    func testBookListView_rotorActionsRouteThroughModel() throws {
        let source = try Self.source(for: "Palace/MyBooks/MyBooks/BookListView.swift")
        XCTAssertTrue(
            source.contains("BookRowAccessibilityActions"),
            "BookListView must use BookRowAccessibilityActions inside .accessibilityActions to ensure each rotor action calls model.handleAction(for:) — the same code path as a touch on the visible button (PP-4326)."
        )
    }

    /// PP-4326 follow-up: the row must be an accessibility CONTAINER so the
    /// inner BookButtonsView Buttons are individually focusable in VoiceOver
    /// linear-swipe navigation. The collapse-to-one-element pattern
    /// (.accessibilityElement(children: .ignore)) made the buttons reachable
    /// only via the rotor menu, which the original reporter flagged as
    /// insufficient.
    func testBookListView_rowIsAccessibilityContainer() throws {
        let source = try Self.source(for: "Palace/MyBooks/MyBooks/BookListView.swift")
        XCTAssertTrue(
            source.contains(".accessibilityElement(children: .contain)"),
            "BookListView must apply .accessibilityElement(children: .contain) on the row so the inner action Buttons are individually focusable in VoiceOver linear navigation (PP-4326 follow-up)."
        )
    }

    /// PP-4326 follow-up: the row-info overlay must use .accessibilitySortPriority
    /// so it's announced FIRST in the per-row VoiceOver order (before the
    /// action buttons). Users should hear "Title, by Author. Button. Opens
    /// book details." then "Borrow. Button." then "Read. Button." etc.
    func testBookListView_rowInfoElementHasSortPriority() throws {
        let source = try Self.source(for: "Palace/MyBooks/MyBooks/BookListView.swift")
        XCTAssertTrue(
            source.contains(".accessibilitySortPriority"),
            "BookListView must apply .accessibilitySortPriority on the row-info overlay so it's announced before the action buttons in VoiceOver linear order (PP-4326 follow-up)."
        )
    }

    /// BookRowAccessibilityActions must be defined and must iterate over
    /// the model's available button types so rotor actions stay in sync
    /// with the visible in-row buttons (the actions list is driven by
    /// download/loan state, not a hardcoded list).
    func testBookRowAccessibilityActions_iteratesModelButtonTypes() throws {
        let source = try Self.source(for: "Palace/MyBooks/MyBooks/BookListView.swift")
        XCTAssertTrue(
            source.contains("struct BookRowAccessibilityActions"),
            "BookListView.swift must define BookRowAccessibilityActions so rotor actions are co-located with the row that uses them (PP-4326)."
        )
        XCTAssertTrue(
            source.contains("model.buttonTypes"),
            "BookRowAccessibilityActions must iterate over model.buttonTypes so VoiceOver rotor actions match the visible button list per book state (PP-4326)."
        )
        XCTAssertTrue(
            source.contains("handleAction(for:"),
            "BookRowAccessibilityActions must call model.handleAction(for:) so the rotor action follows the same code path as a touch on the visible button (PP-4326)."
        )
    }

    // MARK: - voiceOverLabel canonical-format behavior checks

    /// Sanity check that voiceOverLabel still produces the expected
    /// "Title, by Author" form that the row announces. If this regresses,
    /// PP-3968's canonical label is broken regardless of the PP-4326
    /// wiring.
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
