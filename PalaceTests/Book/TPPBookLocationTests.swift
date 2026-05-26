//
//  TPPBookLocationTests.swift
//  PalaceTests
//
//  Tests for TPPBookLocation, TPPBookLocationKey, TPPBookContentTypeConverter,
//  TPPBookAuthor, TPPProblemDocument, and edge cases including isSimilarTo
//  comparison logic and TPPBookLocationData extension.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceCatalog
@testable import Palace

// MARK: - TPPBookLocation Tests

final class TPPBookLocationCoverageTests: XCTestCase {

    // SRS: TPPBookLocation init with valid strings succeeds
    func testBookLocation_initWithStrings() {
        let loc = TPPBookLocation(locationString: "page:42", renderer: "Readium")
        XCTAssertEqual(loc?.locationString, "page:42")
        XCTAssertEqual(loc?.renderer, "Readium")
        // Verify the dictionary representation captures both fields
        XCTAssertEqual(loc?.dictionaryRepresentation["locationString"] as? String, "page:42")
        XCTAssertEqual(loc?.dictionaryRepresentation["renderer"] as? String, "Readium")
    }

    // SRS: TPPBookLocation init with dictionary succeeds
    func testBookLocation_initWithDictionary() {
        let dict: [String: Any] = [
            "locationString": "chapter3",
            "renderer": "R2"
        ]
        let loc = TPPBookLocation(dictionary: dict)
        XCTAssertEqual(loc?.locationString, "chapter3")
        XCTAssertEqual(loc?.renderer, "R2")
        // Round-trip: the reconstructed dictionary should match the input
        XCTAssertEqual(loc?.dictionaryRepresentation.count, 2)
    }

    // SRS: TPPBookLocation init with incomplete dictionary fails
    func testBookLocation_initWithIncompleteDictionary() {
        let dict: [String: Any] = ["locationString": "page:1"]
        let loc = TPPBookLocation(dictionary: dict)
        XCTAssertNil(loc, "Missing renderer should cause init to fail")
        // Flipped: missing locationString also fails
        let dictMissingLS: [String: Any] = ["renderer": "readium"]
        XCTAssertNil(TPPBookLocation(dictionary: dictMissingLS), "Missing locationString should also fail")
        // Both keys present → must succeed
        let complete: [String: Any] = ["locationString": "page:1", "renderer": "readium"]
        XCTAssertNotNil(TPPBookLocation(dictionary: complete))
    }

    // SRS: TPPBookLocation init with empty dictionary fails
    func testBookLocation_initWithEmptyDictionary() {
        let loc = TPPBookLocation(dictionary: [:])
        XCTAssertNil(loc)
        // A dictionary with one valid key but the wrong type for the other also fails
        let wrongType: [String: Any] = ["locationString": 99, "renderer": "r"]
        XCTAssertNil(TPPBookLocation(dictionary: wrongType), "Non-string locationString should fail")
    }

    // SRS: TPPBookLocation dictionaryRepresentation round-trips
    func testBookLocation_dictionaryRoundTrip() {
        let loc = TPPBookLocation(locationString: "loc:data", renderer: "TestRenderer")!
        let dict = loc.dictionaryRepresentation
        let restored = TPPBookLocation(dictionary: dict)
        XCTAssertEqual(restored?.locationString, "loc:data")
        XCTAssertEqual(restored?.renderer, "TestRenderer")
    }

    // SRS: TPPBookLocation locationString mutation round-trips through dictionaryRepresentation
    func testBookLocation_locationStringMutation_ReflectsInDictionary() {
        let loc = TPPBookLocation(locationString: "old", renderer: "R")!

        // Act: mutate locationString
        loc.locationString = "new"

        // Assert: the dictionary representation reflects the mutation
        XCTAssertEqual(loc.locationString, "new",
            "locationString must reflect the mutation immediately")
        XCTAssertEqual(loc.dictionaryRepresentation["locationString"] as? String, "new",
            "dictionaryRepresentation must be consistent with the mutated locationString")
    }

