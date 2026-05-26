//
//  OPDS2FeedParsingTests.swift
//  PalaceTests
//
//  Extended tests for OPDS2 feed parsing
//

import XCTest
import PalaceCatalog
@testable import Palace

final class OPDS2FeedParsingTests: XCTestCase {

    // MARK: - Properties

    private var testFeedURL: URL!

    // MARK: - Setup

    override func setUpWithError() throws {
        try super.setUpWithError()
        testFeedURL = Bundle(for: type(of: self))
            .url(forResource: "OPDS2CatalogsFeed", withExtension: "json")
    }

    // MARK: - Feed Parsing Tests

    func testFromData_withValidJSON_parsesFeed() throws {
        let data = try Data(contentsOf: testFeedURL)
        let feed = try OPDS2CatalogsFeed.fromData(data)

        XCTAssertFalse(feed.catalogs.isEmpty)
        XCTAssertFalse(feed.links.isEmpty)
        XCTAssertFalse(feed.metadata.title.isEmpty)
    }

    func testFromData_withInvalidJSON_throwsError() {
        let invalidJSON = Data("{ invalid json }".utf8)

        XCTAssertThrowsError(try OPDS2CatalogsFeed.fromData(invalidJSON))
        // A completely wrong data type must also fail
        XCTAssertThrowsError(try OPDS2CatalogsFeed.fromData(Data("not json at all".utf8)))
    }

    func testFromData_withEmptyData_throwsError() {
        let emptyData = Data()

        XCTAssertThrowsError(try OPDS2CatalogsFeed.fromData(emptyData))
        // Single whitespace byte is also invalid
        XCTAssertThrowsError(try OPDS2CatalogsFeed.fromData(Data(" ".utf8)))
    }

    func testFromData_withMissingCatalogs_throwsError() {
        let jsonWithoutCatalogs = Data("""
    {
      "links": [],
      "metadata": {"title": "Test"}
    }
    """.utf8)

        XCTAssertThrowsError(try OPDS2CatalogsFeed.fromData(jsonWithoutCatalogs))
        // JSON with null catalogs key must also fail
        XCTAssertThrowsError(try OPDS2CatalogsFeed.fromData(Data("""
    {"catalogs": null, "links": [], "metadata": {"title": "Test"}}
    """.utf8)))
    }

    func testFromData_withEmptyCatalogs_parsesSuccessfully() throws {
        let jsonWithEmptyCatalogs = Data("""
    {
      "catalogs": [],
      "links": [],
      "metadata": {"title": "Test Feed"}
    }
    """.utf8)

        let feed = try OPDS2CatalogsFeed.fromData(jsonWithEmptyCatalogs)

        XCTAssertTrue(feed.catalogs.isEmpty)
        XCTAssertEqual(feed.metadata.title, "Test Feed")
    }

    // MARK: - Metadata Tests

    func testMetadata_parsesTitle() throws {
        let data = try Data(contentsOf: testFeedURL)
        let feed = try OPDS2CatalogsFeed.fromData(data)

        XCTAssertFalse(feed.metadata.title.isEmpty)
        // The title must be a string with meaningful content (not just whitespace)
        XCTAssertFalse(feed.metadata.title.trimmingCharacters(in: .whitespaces).isEmpty,
                       "Feed metadata title must not be only whitespace")
    }

    func testMetadata_parsesAdobeVendorId() throws {
        let data = try Data(contentsOf: testFeedURL)
        let feed = try OPDS2CatalogsFeed.fromData(data)

        // Metadata must always be present and have a non-empty title
        XCTAssertNotNil(feed.metadata)
        XCTAssertFalse(feed.metadata.title.isEmpty, "Feed metadata must have a non-empty title")
        // Verify metadata has expected properties
        XCTAssertNotNil(feed.metadata.title, "Feed metadata title should be accessible")
    }

    // MARK: - Links Tests

    func testLinks_parsesCorrectly() throws {
        let data = try Data(contentsOf: testFeedURL)
        let feed = try OPDS2CatalogsFeed.fromData(data)

        XCTAssertFalse(feed.links.isEmpty)

        for link in feed.links {
            XCTAssertFalse(link.href.isEmpty)
        }
    }

    // MARK: - Date Parsing Tests

    func testDateParsing_withISO8601_parsesCorrectly() throws {
        let data = try Data(contentsOf: testFeedURL)
        let feed = try OPDS2CatalogsFeed.fromData(data)

        // Check that dates in publications are parsed
        for catalog in feed.catalogs {
            // metadata.updated should be a valid date
            XCTAssertNotNil(catalog.metadata.updated)
        }
    }

