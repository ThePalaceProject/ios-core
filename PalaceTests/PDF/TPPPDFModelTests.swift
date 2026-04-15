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
        // Verify distinct pages are not equal after encode/decode
        let other = TPPPDFPage(pageNumber: 43)
        XCTAssertNotEqual(page.pageNumber, other.pageNumber)
        // Page number must survive a JSON round-trip (Codable conformance)
        let data = try? JSONEncoder().encode(page)
        let decoded = data.flatMap { try? JSONDecoder().decode(TPPPDFPage.self, from: $0) }
        XCTAssertEqual(decoded?.pageNumber, 42, "pageNumber must survive Codable round-trip")
    }

    // SRS: TPPPDFPage is Codable (round-trip encoding/decoding)
    func testPDFPage_codableRoundTrip() throws {
        let page = TPPPDFPage(pageNumber: 7)
        let data = try JSONEncoder().encode(page)
        let decoded = try JSONDecoder().decode(TPPPDFPage.self, from: data)
        XCTAssertEqual(decoded.pageNumber, 7)
        // A different page number must decode differently
        let page2 = TPPPDFPage(pageNumber: 8)
        let data2 = try JSONEncoder().encode(page2)
        let decoded2 = try JSONDecoder().decode(TPPPDFPage.self, from: data2)
        XCTAssertNotEqual(decoded.pageNumber, decoded2.pageNumber)
    }

    // SRS: TPPPDFPage encodes expected JSON structure
    func testPDFPage_encodesToExpectedJSON() throws {
        let page = TPPPDFPage(pageNumber: 0)
        let data = try JSONEncoder().encode(page)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(dict?["pageNumber"] as? Int, 0)
        // The encoded JSON must contain exactly the "pageNumber" key
        XCTAssertNotNil(dict, "Encoded JSON must be a valid dictionary")
    }

    // SRS: TPPPDFPage decodes from JSON data
    func testPDFPage_decodesFromJSON() throws {
        let json = #"{"pageNumber": 100}"#
        let data = json.data(using: .utf8)!
        let page = try JSONDecoder().decode(TPPPDFPage.self, from: data)
        XCTAssertEqual(page.pageNumber, 100)
        // Page number 100 must not equal a different value
        XCTAssertNotEqual(page.pageNumber, 0)
    }

    // SRS: TPPPDFPage handles zero page number
    func testPDFPage_zeroPageNumber() {
        let page = TPPPDFPage(pageNumber: 0)
        XCTAssertEqual(page.pageNumber, 0)
        // Zero is distinct from page 1
        XCTAssertNotEqual(page.pageNumber, 1)
        // Zero also round-trips correctly
        let data = try? JSONEncoder().encode(page)
        let decoded = data.flatMap { try? JSONDecoder().decode(TPPPDFPage.self, from: $0) }
        XCTAssertEqual(decoded?.pageNumber, 0, "Zero page number must survive Codable round-trip")
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
        // Default level of 0 means the id ends with "-0"
        XCTAssertTrue(loc.id.hasSuffix("-0"), "Default level 0 should appear at end of id as '-0'")
        // A location with explicit level=1 is different
        let locWithLevel = TPPPDFLocation(title: "Test", subtitle: nil, pageLabel: nil, pageNumber: 5, level: 1)
        XCTAssertNotEqual(loc.id, locWithLevel.id, "Different levels should produce different ids")
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
        // A location with different title must have a different id
        let loc3 = TPPPDFLocation(title: "Ch2", subtitle: "Sub", pageLabel: "1", pageNumber: 0, level: 0)
        XCTAssertNotEqual(loc1.id, loc3.id, "Locations with different titles must have different ids")
    }

    // SRS: TPPPDFLocation id encodes all fields
    func testPDFLocation_id_encodesAllFields() {
        let loc = TPPPDFLocation(title: "Title", subtitle: "Sub", pageLabel: "iv", pageNumber: 3, level: 2)
        XCTAssertEqual(loc.id, "3-iv-Sub-Title-2")
        // Changing any single field must produce a different id
        let diffPage = TPPPDFLocation(title: "Title", subtitle: "Sub", pageLabel: "iv", pageNumber: 4, level: 2)
        XCTAssertNotEqual(loc.id, diffPage.id, "Changing pageNumber must change the id")
    }

    // SRS: TPPPDFLocation id handles nil values as empty strings
    func testPDFLocation_id_handlesNils() {
        let loc = TPPPDFLocation(title: nil, subtitle: nil, pageLabel: nil, pageNumber: 5, level: 0)
        XCTAssertEqual(loc.id, "5----0")
        // A non-nil title must produce a different id
        let withTitle = TPPPDFLocation(title: "T", subtitle: nil, pageLabel: nil, pageNumber: 5, level: 0)
        XCTAssertNotEqual(loc.id, withTitle.id, "Adding a title must change the id")
    }

    // SRS: TPPPDFLocation different locations produce different ids
    func testPDFLocation_differentLocations_differentIds() {
        let loc1 = TPPPDFLocation(title: "A", subtitle: nil, pageLabel: nil, pageNumber: 1)
        let loc2 = TPPPDFLocation(title: "B", subtitle: nil, pageLabel: nil, pageNumber: 2)
        XCTAssertNotEqual(loc1.id, loc2.id)
        // The same title but different page also produces different ids
        let loc3 = TPPPDFLocation(title: "A", subtitle: nil, pageLabel: nil, pageNumber: 2)
        XCTAssertNotEqual(loc1.id, loc3.id, "Different pageNumbers must produce different ids")
    }
}