    // SRS: TPPBookLocation renderer mutation round-trips through dictionaryRepresentation
    func testBookLocation_rendererMutation_ReflectsInDictionary() {
        let loc = TPPBookLocation(locationString: "s", renderer: "old")!

        // Act: mutate renderer
        loc.renderer = "new"

        // Assert: the dictionary representation reflects the mutation
        XCTAssertEqual(loc.renderer, "new",
            "renderer must reflect the mutation immediately")
        XCTAssertEqual(loc.dictionaryRepresentation["renderer"] as? String, "new",
            "dictionaryRepresentation must be consistent with the mutated renderer")
    }
}

// MARK: - TPPBookLocationKey Tests

final class TPPBookLocationKeyTests: XCTestCase {

    // SRS: TPPBookLocationKey cases match the dictionary keys produced by TPPBookLocation.
    // This verifies that the typed enum accessor retrieves the same value that
    // dictionaryRepresentation stores, ensuring round-trip integrity.
    func testBookLocationKey_MatchesDictionaryRepresentationKeys() {
        let loc = TPPBookLocation(locationString: "chapter7", renderer: "readium")!
        let dict = loc.dictionaryRepresentation as TPPBookLocationData

        XCTAssertEqual(dict.string(for: .locationString), "chapter7",
            ".locationString key must resolve the value stored under 'locationString'")
        XCTAssertEqual(dict.string(for: .renderer), "readium",
            ".renderer key must resolve the value stored under 'renderer'")
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
        // Bool, Array, and Dict should also return nil — only String is valid
        let boolData: TPPBookLocationData = ["locationString": true]
        XCTAssertNil(boolData.string(for: .locationString))
        // Missing key returns nil too
        let emptyData: TPPBookLocationData = [:]
        XCTAssertNil(emptyData.string(for: .renderer))
    }
}

// MARK: - TPPBookContentTypeConverter Tests

final class TPPBookContentTypeConverterTests: XCTestCase {

    // SRS: TPPBookContentTypeConverter epub string — and it is distinct from other types
    func testStringValue_epub() {
        let epubString = TPPBookContentTypeConverter.stringValue(of: .epub)
        XCTAssertEqual(epubString, "Epub")
        // Must not collide with other type strings
        XCTAssertNotEqual(epubString, TPPBookContentTypeConverter.stringValue(of: .audiobook))
        XCTAssertNotEqual(epubString, TPPBookContentTypeConverter.stringValue(of: .pdf))
        XCTAssertNotEqual(epubString, TPPBookContentTypeConverter.stringValue(of: .unsupported))
    }

    // SRS: TPPBookContentTypeConverter audiobook string — non-empty and distinct
    func testStringValue_audiobook() {
        let audiobookString = TPPBookContentTypeConverter.stringValue(of: .audiobook)
        XCTAssertEqual(audiobookString, "AudioBook")
        XCTAssertFalse(audiobookString.isEmpty, "Audiobook type string must not be empty")
        XCTAssertNotEqual(audiobookString, TPPBookContentTypeConverter.stringValue(of: .epub))
    }

    // SRS: TPPBookContentTypeConverter pdf string — non-empty and distinct
    func testStringValue_pdf() {
        let pdfString = TPPBookContentTypeConverter.stringValue(of: .pdf)
        XCTAssertEqual(pdfString, "PDF")
        XCTAssertFalse(pdfString.isEmpty, "PDF type string must not be empty")
        XCTAssertNotEqual(pdfString, TPPBookContentTypeConverter.stringValue(of: .epub))
    }

    // SRS: TPPBookContentTypeConverter unsupported string — all four type strings are unique
    func testStringValue_unsupported() {
        let types: [TPPBookContentType] = [.epub, .audiobook, .pdf, .unsupported]
        let strings = types.map { TPPBookContentTypeConverter.stringValue(of: $0) }

        XCTAssertEqual(TPPBookContentTypeConverter.stringValue(of: .unsupported), "Unsupported")
        // All strings must be unique — no two content types map to the same label
        XCTAssertEqual(Set(strings).count, types.count,
            "Each TPPBookContentType must produce a unique string value")
    }
}

// MARK: - TPPBookAuthor Tests

final class TPPBookAuthorCoverageTests: XCTestCase {

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

