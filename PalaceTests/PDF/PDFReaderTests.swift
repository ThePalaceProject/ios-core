//
//  PDFReaderTests.swift
//  PalaceTests
//
//  Tests for TPPPDFPage, TPPPDFPageBookmark, and TPPPDFReaderMode.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import Combine
@testable import Palace

@MainActor
final class PDFReaderTests: XCTestCase {

    // MARK: - Helper Methods

    private func createPDFBook() -> TPPBook {
        return TPPBookMocker.mockBook(distributorType: .OpenAccessPDF)
    }

    private func createLCPPDFBook() -> TPPBook {
        return TPPBookMocker.mockBook(distributorType: .PDFLCP)
    }

    // MARK: - TPPPDFPage Tests

    func testPDFPage_Initialization() {
        let page = TPPPDFPage(pageNumber: 5)

        XCTAssertEqual(page.pageNumber, 5)
        // Verify round-trip via JSON to prove the stored value is the canonical one
        let data = try? JSONEncoder().encode(page)
        XCTAssertNotNil(data, "TPPPDFPage should be encodable")
        let json = data.flatMap { String(data: $0, encoding: .utf8) }
        XCTAssertTrue(json?.contains("5") ?? false, "Encoded JSON should contain the page number")
    }

    func testPDFPage_Encoding() throws {
        let page = TPPPDFPage(pageNumber: 10)
        let encoder = JSONEncoder()

        let data = try encoder.encode(page)
        XCTAssertFalse(data.isEmpty)

        let json = String(data: data, encoding: .utf8)
        XCTAssertTrue(json?.contains("10") ?? false)
    }

    func testPDFPage_Decoding() throws {
        let json = "{\"pageNumber\":15}"
        let data = json.data(using: .utf8)!
        let decoder = JSONDecoder()

        let page = try decoder.decode(TPPPDFPage.self, from: data)

        XCTAssertEqual(page.pageNumber, 15)
    }

    func testPDFPage_RoundTrip() throws {
        let originalPage = TPPPDFPage(pageNumber: 42)
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(originalPage)
        let decodedPage = try decoder.decode(TPPPDFPage.self, from: data)

        XCTAssertEqual(originalPage.pageNumber, decodedPage.pageNumber)
    }

    // MARK: - TPPPDFPageBookmark Tests

    func testPDFPageBookmark_Initialization() {
        let bookmark = TPPPDFPageBookmark(page: 25)

        XCTAssertEqual(bookmark.page, 25)
        XCTAssertEqual(bookmark.type, TPPPDFPageBookmark.Types.locatorPage.rawValue)
        XCTAssertNil(bookmark.annotationID)
    }

    func testPDFPageBookmark_WithAnnotationID() {
        let bookmark = TPPPDFPageBookmark(page: 30, annotationID: "annotation-123")

        XCTAssertEqual(bookmark.page, 30)
        XCTAssertEqual(bookmark.annotationID, "annotation-123")
    }

    func testPDFPageBookmark_ConformsToBookmark() {
        let bookmark = TPPPDFPageBookmark(page: 1)

        XCTAssertTrue(bookmark is Bookmark)
        XCTAssertEqual(bookmark.page, 1, "Page number must be preserved during Bookmark conformance init")
        XCTAssertEqual(bookmark.type, "LocatorPage", "Bookmark type must be LocatorPage")
    }

    func testPDFPageBookmark_Encoding() throws {
        let bookmark = TPPPDFPageBookmark(page: 50)
        let encoder = JSONEncoder()

        let data = try encoder.encode(bookmark)
        let json = String(data: data, encoding: .utf8)!

        XCTAssertTrue(json.contains("LocatorPage"))
        XCTAssertTrue(json.contains("50"))
    }

    func testPDFPageBookmark_Decoding() throws {
        let json = "{\"@type\":\"LocatorPage\",\"page\":75}"
        let data = json.data(using: .utf8)!
        let decoder = JSONDecoder()

        let bookmark = try decoder.decode(TPPPDFPageBookmark.self, from: data)

        XCTAssertEqual(bookmark.page, 75)
        XCTAssertEqual(bookmark.type, "LocatorPage")
    }

    // MARK: - TPPPDFReaderMode Tests

    func testReaderMode_Values() {
        XCTAssertEqual(TPPPDFReaderMode.reader.value, "Reader")
        XCTAssertEqual(TPPPDFReaderMode.previews.value, "Page previews")
        XCTAssertEqual(TPPPDFReaderMode.bookmarks.value, "Bookmarks")
        XCTAssertEqual(TPPPDFReaderMode.toc.value, "TOC")
        XCTAssertEqual(TPPPDFReaderMode.search.value, "Search")
    }

    // MARK: - Book Content Type Tests

    func testPDFBook_ContentType() {
        let book = createPDFBook()

        XCTAssertEqual(book.defaultBookContentType, .pdf)
        XCTAssertNotEqual(book.defaultBookContentType, .epub, "PDF book must not report epub content type")
        XCTAssertFalse(book.isAudiobook, "PDF book must not be identified as audiobook")
    }

    func testLCPPDFBook_ContentType() {
        let book = createLCPPDFBook()

        // LCP PDF content type detection depends on the acquisition path
        let contentType = book.defaultBookContentType
        XCTAssertTrue(
            contentType == .pdf || contentType == .unsupported,
            "LCP PDF should be .pdf or .unsupported depending on acquisition configuration"
        )
        // The book should still have a valid identifier and title regardless of DRM type
        XCTAssertFalse(book.identifier.isEmpty, "LCP PDF book should have a non-empty identifier")
        XCTAssertFalse(book.title.isEmpty, "LCP PDF book should have a non-empty title")
        // Verify the book is distinct from a plain PDF book
        let plainPDF = createPDFBook()
        XCTAssertNotEqual(book.identifier, plainPDF.identifier, "LCP PDF and plain PDF should be different book instances")
    }
}
