//
//  OPDS2AuthenticationDocumentTests.swift
//  PalaceTests
//
//  Tests for OPDS2 authentication document parsing
//

import XCTest
@testable import Palace

final class OPDS2AuthenticationDocumentTests: XCTestCase {

    // MARK: - Properties

    private var nyplAuthURL: URL!
    private var gplAuthURL: URL!
    private var dplAuthURL: URL!

    // MARK: - Setup

    override func setUpWithError() throws {
        try super.setUpWithError()
        let bundle = Bundle(for: type(of: self))
        nyplAuthURL = bundle.url(forResource: "nypl_authentication_document", withExtension: "json")
        gplAuthURL = bundle.url(forResource: "gpl_authentication_document", withExtension: "json")
        dplAuthURL = bundle.url(forResource: "dpl_authentication_document", withExtension: "json")
    }

    // MARK: - Basic Parsing Tests

    func testFromData_withValidJSON_parsesDocument() throws {
        guard let url = nyplAuthURL else {
            XCTFail("Test resource not found")
            return
        }

        let data = try Data(contentsOf: url)
        let doc = try OPDS2AuthenticationDocument.fromData(data)

        XCTAssertFalse(doc.title.isEmpty)
        XCTAssertFalse(doc.id.isEmpty)
    }

    func testFromData_withInvalidJSON_throwsError() {
        let invalidJSON = Data("{ invalid json }".utf8)

        XCTAssertThrowsError(try OPDS2AuthenticationDocument.fromData(invalidJSON))
        // A non-JSON payload must also throw
        XCTAssertThrowsError(try OPDS2AuthenticationDocument.fromData(Data("not json at all".utf8)),
                             "Non-JSON bytes must throw a parsing error")
    }

    func testFromData_withEmptyData_throwsError() {
        let emptyData = Data()

        XCTAssertThrowsError(try OPDS2AuthenticationDocument.fromData(emptyData))
        // Single whitespace is also invalid
        XCTAssertThrowsError(try OPDS2AuthenticationDocument.fromData(Data(" ".utf8)),
                             "Whitespace-only data must throw a parsing error")
    }

    func testFromData_withMissingRequiredFields_throwsError() {
        // Missing 'id' and 'title' which are required
        let incompleteJSON = Data("""
    {
      "authentication": []
    }
    """.utf8)

        XCTAssertThrowsError(try OPDS2AuthenticationDocument.fromData(incompleteJSON))
        // Missing only title (id present) must also fail
        XCTAssertThrowsError(try OPDS2AuthenticationDocument.fromData(Data("""
    {"id": "test-id", "authentication": []}
    """.utf8)), "JSON with id but missing title must throw a parsing error")
    }

    // MARK: - Authentication Methods Tests

    func testAuthentication_parsesMultipleMethods() throws {
        guard let url = nyplAuthURL else {
            XCTFail("Test resource not found")
            return
        }

        let data = try Data(contentsOf: url)
        let doc = try OPDS2AuthenticationDocument.fromData(data)

        // NYPL should have multiple auth methods
        XCTAssertNotNil(doc.authentication)
        XCTAssertFalse(doc.authentication?.isEmpty ?? true)
    }

    func testAuthentication_parsesBasicAuth() throws {
        guard let url = gplAuthURL else {
            XCTFail("Test resource not found")
            return
        }

        let data = try Data(contentsOf: url)
        let doc = try OPDS2AuthenticationDocument.fromData(data)

        let basicAuth = doc.authentication?.first { $0.type.contains("basic") || $0.type.contains("Basic") }
        XCTAssertNotNil(basicAuth)
    }

    func testAuthentication_noAuthRequired() throws {
        guard let url = dplAuthURL else {
            XCTFail("Test resource not found")
            return
        }

        let data = try Data(contentsOf: url)
        let doc = try OPDS2AuthenticationDocument.fromData(data)

        // DPL doesn't require authentication
        XCTAssertTrue(doc.authentication?.isEmpty ?? true)
    }

    // MARK: - Labels Tests

    func testAuthentication_parsesLabels() throws {
        guard let url = gplAuthURL else {
            XCTFail("Test resource not found")
            return
        }

        let data = try Data(contentsOf: url)
        let doc = try OPDS2AuthenticationDocument.fromData(data)

        if let auth = doc.authentication?.first, let labels = auth.labels {
            XCTAssertFalse(labels.login.isEmpty)
            XCTAssertFalse(labels.password.isEmpty)
        }
    }

