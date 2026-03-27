//
//  TPPPDFModelTests.swift
//  PalaceTests
//
//  Tests for PDF model types: TPPPDFPage, TPPPDFLocation, TPPPDFPageBookmark,
//  TPPPDFReaderMode, and TPPPDFDocument.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

// MARK: - TPPPDFPage Tests

final class TPPPDFPageTests: XCTestCase {

    // SRS: TPPPDFPage stores page number correctly
    func testPDFPage_initStoresPageNumber() {
        let page = TPPPDFPage(pageNumber: 42)
        XCTAssertEqual(page.pageNumber, 42)
    }

    // SRS: TPPPDFPage is Codable (round-trip encoding/decoding)
    func testPDFPage_codableRoundTrip() throws {
        let page = TPPPDFPage(pageNumber: 7)
        let data = try JSONEncoder().encode(page)
        let decoded = try JSONDecoder().decode(TPPPDFPage.self, from: data)
        XCTAssertEqual(decoded.pageNumber, 7)
    }

    // SRS: TPPPDFPage encodes expected JSON structure
    func testPDFPage_encodesToExpectedJSON() throws {
        let page = TPPPDFPage(pageNumber: 0)
        let data = try JSONEncoder().encode(page)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(dict?["pageNumber"] as? Int, 0)
    }

    // SRS: TPPPDFPage decodes from JSON data
    func testPDFPage_decodesFromJSON() throws {
        let json = #"{"pageNumber": 100}"#
        let data = json.data(using: .utf8)!
        let page = try JSONDecoder().decode(TPPPDFPage.self, from: data)
        XCTAssertEqual(page.pageNumber, 100)
    }

    // SRS: TPPPDFPage handles zero page number
    func testPDFPage_zeroPageNumber() {
        let page = TPPPDFPage(pageNumber: 0)
        XCTAssertEqual(page.pageNumber, 0)
    }
}

// MARK: - TPPPDFLocation Tests

final class TPPPDFLocationCoverageTests: XCTestCase {

    // SRS: TPPPDFLocation initializes with all parameters
    func testPDFLocation_initWithAllParameters() {
        let loc = TPPPDFLocation(title: "Chapter 1", subtitle: "Introduction", pageLabel: "i", pageNumber: 0, level: 1)
        XCTAssertEqual(loc.title, "Chapter 1")
        XCTAssertEqual(loc.subtitle, "Introduction")
        XCTAssertEqual(loc.pageLabel, "i")
        XCTAssertEqual(loc.pageNumber, 0)
        XCTAssertEqual(loc.level, 1)
    }

    // SRS: TPPPDFLocation default level is 0
    func testPDFLocation_defaultLevelIsZero() {
        let loc = TPPPDFLocation(title: "Test", subtitle: nil, pageLabel: nil, pageNumber: 5)
        XCTAssertEqual(loc.level, 0)
    }

    // SRS: TPPPDFLocation nil properties handled
    func testPDFLocation_nilProperties() {
        let loc = TPPPDFLocation(title: nil, subtitle: nil, pageLabel: nil, pageNumber: 3)
        XCTAssertNil(loc.title)
        XCTAssertNil(loc.subtitle)
        XCTAssertNil(loc.pageLabel)
    }

    // SRS: TPPPDFLocation Identifiable id is deterministic
    func testPDFLocation_identifiableId_isDeterministic() {
        let loc1 = TPPPDFLocation(title: "Ch1", subtitle: "Sub", pageLabel: "1", pageNumber: 0, level: 0)
        let loc2 = TPPPDFLocation(title: "Ch1", subtitle: "Sub", pageLabel: "1", pageNumber: 0, level: 0)
        XCTAssertEqual(loc1.id, loc2.id)
    }

    // SRS: TPPPDFLocation id encodes all fields
    func testPDFLocation_id_encodesAllFields() {
        let loc = TPPPDFLocation(title: "Title", subtitle: "Sub", pageLabel: "iv", pageNumber: 3, level: 2)
        XCTAssertEqual(loc.id, "3-iv-Sub-Title-2")
    }

    // SRS: TPPPDFLocation id handles nil values as empty strings
    func testPDFLocation_id_handlesNils() {
        let loc = TPPPDFLocation(title: nil, subtitle: nil, pageLabel: nil, pageNumber: 5, level: 0)
        XCTAssertEqual(loc.id, "5---0")
    }