    // SRS: TPPBookAuthor preserves both name and URL through properties,
    // and a nil URL is distinct from an empty-string URL.
    func testBookAuthor_NilURL_IsDistinctFromEmptyURL() {
        let authorWithNilURL = TPPBookAuthor(authorName: "Nil URL Author", relatedBooksURL: nil)
        let authorWithEmptyPath = TPPBookAuthor(
            authorName: "Empty Author",
            relatedBooksURL: URL(string: "https://example.com")
        )

        XCTAssertNil(authorWithNilURL.relatedBooksURL,
            "Author initialized with nil URL must not synthesize a URL")
        XCTAssertNotNil(authorWithEmptyPath.relatedBooksURL,
            "Author initialized with a URL must retain it")
        XCTAssertNotEqual(authorWithNilURL.relatedBooksURL, authorWithEmptyPath.relatedBooksURL,
            "nil URL and a real URL must not be equal")
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
        // Empty data also throws
        XCTAssertThrowsError(try TPPProblemDocument.fromData(Data()))
        // A JSON array (not an object) should also throw or produce an error
        let arrayData = "[1,2,3]".data(using: .utf8)!
        XCTAssertThrowsError(try TPPProblemDocument.fromData(arrayData))
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
        // Neither title nor detail: stringValue should be an empty string or only separator
        let emptyDoc = TPPProblemDocument.fromDictionary([:])
        XCTAssertFalse(emptyDoc.stringValue.contains("nil"), "stringValue must not expose 'nil' literals")
    }