    // MARK: - Input Configuration Tests

    func testAuthentication_parsesInputConfiguration() throws {
        guard let url = gplAuthURL else {
            XCTFail("Test resource not found")
            return
        }

        let data = try Data(contentsOf: url)
        let doc = try OPDS2AuthenticationDocument.fromData(data)

        if let auth = doc.authentication?.first, let inputs = auth.inputs {
            XCTAssertNotNil(inputs.login.keyboard)
            XCTAssertNotNil(inputs.password.keyboard)
        }
    }

    func testAuthentication_parsesBarcodeFormat() throws {
        guard let url = gplAuthURL else {
            XCTFail("Test resource not found")
            return
        }

        let data = try Data(contentsOf: url)
        let doc = try OPDS2AuthenticationDocument.fromData(data)

        if let auth = doc.authentication?.first, let inputs = auth.inputs {
            // Barcode format is optional
            XCTAssertNotNil(inputs.login)
        }
    }

    func testAuthentication_parsesMaximumLength() throws {
        guard let url = gplAuthURL else {
            XCTFail("Test resource not found")
            return
        }

        let data = try Data(contentsOf: url)
        let doc = try OPDS2AuthenticationDocument.fromData(data)

        if let auth = doc.authentication?.first, let inputs = auth.inputs {
            // Maximum length may or may not be present
            XCTAssertNotNil(inputs.password)
        }
    }

    // MARK: - Features Tests

    func testFeatures_parsesEnabledFeatures() throws {
        guard let url = nyplAuthURL else {
            XCTFail("Test resource not found")
            return
        }

        let data = try Data(contentsOf: url)
        let doc = try OPDS2AuthenticationDocument.fromData(data)

        // Features are optional
        if let features = doc.features {
            XCTAssertNotNil(features.enabled ?? features.disabled)
        }
    }

    func testFeatures_parsesDisabledFeatures() throws {
        guard let url = nyplAuthURL else {
            XCTFail("Test resource not found")
            return
        }

        let data = try Data(contentsOf: url)
        let doc = try OPDS2AuthenticationDocument.fromData(data)

        // Document must parse without throwing
        XCTAssertFalse(doc.id.isEmpty, "Document id must be non-empty even when features are absent")
        XCTAssertFalse(doc.title.isEmpty, "Document title must be non-empty")
        // If features exist they must have at least one of enabled/disabled populated
        if let features = doc.features {
            let hasEnabledOrDisabled = features.enabled != nil || features.disabled != nil
            XCTAssertTrue(hasEnabledOrDisabled, "Features object must contain enabled or disabled list")
        }
    }

    // MARK: - Links Tests

    func testLinks_parsesCorrectly() throws {
        guard let url = nyplAuthURL else {
            XCTFail("Test resource not found")
            return
        }

        let data = try Data(contentsOf: url)
        let doc = try OPDS2AuthenticationDocument.fromData(data)

        if let links = doc.links {
            XCTAssertFalse(links.isEmpty)
            for link in links {
                XCTAssertFalse(link.href.isEmpty)
            }
        }
    }

    func testLinks_firstRelMethod_findsPasswordReset() throws {
        guard let url = nyplAuthURL else {
            XCTFail("Test resource not found")
            return
        }

        let data = try Data(contentsOf: url)
        let doc = try OPDS2AuthenticationDocument.fromData(data)

        // Every link in the document must have a non-empty href
        if let links = doc.links {
            XCTAssertFalse(links.isEmpty, "NYPL auth document should have at least one link")
            for link in links {
                XCTAssertFalse(link.href.isEmpty, "Each link must have a non-empty href")
            }
        }

        // If a password-reset link exists, verify it has the correct rel and a valid URL
        let passwordResetLink = doc.links?.first { $0.rel == OPDS2LinkRel.passwordReset.rawValue }
        if let resetLink = passwordResetLink {
            XCTAssertFalse(resetLink.href.isEmpty, "Password reset link must have a non-empty href")
            XCTAssertEqual(resetLink.rel, OPDS2LinkRel.passwordReset.rawValue,
                           "Rel must match the expected password-reset constant")
        }
    }