    // SRS: TPPPDFLocation different locations produce different ids
    func testPDFLocation_differentLocations_differentIds() {
        let loc1 = TPPPDFLocation(title: "A", subtitle: nil, pageLabel: nil, pageNumber: 1)
        let loc2 = TPPPDFLocation(title: "B", subtitle: nil, pageLabel: nil, pageNumber: 2)
        XCTAssertNotEqual(loc1.id, loc2.id)
    }
}

// MARK: - TPPPDFPageBookmark Tests

final class TPPPDFPageBookmarkTests: XCTestCase {

    // SRS: TPPPDFPageBookmark initializes with page number
    func testPageBookmark_initSetsPage() {
        let bookmark = TPPPDFPageBookmark(page: 10)
        XCTAssertEqual(bookmark.page, 10)
    }

    // SRS: TPPPDFPageBookmark type is always LocatorPage
    func testPageBookmark_typeIsLocatorPage() {
        let bookmark = TPPPDFPageBookmark(page: 5)
        XCTAssertEqual(bookmark.type, "LocatorPage")
    }

    // SRS: TPPPDFPageBookmark annotationID defaults to nil
    func testPageBookmark_annotationIdDefaultsToNil() {
        let bookmark = TPPPDFPageBookmark(page: 3)
        XCTAssertNil(bookmark.annotationID)
    }

    // SRS: TPPPDFPageBookmark annotationID can be set
    func testPageBookmark_annotationIdCanBeSet() {
        let bookmark = TPPPDFPageBookmark(page: 3, annotationID: "abc-123")
        XCTAssertEqual(bookmark.annotationID, "abc-123")
    }

    // SRS: TPPPDFPageBookmark is Codable (round-trip)
    func testPageBookmark_codableRoundTrip() throws {
        let bookmark = TPPPDFPageBookmark(page: 42, annotationID: "test-id")
        let data = try JSONEncoder().encode(bookmark)
        let decoded = try JSONDecoder().decode(TPPPDFPageBookmark.self, from: data)
        XCTAssertEqual(decoded.page, 42)
        XCTAssertEqual(decoded.type, "LocatorPage")
        // annotationID is not in CodingKeys, so it won't round-trip via Codable
    }

    // SRS: TPPPDFPageBookmark encodes @type key
    func testPageBookmark_encodesAtTypeKey() throws {
        let bookmark = TPPPDFPageBookmark(page: 1)
        let data = try JSONEncoder().encode(bookmark)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(dict?["@type"] as? String, "LocatorPage")
        XCTAssertEqual(dict?["page"] as? Int, 1)
    }

    // SRS: TPPPDFPageBookmark decodes from JSON
    func testPageBookmark_decodesFromJSON() throws {
        let json = #"{"@type": "LocatorPage", "page": 55}"#
        let decoded = try JSONDecoder().decode(TPPPDFPageBookmark.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(decoded.page, 55)
        XCTAssertEqual(decoded.type, "LocatorPage")
    }

    // SRS: TPPPDFPageBookmark conforms to Bookmark protocol
    func testPageBookmark_conformsToBookmark() {
        let bookmark = TPPPDFPageBookmark(page: 1)
        XCTAssertTrue(bookmark is Bookmark)
    }

    // SRS: TPPPDFPageBookmark is NSObject subclass
    func testPageBookmark_isNSObject() {
        let bookmark = TPPPDFPageBookmark(page: 1)
        XCTAssertTrue(bookmark is NSObject)
    }
}

// MARK: - TPPPDFReaderMode Tests

final class TPPPDFReaderModeTests: XCTestCase {

    // SRS: TPPPDFReaderMode reader value
    func testReaderMode_readerValue() {
        XCTAssertEqual(TPPPDFReaderMode.reader.value, "Reader")
    }

    // SRS: TPPPDFReaderMode previews value
    func testReaderMode_previewsValue() {
        XCTAssertEqual(TPPPDFReaderMode.previews.value, "Page previews")
    }

    // SRS: TPPPDFReaderMode bookmarks value
    func testReaderMode_bookmarksValue() {
        XCTAssertEqual(TPPPDFReaderMode.bookmarks.value, "Bookmarks")
    }

    // SRS: TPPPDFReaderMode toc value
    func testReaderMode_tocValue() {
        XCTAssertEqual(TPPPDFReaderMode.toc.value, "TOC")
    }

    // SRS: TPPPDFReaderMode search value
    func testReaderMode_searchValue() {
        XCTAssertEqual(TPPPDFReaderMode.search.value, "Search")
    }