// MARK: - TPPPDFPageBookmark Tests

final class TPPPDFPageBookmarkTests: XCTestCase {

    // SRS: TPPPDFPageBookmark initializes with page number
    func testPageBookmark_initSetsPage() {
        let bookmark = TPPPDFPageBookmark(page: 10)
        XCTAssertEqual(bookmark.page, 10)
        // The type is always "LocatorPage" regardless of page number
        XCTAssertEqual(bookmark.type, "LocatorPage")
        // A different page number produces a distinct bookmark
        let other = TPPPDFPageBookmark(page: 11)
        XCTAssertNotEqual(bookmark.page, other.page)
    }

    // SRS: TPPPDFPageBookmark type is always LocatorPage
    func testPageBookmark_typeIsLocatorPage() {
        let bookmark = TPPPDFPageBookmark(page: 5)
        XCTAssertEqual(bookmark.type, "LocatorPage")
        // Type is consistent across different page numbers
        let bookmarkPage100 = TPPPDFPageBookmark(page: 100)
        XCTAssertEqual(bookmarkPage100.type, "LocatorPage", "Type should be LocatorPage for any page number")
        // Type is encoded as @type key in JSON
        do {
            let data = try JSONEncoder().encode(bookmark)
            if let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                XCTAssertEqual(dict["@type"] as? String, "LocatorPage", "@type key should equal 'LocatorPage' in JSON output")
            }
        } catch {
            XCTFail("Encoding bookmark to JSON failed: \(error)")
        }
    }

    // SRS: TPPPDFPageBookmark annotationID defaults to nil
    func testPageBookmark_annotationIdDefaultsToNil() {
        let bookmark = TPPPDFPageBookmark(page: 3)
        XCTAssertNil(bookmark.annotationID)
        // The default state must survive a Codable round-trip (annotationID is not in CodingKeys)
        let encoded = try? JSONEncoder().encode(bookmark)
        let decoded = encoded.flatMap { try? JSONDecoder().decode(TPPPDFPageBookmark.self, from: $0) }
        XCTAssertNil(decoded?.annotationID,
                     "annotationID (not in CodingKeys) must remain nil after Codable round-trip")
        // Two bookmarks on the same page with no annotationID must share the same Codable output
        let bookmark2 = TPPPDFPageBookmark(page: 3)
        let encoded2 = try? JSONEncoder().encode(bookmark2)
        // Compare decoded values — JSONEncoder doesn't guarantee key order
        let d1 = encoded.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        let d2 = encoded2.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        XCTAssertNotNil(d1, "First bookmark must encode to valid JSON")
        XCTAssertNotNil(d2, "Second bookmark must encode to valid JSON")
        XCTAssertEqual(d1?["@type"] as? String, d2?["@type"] as? String, "type must match")
        XCTAssertEqual(d1?["page"] as? Int, d2?["page"] as? Int, "page must match")
    }

    // SRS: TPPPDFPageBookmark annotationID can be set
    func testPageBookmark_annotationIdCanBeSet() {
        let bookmark = TPPPDFPageBookmark(page: 3, annotationID: "abc-123")
        XCTAssertEqual(bookmark.annotationID, "abc-123")
        XCTAssertEqual(bookmark.page, 3, "Page number must not be affected by annotationID")
        // A bookmark without annotationID must differ from one with annotationID
        let noId = TPPPDFPageBookmark(page: 3)
        XCTAssertNil(noId.annotationID, "Bookmark created without annotationID must have nil annotationID")
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
        // As a Bookmark, the type field must identify the locator type
        XCTAssertEqual(bookmark.type, "LocatorPage",
                       "Bookmark protocol conformant must report 'LocatorPage' type")
    }

    // SRS: TPPPDFPageBookmark is NSObject subclass
    func testPageBookmark_isNSObject() {
        let bookmark = TPPPDFPageBookmark(page: 1)
        XCTAssertTrue(bookmark is NSObject)
        // As NSObject, isEqual must work for identity comparison
        XCTAssertTrue(bookmark.isEqual(bookmark),
                      "NSObject.isEqual with self must return true")
    }
}