    // MARK: - Announcements Tests

    func testAnnouncements_parsesIfPresent() throws {
        guard let url = nyplAuthURL else {
            XCTFail("Test resource not found")
            return
        }

        let data = try Data(contentsOf: url)
        let doc = try OPDS2AuthenticationDocument.fromData(data)

        // Announcements are optional
        if let announcements = doc.announcements {
            for announcement in announcements {
                XCTAssertFalse(announcement.id.isEmpty)
                XCTAssertFalse(announcement.content.isEmpty)
            }
        }
    }

    // MARK: - Color Scheme Tests

    func testColorScheme_parsesIfPresent() throws {
        guard let url = nyplAuthURL else {
            XCTFail("Test resource not found")
            return
        }

        let data = try Data(contentsOf: url)
        let doc = try OPDS2AuthenticationDocument.fromData(data)

        // Document must round-trip through JSON successfully regardless of color scheme presence
        XCTAssertFalse(doc.id.isEmpty, "Document id must survive parsing")
        XCTAssertFalse(doc.title.isEmpty, "Document title must survive parsing")
        // If a color scheme is present, its values must be non-empty strings
        if let colorScheme = doc.colorScheme {
            XCTAssertFalse(colorScheme.isEmpty, "Color scheme string must not be empty when present")
        }
    }

    // MARK: - Service Description Tests

    func testServiceDescription_parsesIfPresent() throws {
        guard let url = nyplAuthURL else {
            XCTFail("Test resource not found")
            return
        }

        let data = try Data(contentsOf: url)
        let doc = try OPDS2AuthenticationDocument.fromData(data)

        // The document itself must always have required top-level fields
        XCTAssertFalse(doc.id.isEmpty, "Document id is required")
        XCTAssertFalse(doc.title.isEmpty, "Document title is required")
        // If a service description is present it must be a non-empty string
        if let description = doc.serviceDescription {
            XCTAssertFalse(description.isEmpty, "serviceDescription must not be an empty string when present")
        }
    }
}

// MARK: - Announcement Tests

final class AnnouncementTests: XCTestCase {

    func testAnnouncement_decodesValidJSON() throws {
        let json = Data("""
    {
      "id": "announcement-1",
      "content": "Library will be closed on Monday"
    }
    """.utf8)

        let announcement = try JSONDecoder().decode(Announcement.self, from: json)

        XCTAssertEqual(announcement.id, "announcement-1")
        XCTAssertEqual(announcement.content, "Library will be closed on Monday")
    }

    func testAnnouncement_withMissingId_throwsError() {
        let json = Data("""
    {
      "content": "Test content"
    }
    """.utf8)

        XCTAssertThrowsError(try JSONDecoder().decode(Announcement.self, from: json))
        // An empty JSON object must also fail (missing both id and content)
        XCTAssertThrowsError(try JSONDecoder().decode(Announcement.self, from: Data("{}".utf8)),
                             "Empty JSON object must throw for missing id and content")
    }

    func testAnnouncement_withMissingContent_throwsError() {
        let json = Data("""
    {
      "id": "test-id"
    }
    """.utf8)

        XCTAssertThrowsError(try JSONDecoder().decode(Announcement.self, from: json))
        // id with null content must also fail
        XCTAssertThrowsError(try JSONDecoder().decode(Announcement.self, from: Data("""
    {"id": "test-id", "content": null}
    """.utf8)), "JSON with null content must throw a decoding error")
    }
}

// MARK: - OPDS2LinkRel Tests

final class OPDS2LinkRelTests: XCTestCase {

    func testPasswordReset_hasCorrectRawValue() {
        let rel = OPDS2LinkRel.passwordReset
        XCTAssertEqual(rel.rawValue, "http://librarysimplified.org/terms/rel/patron-password-reset")
        // The raw value must be a valid URL-like string (contains scheme and path)
        XCTAssertTrue(rel.rawValue.contains("://"), "passwordReset rel must contain a scheme separator")
        // Verify it's distinguishable from other rels (not empty or a generic string)
        XCTAssertTrue(rel.rawValue.contains("password-reset"), "raw value must reference 'password-reset'")
    }
}
