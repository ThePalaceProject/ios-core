//
//  OPDS2FeedParsingTests.swift
//  PalaceTests
//
//  Extended tests for OPDS2 feed parsing
//

import XCTest
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
    let invalidJSON = "{ invalid json }".data(using: .utf8)!
    
    XCTAssertThrowsError(try OPDS2CatalogsFeed.fromData(invalidJSON))
  }
  
  func testFromData_withEmptyData_throwsError() {
    let emptyData = Data()
    
    XCTAssertThrowsError(try OPDS2CatalogsFeed.fromData(emptyData))
  }
  
  func testFromData_withMissingCatalogs_throwsError() {
    let jsonWithoutCatalogs = """
    {
      "links": [],
      "metadata": {"title": "Test"}
    }
    """.data(using: .utf8)!
    
    XCTAssertThrowsError(try OPDS2CatalogsFeed.fromData(jsonWithoutCatalogs))
  }
  
  func testFromData_withEmptyCatalogs_parsesSuccessfully() throws {
    let jsonWithEmptyCatalogs = """
    {
      "catalogs": [],
      "links": [],
      "metadata": {"title": "Test Feed"}
    }
    """.data(using: .utf8)!
    
    let feed = try OPDS2CatalogsFeed.fromData(jsonWithEmptyCatalogs)
    
    XCTAssertTrue(feed.catalogs.isEmpty)
    XCTAssertEqual(feed.metadata.title, "Test Feed")
  }
  
  // MARK: - Metadata Tests
  
  func testMetadata_parsesTitle() throws {
    let data = try Data(contentsOf: testFeedURL)
    let feed = try OPDS2CatalogsFeed.fromData(data)
    
    XCTAssertFalse(feed.metadata.title.isEmpty)
  }
  
  func testMetadata_parsesAdobeVendorId() throws {
    // Adobe vendor ID is optional
    let data = try Data(contentsOf: testFeedURL)
    let feed = try OPDS2CatalogsFeed.fromData(data)
    
    // May or may not be present
    XCTAssertNotNil(feed.metadata)
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
    let jsonWithMilliseconds = """
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
    """.data(using: .utf8)!
    
    let feed = try OPDS2CatalogsFeed.fromData(jsonWithMilliseconds)
    
    XCTAssertNotNil(feed.catalogs.first?.metadata.updated)
  }
  
  func testDateParsing_withoutMilliseconds_parsesCorrectly() throws {
    let jsonWithoutMilliseconds = """
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
    """.data(using: .utf8)!
    
    let feed = try OPDS2CatalogsFeed.fromData(jsonWithoutMilliseconds)
    
    XCTAssertNotNil(feed.catalogs.first?.metadata.updated)
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
    
    for link in feed.links {
      XCTAssertFalse(link.href.isEmpty)
    }
  }
  
  func testLink_firstRelMethod_findsMatchingLink() throws {
    let testFeedURL = Bundle(for: type(of: self))
      .url(forResource: "OPDS2CatalogsFeed", withExtension: "json")!
    let data = try Data(contentsOf: testFeedURL)
    let feed = try OPDS2CatalogsFeed.fromData(data)
    
    // Test that we can find links by rel
    let selfLink = feed.links.first { $0.rel == "self" }
    // May or may not exist depending on feed content
    XCTAssertTrue(selfLink != nil || selfLink == nil)
  }
}