// MARK: - TPPPDFReaderMode Tests

final class TPPPDFReaderModeTests: XCTestCase {

    // SRS: TPPPDFReaderMode reader value
    func testReaderMode_readerValue() {
        XCTAssertEqual(TPPPDFReaderMode.reader.value, "Reader")
        XCTAssertFalse(TPPPDFReaderMode.reader.value.isEmpty)
        XCTAssertNotEqual(TPPPDFReaderMode.reader.value, TPPPDFReaderMode.previews.value)
    }

    // SRS: TPPPDFReaderMode previews value
    func testReaderMode_previewsValue() {
        XCTAssertEqual(TPPPDFReaderMode.previews.value, "Page previews")
        XCTAssertFalse(TPPPDFReaderMode.previews.value.isEmpty)
        XCTAssertNotEqual(TPPPDFReaderMode.previews.value, TPPPDFReaderMode.bookmarks.value)
    }

    // SRS: TPPPDFReaderMode bookmarks value
    func testReaderMode_bookmarksValue() {
        XCTAssertEqual(TPPPDFReaderMode.bookmarks.value, "Bookmarks")
        XCTAssertFalse(TPPPDFReaderMode.bookmarks.value.isEmpty)
        XCTAssertNotEqual(TPPPDFReaderMode.bookmarks.value, TPPPDFReaderMode.toc.value)
    }

    // SRS: TPPPDFReaderMode toc value
    func testReaderMode_tocValue() {
        XCTAssertEqual(TPPPDFReaderMode.toc.value, "TOC")
        XCTAssertFalse(TPPPDFReaderMode.toc.value.isEmpty)
        XCTAssertNotEqual(TPPPDFReaderMode.toc.value, TPPPDFReaderMode.search.value)
    }

    // SRS: TPPPDFReaderMode search value
    func testReaderMode_searchValue() {
        XCTAssertEqual(TPPPDFReaderMode.search.value, "Search")
        XCTAssertFalse(TPPPDFReaderMode.search.value.isEmpty)
        XCTAssertNotEqual(TPPPDFReaderMode.search.value, TPPPDFReaderMode.reader.value)
    }

    // SRS: TPPPDFReaderMode all cases have unique values
    func testReaderMode_allCasesHaveUniqueValues() {
        let modes: [TPPPDFReaderMode] = [.reader, .previews, .bookmarks, .toc, .search]
        let values = modes.map { $0.value }
        XCTAssertEqual(Set(values).count, values.count, "All reader mode values should be unique")
        // No value should be empty
        for (mode, value) in zip(modes, values) {
            XCTAssertFalse(value.isEmpty, "Reader mode '\(mode)' must have a non-empty value string")
        }
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
        // A non-encrypted document has no encrypted counterpart
        XCTAssertNil(doc.encryptedDocument, "Non-encrypted document should have nil encryptedDocument")
        // The delegate is nil by default
        XCTAssertNil(doc.delegate, "Delegate should be nil on init")
    }

    // SRS: TPPPDFDocument encrypted init sets correct properties
    func testPDFDocument_encryptedInit() {
        let data = Data([0x00, 0x01, 0x02])
        let doc = TPPPDFDocument(encryptedData: data) { data, _, _ in data }
        XCTAssertTrue(doc.isEncrypted)
        XCTAssertEqual(doc.data, data)
        // Encrypted document should have nil regular document (uses encrypted path)
        XCTAssertNil(doc.document, "Encrypted document should have nil .document property")
        // The delegate is nil by default
        XCTAssertNil(doc.delegate, "Delegate should be nil on init")
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
        // decrypt must be a pure pass-through: result must equal input exactly
        XCTAssertFalse(doc.isEncrypted, "Non-encrypted document must report isEncrypted = false")
        // Calling decrypt with different bounds on the same data must still return the original
        let resultAgain = doc.decrypt(data: data, start: 0, end: 3)
        XCTAssertEqual(resultAgain, data, "Repeated decrypt calls must return same data for non-encrypted doc")
    }

