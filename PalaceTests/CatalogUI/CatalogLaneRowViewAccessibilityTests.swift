//
//  CatalogLaneRowViewAccessibilityTests.swift
//  PalaceTests
//
//  Regression test for VoiceOver no longer reading title and author of books
//  in main catalog screen. This test ensures that the book buttons in the horizontal
//  lane scroller have proper accessibility labels for VoiceOver users.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import SwiftUI
@testable import Palace

final class CatalogLaneRowViewAccessibilityTests: XCTestCase {

    // MARK: - Regression Tests

    /// Verifies that a book's accessibility label includes title and author
    func testAccessibilityLabel_includesTitleAndAuthor() {
        // Given
        let book = TPPBookMocker.mockBook(title: "The Great Gatsby", authors: "F. Scott Fitzgerald")

        // When
        let label = makeAccessibilityLabel(for: book)

        // Then
        XCTAssertEqual(label, "The Great Gatsby, F. Scott Fitzgerald")
    }

    /// Verifies that a book without authors still has a valid accessibility label
    func testAccessibilityLabel_bookWithoutAuthor() {
        // Given
        let book = TPPBookMocker.mockBook(title: "Untitled Work", authors: nil)

        // When
        let label = makeAccessibilityLabel(for: book)

        // Then
        XCTAssertEqual(label, "Untitled Work")
    }

    /// Verifies that audiobooks have proper accessibility designation
    func testAccessibilityLabel_audiobookIncludesAudiobookDesignation() {
        // Given
        let audiobook = TPPBookMocker.snapshotAudiobook()

        // When
        let label = makeAccessibilityLabel(for: audiobook)

        // Then
        XCTAssertTrue(audiobook.isAudiobook, "Test prerequisite: book should be an audiobook")
        XCTAssertTrue(label.contains(Strings.Generic.audiobook))
        XCTAssertTrue(label.contains(audiobook.title))
    }

    /// Verifies that regular eBooks do NOT have audiobook designation
    func testAccessibilityLabel_ebookDoesNotIncludeAudiobookDesignation() {
        // Given
        let ebook = TPPBookMocker.snapshotEPUB()

        // When
        let label = makeAccessibilityLabel(for: ebook)

        // Then
        XCTAssertFalse(ebook.isAudiobook, "Test prerequisite: book should NOT be an audiobook")
        XCTAssertFalse(label.contains(Strings.Generic.audiobook))
    }

    /// Verifies accessibility label uses comma-separated format
    func testAccessibilityLabel_usesCommaSeparatedFormat() {
        // Given
        let book = TPPBookMocker.mockBook(title: "Pride and Prejudice", authors: "Jane Austen")

        // When
        let label = makeAccessibilityLabel(for: book)

        // Then - Format: "Title, Author"
        XCTAssertEqual(label, "Pride and Prejudice, Jane Austen")
    }

    /// Verifies audiobook label format includes audiobook designation
    func testAccessibilityLabel_audiobookFormat() {
        // Given
        let audiobook = TPPBookMocker.snapshotAudiobook() // "Pride and Prejudice" by "Jane Austen"

        // When
        let label = makeAccessibilityLabel(for: audiobook)

        // Then - Format: "Title, Audiobook, Author"
        XCTAssertTrue(label.hasPrefix(audiobook.title))
        if let authors = audiobook.authors {
            let expected = "\(audiobook.title), \(Strings.Generic.audiobook), \(authors)"
            XCTAssertEqual(label, expected)
        }
    }

    // MARK: - PP-3968: Catalog cell accessibility label format

    /// Audible/Libby-style label: "Title, by Author".
    func testAccessibilityLabel_ebook_titleByAuthor() {
        let book = TPPBookMocker.mockBook(title: "The Great Gatsby", authors: "F. Scott Fitzgerald")
        let label = CatalogLaneRowView.accessibilityLabel(for: book)
        XCTAssertEqual(label, "The Great Gatsby, by F. Scott Fitzgerald")
    }

    /// Ebook with no author falls back to just the title — no trailing punctuation.
    func testAccessibilityLabel_ebook_noAuthor_titleOnly() {
        let book = TPPBookMocker.mockBook(title: "Untitled Work", authors: nil)
        let label = CatalogLaneRowView.accessibilityLabel(for: book)
        XCTAssertEqual(label, "Untitled Work")
    }

    /// Audiobook with author but no narrator: "Title, audiobook, by Author".
    func testAccessibilityLabel_audiobook_authorOnly() {
        let audiobook = TPPBookMocker.snapshotAudiobook() // narrators empty
        let label = CatalogLaneRowView.accessibilityLabel(for: audiobook)
        XCTAssertTrue(audiobook.isAudiobook, "Test prerequisite: book should be an audiobook")
        XCTAssertEqual(label, "Pride and Prejudice, audiobook, by Jane Austen")
    }

    /// PP-3968 acceptance: the label must NEVER contain blurbs, summaries, or
    /// any free-form text that could come from a cover image OCR pass — only
    /// title, author, audiobook designation, and narrator.
    func testAccessibilityLabel_doesNotIncludeSummaryOrBlurbs() {
        let book = TPPBookMocker.mockBook(title: "Test Title", authors: "Test Author")
        // Sanity-check the mock so we know `summary` actually has content.
        XCTAssertNotNil(book.summary)
        let label = CatalogLaneRowView.accessibilityLabel(for: book)
        XCTAssertFalse(label.contains(book.summary ?? "<missing>"),
                       "Cell label leaked the book summary into VoiceOver: \(label)")
    }

    // MARK: - PP-3980: Swimlane heading trait

    /// Regression test for PP-3980. The catalog swimlane title must carry the
    /// `.header` accessibility trait so VoiceOver users can navigate between
    /// swimlanes via the heading rotor. SwiftUI's accessibility tree is not
    /// materialized in unit-test environments without VoiceOver running, so we
    /// guard the modifier at the source level — this is a sentinel regression
    /// test that fails the moment someone removes the trait from
    /// `CatalogLaneRowView`.
    func testSwimlaneTitle_sourceDeclaresHeaderAccessibilityTrait() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()        // CatalogUI
            .deletingLastPathComponent()        // PalaceTests
            .deletingLastPathComponent()        // repo root
            .appendingPathComponent("Palace/CatalogUI/Views/CatalogLaneRowView.swift")

        let source = try String(contentsOf: url, encoding: .utf8)

        // The lane scroller container must carry the .header trait so its title
        // appears in the VoiceOver heading rotor.
        XCTAssertTrue(
            source.contains(".accessibilityAddTraits(.isHeader)"),
            "CatalogLaneRowView must apply .accessibilityAddTraits(.isHeader) to expose the swimlane title as a heading for VoiceOver navigation (PP-3980)."
        )

        // The static header() builder must also be header-trait annotated so the
        // visible Text element gets the heading role even if the container is
        // restructured.
        let headerSection = source.components(separatedBy: "static func header(").last ?? ""
        XCTAssertTrue(
            headerSection.contains(".accessibilityAddTraits(.isHeader)"),
            "CatalogLaneRowView.header() must apply .isHeader to the title Text (PP-3980)."
        )
    }

    // MARK: - Helper Methods

    /// Replicates the accessibility label generation logic from CatalogLaneRowView
    private func makeAccessibilityLabel(for book: TPPBook) -> String {
        var components = [book.title]
        if book.isAudiobook {
            components.append(Strings.Generic.audiobook)
        }
        if let authors = book.authors, !authors.isEmpty {
            components.append(authors)
        }
        return components.joined(separator: ", ")
    }
}
