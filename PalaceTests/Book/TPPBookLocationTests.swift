//
//  TPPBookLocationTests.swift
//  PalaceTests
//
//  Tests for TPPBookLocation, TPPBookLocationKey, TPPBookContentTypeConverter,
//  TPPBookAuthor, and TPPProblemDocument.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

// MARK: - TPPBookLocation Tests

final class TPPBookLocationTests: XCTestCase {

    // SRS: TPPBookLocation init with valid strings succeeds
    func testBookLocation_initWithStrings() {
        let loc = TPPBookLocation(locationString: "page:42", renderer: "Readium")
        XCTAssertNotNil(loc)
        XCTAssertEqual(loc?.locationString, "page:42")
        XCTAssertEqual(loc?.renderer, "Readium")
    }

    // SRS: TPPBookLocation init with dictionary succeeds
    func testBookLocation_initWithDictionary() {
        let dict: [String: Any] = [
            "locationString": "chapter3",
            "renderer": "R2"
        ]
        let loc = TPPBookLocation(dictionary: dict)
        XCTAssertNotNil(loc)
        XCTAssertEqual(loc?.locationString, "chapter3")
        XCTAssertEqual(loc?.renderer, "R2")
    }

    // SRS: TPPBookLocation init with incomplete dictionary fails
    func testBookLocation_initWithIncompleteDictionary() {
        let dict: [String: Any] = ["locationString": "page:1"]
        let loc = TPPBookLocation(dictionary: dict)
        XCTAssertNil(loc, "Missing renderer should cause init to fail")
    }

    // SRS: TPPBookLocation init with empty dictionary fails
    func testBookLocation_initWithEmptyDictionary() {
        let loc = TPPBookLocation(dictionary: [:])
        XCTAssertNil(loc)
    }

    // SRS: TPPBookLocation dictionaryRepresentation round-trips
    func testBookLocation_dictionaryRoundTrip() {
        let loc = TPPBookLocation(locationString: "loc:data", renderer: "TestRenderer")!
        let dict = loc.dictionaryRepresentation
        let restored = TPPBookLocation(dictionary: dict)
        XCTAssertEqual(restored?.locationString, "loc:data")
        XCTAssertEqual(restored?.renderer, "TestRenderer")
    }

    // SRS: TPPBookLocation locationString is mutable
    func testBookLocation_locationStringIsMutable() {
        let loc = TPPBookLocation(locationString: "old", renderer: "R")!
        loc.locationString = "new"
        XCTAssertEqual(loc.locationString, "new")
    }

    // SRS: TPPBookLocation renderer is mutable
    func testBookLocation_rendererIsMutable() {
        let loc = TPPBookLocation(locationString: "s", renderer: "old")!
        loc.renderer = "new"
        XCTAssertEqual(loc.renderer, "new")
    }
}

// MARK: - TPPBookLocationKey Tests

final class TPPBookLocationKeyTests: XCTestCase {

    // SRS: TPPBookLocationKey raw values
    func testBookLocationKey_rawValues() {
        XCTAssertEqual(TPPBookLocationKey.locationString.rawValue, "locationString")
        XCTAssertEqual(TPPBookLocationKey.renderer.rawValue, "renderer")
    }

    // SRS: TPPBookLocationData string accessor works
    func testBookLocationData_stringAccessor() {
        let data: TPPBookLocationData = [
            "locationString": "test-value",
            "renderer": "R2"
        ]
        XCTAssertEqual(data.string(for: .locationString), "test-value")
        XCTAssertEqual(data.string(for: .renderer), "R2")
    }

    // SRS: TPPBookLocationData string accessor returns nil for wrong type
    func testBookLocationData_stringAccessorWrongType() {
        let data: TPPBookLocationData = ["locationString": 42]
        XCTAssertNil(data.string(for: .locationString))
    }
}

// MARK: - TPPBookContentTypeConverter Tests

final class TPPBookContentTypeConverterTests: XCTestCase {

    // SRS: TPPBookContentTypeConverter epub string
    func testStringValue_epub() {
        XCTAssertEqual(TPPBookContentTypeConverter.stringValue(of: .epub), "Epub")
    }

    // SRS: TPPBookContentTypeConverter audiobook string
    func testStringValue_audiobook() {
        XCTAssertEqual(TPPBookContentTypeConverter.stringValue(of: .audiobook), "AudioBook")
    }

    // SRS: TPPBookContentTypeConverter pdf string
    func testStringValue_pdf() {
        XCTAssertEqual(TPPBookContentTypeConverter.stringValue(of: .pdf), "PDF")
    }

    // SRS: TPPBookContentTypeConverter unsupported string
    func testStringValue_unsupported() {
        XCTAssertEqual(TPPBookContentTypeConverter.stringValue(of: .unsupported), "Unsupported")
    }
}

// MARK: - TPPBookAuthor Tests

final class TPPBookAuthorTests: XCTestCase {