    // SRS: TPPProblemDocument stringValue without detail
    func testStringValue_noDetail() {
        let doc = TPPProblemDocument.fromDictionary([
            "title": "Title only"
        ])
        XCTAssertEqual(doc.stringValue, "Title only: ")
        // Must differ from a doc that has both title and detail
        let full = TPPProblemDocument.fromDictionary(["title": "Title only", "detail": "D"])
        XCTAssertNotEqual(doc.stringValue, full.stringValue, "Adding detail must change stringValue")
        // Must differ from a doc that has no title either
        let noTitle = TPPProblemDocument.fromDictionary([:])
        XCTAssertNotEqual(doc.stringValue, noTitle.stringValue, "Title-only stringValue must differ from empty doc")
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

    // SRS: TPPProblemDocument fromProblemResponseData with non-problem JSON returns nil
    func testFromProblemResponseData_nonProblemJSON() {
        let json = """
        {"message": "Server error occurred"}
        """
        let doc = TPPProblemDocument.fromProblemResponseData(json.data(using: .utf8)!)
        // A JSON object without "type"/"title"/"detail"/"status" is not a valid problem document.
        // Either nil is returned, or the decoded document has no meaningful fields.
        if let doc = doc {
            // If decode succeeds, meaningful problem fields must be absent
            XCTAssertNil(doc.type, "Non-problem JSON must not produce a type field")
            XCTAssertNil(doc.title, "Non-problem JSON must not produce a title field")
        }
        // nil is also a fully acceptable result for non-problem JSON
    }

    // SRS: TPPProblemDocument fromProblemResponseData with invalid data
    func testFromProblemResponseData_invalidData() {
        let doc = TPPProblemDocument.fromProblemResponseData("not json".data(using: .utf8)!)
        XCTAssertNil(doc)
        // Empty data must also return nil, not crash
        XCTAssertNil(TPPProblemDocument.fromProblemResponseData(Data()))
        // Partially-valid JSON that truncates must return nil
        XCTAssertNil(TPPProblemDocument.fromProblemResponseData("{\"type\":".data(using: .utf8)!))
    }

    // SRS: TPPProblemDocument fromResponseError with problemDoc in error
    func testFromResponseError_nilErrorNilData() {
        let doc = TPPProblemDocument.fromResponseError(nil, responseData: nil)
        XCTAssertNil(doc)
        // Passing a non-nil empty data body must also not produce a document
        let emptyDataDoc = TPPProblemDocument.fromResponseError(nil, responseData: Data())
        XCTAssertNil(emptyDataDoc, "Empty data body must not produce a problem document")
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

// MARK: - TPPBookLocation Edge Case Tests

final class TPPBookLocationEdgeCaseTests: XCTestCase {

    // MARK: - Init from string/renderer

    func test_init_withValidStringAndRenderer_createsLocation() {
        let location = TPPBookLocation(locationString: "chapter3", renderer: "readium")
        XCTAssertEqual(location?.locationString, "chapter3")
        XCTAssertEqual(location?.renderer, "readium")
        // The dictionary round-trip must preserve both values
        XCTAssertEqual(location?.dictionaryRepresentation["locationString"] as? String, "chapter3")
    }

    func test_init_withEmptyLocationString_createsLocation() {
        let location = TPPBookLocation(locationString: "", renderer: "readium")
        XCTAssertEqual(location?.locationString, "")
        // Empty locationString location string is distinct from a nil location object
        XCTAssertNotNil(location, "Empty locationString must still produce a location")
    }

    func test_init_withEmptyRenderer_createsLocation() {
        let location = TPPBookLocation(locationString: "chapter1", renderer: "")
        XCTAssertEqual(location?.renderer, "")
        XCTAssertEqual(location?.locationString, "chapter1", "locationString must be preserved even when renderer is empty")
    }

    func test_init_withLongJSON_createsLocation() {
        let jsonString = """
        {"href":"/chapter/1","progression":0.42,"totalProgression":0.15}
        """
        let location = TPPBookLocation(locationString: jsonString, renderer: "readium-2")
        XCTAssertEqual(location?.locationString, jsonString)
        // Long JSON location strings must be parseable via locationStringDictionary
        XCTAssertNotNil(location?.locationStringDictionary(), "Valid JSON locationString must parse to a dictionary")
    }

    // MARK: - Init from dictionary

    func test_initFromDictionary_withValidData_createsLocation() {
        let dict: [String: Any] = [
            "locationString": "page42",
            "renderer": "rmsdk"
        ]
        let location = TPPBookLocation(dictionary: dict)
        XCTAssertEqual(location?.locationString, "page42")
        XCTAssertEqual(location?.renderer, "rmsdk")
        // The resulting location must round-trip back through its own dictionary
        let roundTripped = TPPBookLocation(dictionary: location!.dictionaryRepresentation)
        XCTAssertEqual(roundTripped?.locationString, "page42")
    }

    func test_initFromDictionary_missingLocationString_returnsNil() {
        let dict: [String: Any] = ["renderer": "readium"]
        let location = TPPBookLocation(dictionary: dict)
        XCTAssertNil(location)
        // The full dict (both keys) must succeed — confirming renderer alone isn't enough
        let full: [String: Any] = ["locationString": "chapter1", "renderer": "readium"]
        XCTAssertNotNil(TPPBookLocation(dictionary: full))
    }

    func test_initFromDictionary_missingRenderer_returnsNil() {
        let dict: [String: Any] = ["locationString": "chapter1"]
        let location = TPPBookLocation(dictionary: dict)
        XCTAssertNil(location)
        // locationString alone is not sufficient — renderer is required
        XCTAssertNil(TPPBookLocation(dictionary: ["locationString": ""]))
    }

    func test_initFromDictionary_emptyDictionary_returnsNil() {
        let location = TPPBookLocation(dictionary: [:])
        XCTAssertNil(location)
        // A dictionary with both keys present must NOT be nil
        let nonEmpty: [String: Any] = ["locationString": "s", "renderer": "r"]
        XCTAssertNotNil(TPPBookLocation(dictionary: nonEmpty), "Valid dict must produce a location")
    }

    func test_initFromDictionary_wrongTypes_returnsNil() {
        let dict: [String: Any] = [
            "locationString": 42,
            "renderer": true
        ]
        let location = TPPBookLocation(dictionary: dict)
        XCTAssertNil(location)
        // Only one wrong type also fails
        let oneWrong: [String: Any] = ["locationString": "valid", "renderer": 999]
        XCTAssertNil(TPPBookLocation(dictionary: oneWrong), "Non-string renderer must fail")
    }

    func test_initFromDictionary_extraKeys_ignoresExtras() {
        let dict: [String: Any] = [
            "locationString": "chapter5",
            "renderer": "readium",
            "extraKey": "extraValue"
        ]
        let location = TPPBookLocation(dictionary: dict)
        XCTAssertEqual(location?.locationString, "chapter5")
        XCTAssertEqual(location?.renderer, "readium", "Extra keys must not overwrite valid values")
        // The extra key should NOT appear in dictionaryRepresentation
        XCTAssertNil(location?.dictionaryRepresentation["extraKey"], "Extra input keys must be dropped from representation")
    }

    // MARK: - Dictionary round-trip

    func test_dictionaryRepresentation_roundTrips() {
        let original = TPPBookLocation(locationString: "loc-123", renderer: "readium-2")!
        let dict = original.dictionaryRepresentation
        let restored = TPPBookLocation(dictionary: dict)

        XCTAssertEqual(restored?.locationString, original.locationString)
        XCTAssertEqual(restored?.renderer, original.renderer)
        // The restored location must itself produce an identical dictionary
        XCTAssertEqual(restored?.dictionaryRepresentation["locationString"] as? String,
                       original.dictionaryRepresentation["locationString"] as? String)
    }

    func test_dictionaryRepresentation_containsExpectedKeys() {
        let location = TPPBookLocation(locationString: "test", renderer: "r")!
        let dict = location.dictionaryRepresentation

        XCTAssertEqual(dict["locationString"] as? String, "test")
        XCTAssertEqual(dict["renderer"] as? String, "r")
        XCTAssertEqual(dict.count, 2)
    }

    func test_dictionaryRepresentation_preservesJSONContent() {
        let json = """
        {"chapter":"3","position":0.75}
        """
        let location = TPPBookLocation(locationString: json, renderer: "readium")!
        let dict = location.dictionaryRepresentation
        let restored = TPPBookLocation(dictionary: dict)

        XCTAssertEqual(restored?.locationString, json)
    }

    // MARK: - TPPBookLocationData extension

    func test_bookLocationData_stringForKey_returnsValue() {
        let data: TPPBookLocationData = [
            "locationString": "chapter1",
            "renderer": "readium"
        ]
        XCTAssertEqual(data.string(for: .locationString), "chapter1")
        XCTAssertEqual(data.string(for: .renderer), "readium")
    }

    func test_bookLocationData_stringForKey_missingKey_returnsNil() {
        let data: TPPBookLocationData = [:]
        XCTAssertNil(data.string(for: .locationString))
        XCTAssertNil(data.string(for: .renderer))
    }

    func test_bookLocationData_stringForKey_wrongType_returnsNil() {
        let data: TPPBookLocationData = [
            "locationString": 42
        ]
        XCTAssertNil(data.string(for: .locationString))
        // The renderer key with a wrong type must also return nil
        let rendererWrong: TPPBookLocationData = ["renderer": false]
        XCTAssertNil(rendererWrong.string(for: .renderer))
        // A valid string value must still be returned for a co-existing correct key
        let mixed: TPPBookLocationData = ["locationString": 99, "renderer": "readium"]
        XCTAssertNil(mixed.string(for: .locationString))
        XCTAssertEqual(mixed.string(for: .renderer), "readium")
    }

    // MARK: - locationStringDictionary

    func test_locationStringDictionary_validJSON_returnsParsedDictionary() {
        let json = """
        {"href":"/chapter/1","progression":0.42}
        """
        let location = TPPBookLocation(locationString: json, renderer: "readium")!
        let dict = location.locationStringDictionary()

        XCTAssertNotNil(dict)
        XCTAssertEqual(dict?["href"] as? String, "/chapter/1")
        XCTAssertEqual(dict?["progression"] as? Double ?? -1, 0.42, accuracy: 0.001)
    }

    func test_locationStringDictionary_invalidJSON_returnsNil() {
        let location = TPPBookLocation(locationString: "not json at all", renderer: "readium")!
        let dict = location.locationStringDictionary()
        XCTAssertNil(dict)
        // A valid JSON string must contrast: parsing succeeds and dict is non-nil
        let validLoc = TPPBookLocation(locationString: "{\"href\":\"/ch/1\"}", renderer: "readium")!
        XCTAssertNotNil(validLoc.locationStringDictionary(), "Valid JSON must parse successfully")
    }

    func test_locationStringDictionary_emptyString_returnsNil() {
        let location = TPPBookLocation(locationString: "", renderer: "readium")!
        let dict = location.locationStringDictionary()
        XCTAssertNil(dict)
        // A whitespace-only string is also not valid JSON
        let wsLoc = TPPBookLocation(locationString: "   ", renderer: "readium")!
        XCTAssertNil(wsLoc.locationStringDictionary(), "Whitespace-only string must not parse to a dictionary")
    }

    func test_locationStringDictionary_arrayJSON_returnsNil() {
        // JSON array is not a dictionary
        let location = TPPBookLocation(locationString: "[1,2,3]", renderer: "readium")!
        let dict = location.locationStringDictionary()
        XCTAssertNil(dict)
        // JSON null is also not a dictionary
        let nullLoc = TPPBookLocation(locationString: "null", renderer: "readium")!
        XCTAssertNil(nullLoc.locationStringDictionary(), "JSON null must not parse to a dictionary")
    }

    // MARK: - isSimilarTo

    func test_isSimilarTo_identicalLocations_returnsTrue() {
        let json = """
        {"href":"/chapter/1","progression":0.42}
        """
        let a = TPPBookLocation(locationString: json, renderer: "readium")!
        let b = TPPBookLocation(locationString: json, renderer: "readium")!

        XCTAssertTrue(a.isSimilarTo(b))
    }

    func test_isSimilarTo_differentRenderer_returnsFalse() {
        let json = """
        {"href":"/chapter/1","progression":0.42}
        """
        let a = TPPBookLocation(locationString: json, renderer: "readium")!
        let b = TPPBookLocation(locationString: json, renderer: "rmsdk")!

        XCTAssertFalse(a.isSimilarTo(b))
    }

    func test_isSimilarTo_differentContent_returnsFalse() {
        let jsonA = """
        {"href":"/chapter/1","progression":0.42}
        """
        let jsonB = """
        {"href":"/chapter/2","progression":0.50}
        """
        let a = TPPBookLocation(locationString: jsonA, renderer: "readium")!
        let b = TPPBookLocation(locationString: jsonB, renderer: "readium")!

        XCTAssertFalse(a.isSimilarTo(b))
    }

    func test_isSimilarTo_ignoresTimeStampDifferences() {
        let jsonA = """
        {"href":"/chapter/1","progression":0.42,"timeStamp":"2024-01-01T00:00:00Z"}
        """
        let jsonB = """
        {"href":"/chapter/1","progression":0.42,"timeStamp":"2024-06-15T12:00:00Z"}
        """
        let a = TPPBookLocation(locationString: jsonA, renderer: "readium")!
        let b = TPPBookLocation(locationString: jsonB, renderer: "readium")!

        XCTAssertTrue(a.isSimilarTo(b))
    }

    func test_isSimilarTo_ignoresAnnotationIdDifferences() {
        let jsonA = """
        {"href":"/chapter/1","progression":0.42,"annotationId":"aaa-111"}
        """
        let jsonB = """
        {"href":"/chapter/1","progression":0.42,"annotationId":"bbb-222"}
        """
        let a = TPPBookLocation(locationString: jsonA, renderer: "readium")!
        let b = TPPBookLocation(locationString: jsonB, renderer: "readium")!

        XCTAssertTrue(a.isSimilarTo(b))
    }

    func test_isSimilarTo_nonJSONLocationString_returnsFalse() {
        // When locationString is not valid JSON, locationStringDictionary returns nil
        // so isSimilarTo should return false even if both locations are identical
        let a = TPPBookLocation(locationString: "plaintext", renderer: "readium")!
        let b = TPPBookLocation(locationString: "plaintext", renderer: "readium")!
        XCTAssertFalse(a.isSimilarTo(b))
        // Contrast: identical valid-JSON locations ARE similar
        let json = "{\"href\":\"/ch/1\",\"progression\":0.5}"
        let c = TPPBookLocation(locationString: json, renderer: "readium")!
        let d = TPPBookLocation(locationString: json, renderer: "readium")!
        XCTAssertTrue(c.isSimilarTo(d), "Identical valid-JSON locations must be similar")
        // Non-JSON on one side and JSON on the other must not be similar
        XCTAssertFalse(a.isSimilarTo(c), "Non-JSON location must not be similar to a JSON location")
    }

    func test_isSimilarTo_sameContentDifferentTimeStampAndAnnotationId_returnsTrue() {
        let jsonA = """
        {"href":"/ch/5","progression":0.9,"timeStamp":"2024-01-01","annotationId":"id1","page":42}
        """
        let jsonB = """
        {"href":"/ch/5","progression":0.9,"timeStamp":"2024-12-31","annotationId":"id2","page":42}
        """
        let a = TPPBookLocation(locationString: jsonA, renderer: "readium")!
        let b = TPPBookLocation(locationString: jsonB, renderer: "readium")!

        XCTAssertTrue(a.isSimilarTo(b))
    }
}
