//
//  TPPBookCatalogEntryTests.swift
//  PalaceTests
//
//  `TPPBook.catalogBook(from:registryMetadata:)` decides which feed entries
//  become books in catalog lanes and the book detail screen's related lanes.
//

import XCTest
import PalaceBookModel
import PalaceCatalog
@testable import Palace

final class TPPBookCatalogEntryTests: XCTestCase {

    /// A supported open-access entry becomes the book a lane shows.
    func testCatalogBook_SupportedEntry_ReturnsBookForEntry() throws {
        let entry = try Self.entry(id: "book-1", title: "Book One")

        let book = TPPBook.catalogBook(from: entry, registryMetadata: { _ in nil })

        XCTAssertEqual(book?.identifier, "book-1")
        XCTAssertEqual(book?.title, "Book One")
    }

    /// The registry's copy wins, so a lane shows what the patron already holds.
    func testCatalogBook_RegistryHasNewerMetadata_ReturnsRegistryBook() throws {
        let entry = try Self.entry(id: "book-1", title: "Feed Title")
        let registryCopy = try XCTUnwrap(TPPBook(entry: try Self.entry(id: "book-1", title: "Registry Title")))
        var askedFor: String?

        let book = TPPBook.catalogBook(from: entry, registryMetadata: { asked in
            askedFor = asked.identifier
            return registryCopy
        })

        XCTAssertEqual(askedFor, "book-1")
        XCTAssertEqual(book?.title, "Registry Title")
    }

    /// An entry in a format the app cannot open is left out of the lane.
    func testCatalogBook_UnsupportedFormat_ReturnsNil() throws {
        let entry = try Self.entry(id: "book-x", title: "Odd", acquisitionType: "application/x-not-a-book")

        XCTAssertNil(TPPBook.catalogBook(from: entry, registryMetadata: { _ in nil }))
    }

    /// An entry with no acquisition link cannot be borrowed and is left out.
    func testCatalogBook_NoAcquisition_ReturnsNil() throws {
        let entry = try Self.entry(id: "book-y", title: "No Link", acquisitionType: nil)

        XCTAssertNil(TPPBook.catalogBook(from: entry, registryMetadata: { _ in nil }))
    }

    /// The format check runs on the registry's copy, not only on the feed entry.
    func testCatalogBook_RegistryCopyUnsupported_ReturnsNil() throws {
        let entry = try Self.entry(id: "book-1", title: "Feed Title")
        let unsupportedCopy = try XCTUnwrap(TPPBook(entry: try Self.entry(
            id: "book-1", title: "Old", acquisitionType: "application/x-not-a-book")))

        XCTAssertNil(TPPBook.catalogBook(from: entry, registryMetadata: { _ in unsupportedCopy }))
    }

    // MARK: - Fixtures

    private static func entry(id: String,
                              title: String,
                              acquisitionType: String? = "application/epub+zip") throws -> TPPOPDSEntry {
        let acquisition = acquisitionType.map {
            "<link rel=\"http://opds-spec.org/acquisition/open-access\" href=\"https://example.com/books/\(id).epub\" type=\"\($0)\"/>"
        } ?? ""
        let document = """
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom" xmlns:opds="http://opds-spec.org/2010/catalog">
          <id>urn:uuid:entry-fixture</id>
          <title>Fixture</title>
          <updated>2024-01-01T00:00:00Z</updated>
          <entry>
            <id>\(id)</id>
            <title>\(title)</title>
            <updated>2024-01-01T00:00:00Z</updated>
            \(acquisition)
          </entry>
        </feed>
        """
        let xml = try XCTUnwrap(TPPXML.xml(withData: Data(document.utf8)), "fixture XML must parse")
        let feed = try XCTUnwrap(TPPOPDSFeed(xml: xml), "fixture feed must parse")
        return try XCTUnwrap((feed.entries as? [TPPOPDSEntry])?.first, "fixture must hold one entry")
    }
}
