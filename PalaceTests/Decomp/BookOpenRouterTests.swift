//  BookOpenRouterTests.swift
//
//  The pure format -> destination table of `BookOpenRouter`. `TPPBookContentType`
//  has five cases, so every cell is asserted, from the enum and from a real book's
//  `defaultBookContentType` as call sites use it. Covers the EPUB and PDF cells
//  that `BookDetailOpenRoutingDecisionTableTests` cannot drive without the reader
//  stack.

import XCTest
import PalaceCatalog
@testable import Palace
import PalaceBookModel

@MainActor
final class BookOpenRouterTests: XCTestCase {

    // MARK: - The table, from the content type

    /// Every case of `TPPBookContentType`, one assertion each. Written out
    /// rather than looped so a mis-routed arm names itself in the failure.
    ///
    /// Mutation: swapping any two arms, or collapsing one into another, changes
    /// exactly one line here.
    func testDestination_everyContentTypeMapsToItsReader() {
        XCTAssertEqual(BookOpenRouter.destination(for: .epub), .epubReader)
        XCTAssertEqual(BookOpenRouter.destination(for: .pdf), .pdfReader)
        XCTAssertEqual(BookOpenRouter.destination(for: .audiobook), .audiobookSession)
        XCTAssertEqual(BookOpenRouter.destination(for: .streamingHTML), .streamingReader)
        XCTAssertEqual(BookOpenRouter.destination(for: .unsupported), .unsupported)
    }

    /// The table is a bijection: five content types, five distinct
    /// destinations. A change that routes two formats to the same reader — the
    /// shape a "simplifying" refactor produces — collapses the set and fails
    /// here even if the individual assertion it broke was also edited.
    func testDestination_mapsTheFiveContentTypesToFiveDistinctDestinations() {
        let contentTypes: [TPPBookContentType] = [.epub, .pdf, .audiobook, .streamingHTML, .unsupported]
        let destinations = contentTypes.map { BookOpenRouter.destination(for: $0) }
        XCTAssertEqual(destinations.count, 5, "precondition: every content type is covered")
        for destination in destinations {
            XCTAssertEqual(destinations.filter { $0 == destination }.count, 1,
                           "\(destination) is reached by more than one content type — the routing table is no longer one-to-one")
        }
    }

    // MARK: - The table, from a book

    /// The book-shaped overload must agree with the content-type one for the
    /// same book. Driven through real fixtures because
    /// `defaultBookContentType` is derived from the acquisition path, and a
    /// router that read some other property of the book would still pass the
    /// enum table above.
    func testDestination_fromBook_agreesWithItsDefaultContentType() {
        let cases: [(TPPBook, BookOpenDestination)] = [
            (TPPBookMocker.mockBook(distributorType: .EpubZip), .epubReader),
            (TPPBookMocker.mockBook(distributorType: .OpenAccessPDF), .pdfReader),
            (TPPBookMocker.mockBook(distributorType: .OpenAccessAudiobook), .audiobookSession),
            (BookDetailOpenRoutingDecisionTableTests.makeStreamingHTMLBook(id: "router-streaming"), .streamingReader),
            (TPPBookMocker.mockBook(distributorType: .Biblioboard), .unsupported)
        ]
        for (book, expected) in cases {
            XCTAssertEqual(BookOpenRouter.destination(for: book), expected,
                           "book classified as \(book.defaultBookContentType) must route to \(expected)")
            XCTAssertEqual(BookOpenRouter.destination(for: book),
                           BookOpenRouter.destination(for: book.defaultBookContentType),
                           "the book overload must be exactly the content-type overload applied to defaultBookContentType")
        }
    }
}