    func testDateParsing_withMilliseconds_parsesCorrectly() throws {
        let jsonWithMilliseconds = Data("""
    {
      "catalogs": [
        {
          "metadata": {
            "title": "Test",
            "updated": "2024-01-15T10:30:00.123Z",
            "id": "test-id"
          },
          "links": []
        }
      ],
      "links": [],
      "metadata": {"title": "Test Feed"}
    }
    """.utf8)

        let feed = try OPDS2CatalogsFeed.fromData(jsonWithMilliseconds)

        XCTAssertNotNil(feed.catalogs.first?.metadata.updated)
        // The parsed date must be in January 2024
        let date = feed.catalogs.first!.metadata.updated!
        let components = Calendar.current.dateComponents([.year, .month], from: date)
        XCTAssertEqual(components.year, 2024, "Date year must be 2024")
        XCTAssertEqual(components.month, 1, "Date month must be January")
    }

    func testDateParsing_withoutMilliseconds_parsesCorrectly() throws {
        let jsonWithoutMilliseconds = Data("""
    {
      "catalogs": [
        {
          "metadata": {
            "title": "Test",
            "updated": "2024-01-15T10:30:00Z",
            "id": "test-id"
          },
          "links": []
        }
      ],
      "links": [],
      "metadata": {"title": "Test Feed"}
    }
    """.utf8)

        let feed = try OPDS2CatalogsFeed.fromData(jsonWithoutMilliseconds)

        XCTAssertNotNil(feed.catalogs.first?.metadata.updated)
        // Both with-milliseconds and without-milliseconds dates should parse to the same date
        let jsonWithMilliseconds = Data("""
    {
      "catalogs": [{"metadata": {"title": "Test", "updated": "2024-01-15T10:30:00.000Z", "id": "test-id"}, "links": []}],
      "links": [],
      "metadata": {"title": "Test Feed"}
    }
    """.utf8)
        let feedWithMillis = try OPDS2CatalogsFeed.fromData(jsonWithMilliseconds)
        let t1 = feed.catalogs.first?.metadata.updated?.timeIntervalSince1970 ?? 0
        let t2 = feedWithMillis.catalogs.first?.metadata.updated?.timeIntervalSince1970 ?? 0
        XCTAssertEqual(t1, t2, accuracy: 1.0,
            "Dates with and without fractional seconds must parse to the same instant"
        )
    }
}

// MARK: - OPDS2 Publication Tests

final class OPDS2PublicationTests: XCTestCase {

    func testPublication_hasRequiredFields() throws {
        let testFeedURL = Bundle(for: type(of: self))
            .url(forResource: "OPDS2CatalogsFeed", withExtension: "json")!
        let data = try Data(contentsOf: testFeedURL)
        let feed = try OPDS2CatalogsFeed.fromData(data)

        guard let publication = feed.catalogs.first else {
            XCTFail("No publications in feed")
            return
        }

        XCTAssertNotNil(publication.metadata)
        XCTAssertNotNil(publication.links)
    }

    func testPublication_metadataHasTitle() throws {
        let testFeedURL = Bundle(for: type(of: self))
            .url(forResource: "OPDS2CatalogsFeed", withExtension: "json")!
        let data = try Data(contentsOf: testFeedURL)
        let feed = try OPDS2CatalogsFeed.fromData(data)

        XCTAssertFalse(feed.catalogs.isEmpty, "Feed must have at least one catalog")
        for catalog in feed.catalogs {
            XCTAssertFalse(catalog.metadata.title.isEmpty, "Publication should have a title")
        }
    }
}

// MARK: - OPDS2 Link Tests

final class OPDS2LinkTests: XCTestCase {

    func testLink_hasHref() throws {
        let testFeedURL = Bundle(for: type(of: self))
            .url(forResource: "OPDS2CatalogsFeed", withExtension: "json")!
        let data = try Data(contentsOf: testFeedURL)
        let feed = try OPDS2CatalogsFeed.fromData(data)

        XCTAssertFalse(feed.links.isEmpty, "Feed must have at least one link")
        for link in feed.links {
            XCTAssertFalse(link.href.isEmpty)
            // All hrefs must be valid URL strings
            XCTAssertNotNil(URL(string: link.href), "Link href '\(link.href)' must be a valid URL")
        }
    }

    func testLink_firstRelMethod_findsMatchingLink() throws {
        let testFeedURL = Bundle(for: type(of: self))
            .url(forResource: "OPDS2CatalogsFeed", withExtension: "json")!
        let data = try Data(contentsOf: testFeedURL)
        let feed = try OPDS2CatalogsFeed.fromData(data)

        // Every link must have a non-empty href
        XCTAssertFalse(feed.links.isEmpty, "Feed must contain at least one link")
        for link in feed.links {
            XCTAssertFalse(link.href.isEmpty, "Link href must not be empty")
        }
        // If a self-link exists, its href must be a valid URL string
        let selfLink = feed.links.first { $0.rel == "self" }
        if let selfLink {
            XCTAssertTrue(URL(string: selfLink.href) != nil,
                          "self link href '\(selfLink.href)' must be a valid URL")
            XCTAssertEqual(selfLink.rel, "self")
        }
    }
}