    // SRS: TPPBookAuthor initializes with name and URL
    func testBookAuthor_initWithNameAndURL() {
        let url = URL(string: "https://example.com/books")!
        let author = TPPBookAuthor(authorName: "Jane Doe", relatedBooksURL: url)
        XCTAssertEqual(author.name, "Jane Doe")
        XCTAssertEqual(author.relatedBooksURL, url)
    }

    // SRS: TPPBookAuthor initializes with nil URL
    func testBookAuthor_initWithNilURL() {
        let author = TPPBookAuthor(authorName: "John Smith", relatedBooksURL: nil)
        XCTAssertEqual(author.name, "John Smith")
        XCTAssertNil(author.relatedBooksURL)
    }

    // SRS: TPPBookAuthor is NSObject subclass
    func testBookAuthor_isNSObject() {
        let author = TPPBookAuthor(authorName: "Test", relatedBooksURL: nil)
        XCTAssertTrue(author is NSObject)
    }
}

// MARK: - TPPProblemDocument Tests

final class TPPProblemDocumentTests: XCTestCase {

    // SRS: TPPProblemDocument fromData decodes valid JSON
    func testFromData_validJSON() throws {
        let json = """
        {
            "type": "http://example.com/problem",
            "title": "Not Found",
            "status": 404,
            "detail": "The resource was not found.",
            "instance": "urn:uuid:12345"
        }
        """
        let doc = try TPPProblemDocument.fromData(json.data(using: .utf8)!)
        XCTAssertEqual(doc.type, "http://example.com/problem")
        XCTAssertEqual(doc.title, "Not Found")
        XCTAssertEqual(doc.status, 404)
        XCTAssertEqual(doc.detail, "The resource was not found.")
        XCTAssertEqual(doc.instance, "urn:uuid:12345")
    }

    // SRS: TPPProblemDocument fromData throws for invalid JSON
    func testFromData_invalidJSON() {
        let data = "not json".data(using: .utf8)!
        XCTAssertThrowsError(try TPPProblemDocument.fromData(data))
    }

    // SRS: TPPProblemDocument fromDictionary creates document
    func testFromDictionary_createsDocument() {
        let doc = TPPProblemDocument.fromDictionary([
            "type": "test-type",
            "title": "Test Title",
            "status": 500,
            "detail": "Test detail"
        ])
        XCTAssertEqual(doc.type, "test-type")
        XCTAssertEqual(doc.title, "Test Title")
        XCTAssertEqual(doc.status, 500)
        XCTAssertEqual(doc.detail, "Test detail")
    }

    // SRS: TPPProblemDocument dictionaryValue round trips
    func testDictionaryValue_roundTrip() {
        let doc = TPPProblemDocument.fromDictionary([
            "type": "t",
            "title": "T",
            "status": 200,
            "detail": "D",
            "instance": "I"
        ])
        let dict = doc.dictionaryValue
        XCTAssertEqual(dict["type"] as? String, "t")
        XCTAssertEqual(dict["title"] as? String, "T")
        XCTAssertEqual(dict["status"] as? Int, 200)
        XCTAssertEqual(dict["detail"] as? String, "D")
        XCTAssertEqual(dict["instance"] as? String, "I")
    }

    // SRS: TPPProblemDocument stringValue formats correctly
    func testStringValue_format() {
        let doc = TPPProblemDocument.fromDictionary([
            "title": "Error",
            "detail": "Something went wrong"
        ])
        XCTAssertEqual(doc.stringValue, "Error: Something went wrong")
    }

    // SRS: TPPProblemDocument stringValue without title
    func testStringValue_noTitle() {
        let doc = TPPProblemDocument.fromDictionary([
            "detail": "Detail only"
        ])
        XCTAssertEqual(doc.stringValue, "Detail only")
    }

    // SRS: TPPProblemDocument stringValue without detail
    func testStringValue_noDetail() {
        let doc = TPPProblemDocument.fromDictionary([
            "title": "Title only"
        ])
        XCTAssertEqual(doc.stringValue, "Title only: ")
    }

    // SRS: TPPProblemDocument static type constants exist
    func testStaticTypeConstants() {
        XCTAssertFalse(TPPProblemDocument.TypeNoActiveLoan.isEmpty)
        XCTAssertFalse(TPPProblemDocument.TypeLoanAlreadyExists.isEmpty)
        XCTAssertFalse(TPPProblemDocument.TypeInvalidCredentials.isEmpty)
        XCTAssertFalse(TPPProblemDocument.TypeCannotFulfillLoan.isEmpty)
        XCTAssertFalse(TPPProblemDocument.TypeCannotIssueLoan.isEmpty)
        XCTAssertFalse(TPPProblemDocument.TypeCannotRender.isEmpty)
    }