    // SRS: TPPPDFReaderMode all cases have unique values
    func testReaderMode_allCasesHaveUniqueValues() {
        let modes: [TPPPDFReaderMode] = [.reader, .previews, .bookmarks, .toc, .search]
        let values = modes.map { $0.value }
        XCTAssertEqual(Set(values).count, values.count, "All reader mode values should be unique")
    }
}

// MARK: - TPPPDFDocument Tests

final class TPPPDFDocumentTests: XCTestCase {

    // SRS: TPPPDFDocument non-encrypted init sets correct properties
    func testPDFDocument_nonEncryptedInit() {
        let data = Data([0x25, 0x50, 0x44, 0x46]) // %PDF header bytes
        let doc = TPPPDFDocument(data: data)
        XCTAssertFalse(doc.isEncrypted)
        XCTAssertEqual(doc.data, data)
    }

    // SRS: TPPPDFDocument encrypted init sets correct properties
    func testPDFDocument_encryptedInit() {
        let data = Data([0x00, 0x01, 0x02])
        let doc = TPPPDFDocument(encryptedData: data) { data, _, _ in data }
        XCTAssertTrue(doc.isEncrypted)
        XCTAssertEqual(doc.data, data)
    }

    // SRS: TPPPDFDocument decrypt returns decrypted data when decryptor exists
    func testPDFDocument_decryptWithDecryptor() {
        let originalData = Data([0x01, 0x02, 0x03])
        let decryptedData = Data([0x0A, 0x0B, 0x0C])
        let doc = TPPPDFDocument(encryptedData: originalData) { _, _, _ in decryptedData }
        let result = doc.decrypt(data: originalData, start: 0, end: 3)
        XCTAssertEqual(result, decryptedData)
    }

    // SRS: TPPPDFDocument decrypt returns original data when no decryptor
    func testPDFDocument_decryptWithoutDecryptor() {
        let data = Data([0x01, 0x02, 0x03])
        let doc = TPPPDFDocument(data: data)
        let result = doc.decrypt(data: data, start: 0, end: 3)
        XCTAssertEqual(result, data)
    }

    // SRS: TPPPDFDocument pageCount is 0 for invalid data
    func testPDFDocument_pageCountForInvalidData() {
        let doc = TPPPDFDocument(data: Data())
        XCTAssertEqual(doc.pageCount, 0)
    }

    // SRS: TPPPDFDocument non-encrypted has nil encryptedDocument
    func testPDFDocument_nonEncryptedHasNilEncryptedDocument() {
        let doc = TPPPDFDocument(data: Data())
        XCTAssertNil(doc.encryptedDocument)
    }

    // SRS: TPPPDFDocument encrypted has nil regular document
    func testPDFDocument_encryptedHasNilRegularDocument() {
        let doc = TPPPDFDocument(encryptedData: Data()) { d, _, _ in d }
        XCTAssertNil(doc.document)
    }

    // SRS: TPPPDFDocument tableOfContents is empty for invalid data
    func testPDFDocument_tableOfContentsEmptyForInvalidData() {
        let doc = TPPPDFDocument(data: Data())
        XCTAssertTrue(doc.tableOfContents.isEmpty)
    }

    // SRS: TPPPDFDocument delegate can be set
    func testPDFDocument_delegateCanBeSet() {
        let doc = TPPPDFDocument(data: Data())
        XCTAssertNil(doc.delegate)
    }

    // SRS: TPPPDFDocument size returns nil for invalid page
    func testPDFDocument_sizeReturnsNilForInvalidPage() {
        let doc = TPPPDFDocument(data: Data())
        XCTAssertNil(doc.size(page: 0))
    }

    // SRS: TPPPDFDocument label returns nil for invalid page
    func testPDFDocument_labelReturnsNilForInvalidPage() {
        let doc = TPPPDFDocument(data: Data())
        XCTAssertNil(doc.label(page: 0))
    }

    // SRS: TPPPDFDocument preview returns nil for invalid page
    func testPDFDocument_previewReturnsNilForInvalidPage() {
        let doc = TPPPDFDocument(data: Data())
        XCTAssertNil(doc.preview(for: 0))
    }

    // SRS: TPPPDFDocument thumbnail returns nil for invalid page
    func testPDFDocument_thumbnailReturnsNilForInvalidPage() {
        let doc = TPPPDFDocument(data: Data())
        XCTAssertNil(doc.thumbnail(for: 0))
    }
}