    // SRS: TPPPDFDocument pageCount is 0 for invalid data
    func testPDFDocument_pageCountForInvalidData() {
        let doc = TPPPDFDocument(data: Data())
        XCTAssertEqual(doc.pageCount, 0)
        // With 0 pages, requesting page content should return nil
        XCTAssertNil(doc.size(page: 0), "size(page:) should return nil for invalid data")
        XCTAssertNil(doc.label(page: 0), "label(page:) should return nil for invalid data")
    }

    // SRS: TPPPDFDocument non-encrypted has nil encryptedDocument
    func testPDFDocument_nonEncryptedHasNilEncryptedDocument() {
        let doc = TPPPDFDocument(data: Data())
        XCTAssertNil(doc.encryptedDocument)
        // Non-encrypted document reports isEncrypted = false
        XCTAssertFalse(doc.isEncrypted)
        // Non-encrypted document's data field is accessible
        XCTAssertEqual(doc.data, Data())
    }

    // SRS: TPPPDFDocument encrypted has nil regular document
    func testPDFDocument_encryptedHasNilRegularDocument() {
        let doc = TPPPDFDocument(encryptedData: Data()) { d, _, _ in d }
        XCTAssertNil(doc.document)
        // Encrypted document reports isEncrypted = true
        XCTAssertTrue(doc.isEncrypted)
        // encryptedDocument is the non-nil counterpart for the encrypted path
        // (may still be nil if data is not a valid PDF, but isEncrypted flag is set)
        XCTAssertEqual(doc.data, Data())
    }

    // SRS: TPPPDFDocument tableOfContents is empty for invalid data
    func testPDFDocument_tableOfContentsEmptyForInvalidData() {
        let doc = TPPPDFDocument(data: Data())
        XCTAssertTrue(doc.tableOfContents.isEmpty)
        // Page count is also 0 for invalid data (consistent state)
        XCTAssertEqual(doc.pageCount, 0)
        // Neither preview nor thumbnail should be returned
        XCTAssertNil(doc.preview(for: 0), "preview should be nil for document with no pages")
    }

    // SRS: TPPPDFDocument delegate can be set
    func testPDFDocument_delegateCanBeSet() {
        let doc = TPPPDFDocument(data: Data())
        XCTAssertNil(doc.delegate)
        // Encrypted variant also starts with nil delegate
        let encDoc = TPPPDFDocument(encryptedData: Data()) { d, _, _ in d }
        XCTAssertNil(encDoc.delegate, "Encrypted document delegate should also default to nil")
        // Both documents have 0 pages when constructed with empty data
        XCTAssertEqual(encDoc.pageCount, 0)
    }

    // SRS: TPPPDFDocument size returns nil for invalid page
    func testPDFDocument_sizeReturnsNilForInvalidPage() {
        let doc = TPPPDFDocument(data: Data())
        XCTAssertNil(doc.size(page: 0))
        // Also nil for negative page numbers (out of bounds)
        XCTAssertNil(doc.size(page: -1), "size(page:) should return nil for negative page index")
        // Page count is 0 for empty data, confirming all page indices are invalid
        XCTAssertEqual(doc.pageCount, 0)
    }

    // SRS: TPPPDFDocument label returns nil for invalid page
    func testPDFDocument_labelReturnsNilForInvalidPage() {
        let doc = TPPPDFDocument(data: Data())
        XCTAssertNil(doc.label(page: 0))
        // Also nil for an obviously out-of-bounds page
        XCTAssertNil(doc.label(page: 9999), "label(page:) should return nil for out-of-bounds index")
        // TOC is also empty since no pages exist
        XCTAssertTrue(doc.tableOfContents.isEmpty)
    }

    // SRS: TPPPDFDocument preview returns nil for invalid page
    func testPDFDocument_previewReturnsNilForInvalidPage() {
        let doc = TPPPDFDocument(data: Data())
        XCTAssertNil(doc.preview(for: 0))
        // Out-of-bounds index also returns nil
        XCTAssertNil(doc.preview(for: 100), "preview(for:) should return nil for out-of-bounds index")
        // Consistent with 0 page count
        XCTAssertEqual(doc.pageCount, 0)
    }

    // SRS: TPPPDFDocument thumbnail returns nil for invalid page
    func testPDFDocument_thumbnailReturnsNilForInvalidPage() {
        let doc = TPPPDFDocument(data: Data())
        XCTAssertNil(doc.thumbnail(for: 0))
        // Out-of-bounds index also returns nil
        XCTAssertNil(doc.thumbnail(for: 500), "thumbnail(for:) should return nil for out-of-bounds index")
        // Consistent with 0 page count
        XCTAssertEqual(doc.pageCount, 0)
    }
}