    // SRS: TPPProblemDocument account status type constants
    func testAccountStatusTypeConstants() {
        XCTAssertTrue(TPPProblemDocument.TypeCredentialsSuspended.contains("suspended"))
        XCTAssertTrue(TPPProblemDocument.TypePatronLoanLimit.contains("loan-limit"))
        XCTAssertTrue(TPPProblemDocument.TypePatronHoldLimit.contains("hold-limit"))
    }

    // SRS: TPPProblemDocument isRecoverableAuthError
    func testIsRecoverableAuthError() {
        let doc = TPPProblemDocument.fromDictionary([
            "type": "http://palaceproject.io/terms/problem/auth/recoverable/token-expired"
        ])
        XCTAssertTrue(doc.isRecoverableAuthError)
        XCTAssertFalse(doc.isUnrecoverableAuthError)
    }

    // SRS: TPPProblemDocument isUnrecoverableAuthError
    func testIsUnrecoverableAuthError() {
        let doc = TPPProblemDocument.fromDictionary([
            "type": "http://palaceproject.io/terms/problem/auth/unrecoverable/invalid-credentials"
        ])
        XCTAssertFalse(doc.isRecoverableAuthError)
        XCTAssertTrue(doc.isUnrecoverableAuthError)
    }

    // SRS: TPPProblemDocument non-auth error returns false for both
    func testNonAuthError() {
        let doc = TPPProblemDocument.fromDictionary([
            "type": "http://example.com/generic-error"
        ])
        XCTAssertFalse(doc.isRecoverableAuthError)
        XCTAssertFalse(doc.isUnrecoverableAuthError)
    }

    // SRS: TPPProblemDocument nil type returns false for auth checks
    func testNilType_authChecks() {
        let doc = TPPProblemDocument.fromDictionary([:])
        XCTAssertFalse(doc.isRecoverableAuthError)
        XCTAssertFalse(doc.isUnrecoverableAuthError)
    }

    // SRS: TPPProblemDocument forExpiredOrMissingCredentials with credentials
    func testForExpiredOrMissing_hasCredentials() {
        let doc = TPPProblemDocument.forExpiredOrMissingCredentials(hasCredentials: true)
        XCTAssertEqual(doc.type, TPPProblemDocument.TypeInvalidCredentials)
        XCTAssertNotNil(doc.title)
        XCTAssertNotNil(doc.detail)
    }

    // SRS: TPPProblemDocument forExpiredOrMissingCredentials without credentials
    func testForExpiredOrMissing_noCredentials() {
        let doc = TPPProblemDocument.forExpiredOrMissingCredentials(hasCredentials: false)
        XCTAssertEqual(doc.type, TPPProblemDocument.TypeInvalidCredentials)
        XCTAssertNotNil(doc.title)
        XCTAssertNotNil(doc.detail)
    }

    // SRS: TPPProblemDocument fromProblemResponseData with valid data
    func testFromProblemResponseData_validData() {
        let json = """
        {"type": "test", "title": "Error", "detail": "Details here"}
        """
        let doc = TPPProblemDocument.fromProblemResponseData(json.data(using: .utf8)!)
        XCTAssertNotNil(doc)
        XCTAssertEqual(doc?.title, "Error")
    }

    // SRS: TPPProblemDocument fromProblemResponseData with message fallback
    func testFromProblemResponseData_messageFallback() {
        let json = """
        {"message": "Server error occurred"}
        """
        let doc = TPPProblemDocument.fromProblemResponseData(json.data(using: .utf8)!)
        XCTAssertNotNil(doc)
        XCTAssertEqual(doc?.detail, "Server error occurred")
    }

    // SRS: TPPProblemDocument fromProblemResponseData with invalid data
    func testFromProblemResponseData_invalidData() {
        let doc = TPPProblemDocument.fromProblemResponseData("not json".data(using: .utf8)!)
        XCTAssertNil(doc)
    }

    // SRS: TPPProblemDocument fromResponseError with problemDoc in error
    func testFromResponseError_nilErrorNilData() {
        let doc = TPPProblemDocument.fromResponseError(nil, responseData: nil)
        XCTAssertNil(doc)
    }

    // SRS: TPPProblemDocument fromResponseError with response data
    func testFromResponseError_withResponseData() {
        let json = """
        {"type": "test", "title": "Test", "detail": "Test detail"}
        """
        let doc = TPPProblemDocument.fromResponseError(nil, responseData: json.data(using: .utf8)!)
        XCTAssertNotNil(doc)
        XCTAssertEqual(doc?.title, "Test")
    }

    // SRS: TPPProblemDocument Codable encoding/decoding
    func testCodableRoundTrip() throws {
        let json = """
        {"type": "t", "title": "T", "status": 200, "detail": "D"}
        """
        let original = try TPPProblemDocument.fromData(json.data(using: .utf8)!)
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TPPProblemDocument.self, from: encoded)
        XCTAssertEqual(decoded.type, "t")
        XCTAssertEqual(decoded.title, "T")
        XCTAssertEqual(decoded.status, 200)
        XCTAssertEqual(decoded.detail, "D")
    }
}
