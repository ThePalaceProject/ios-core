//
//  OPDS2FeedTests.swift
//  PalaceTests
//
//  Tests for OPDS2 feed parsing and models
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class OPDS2FeedTests: XCTestCase {
  
  // MARK: - Feed Parsing
  
  func testParseMinimalFeed() throws {
    let json = """
    {
      "metadata": {
        "title": "Test Library"
      },
      "links": [
        {
          "href": "https://example.com/feed",
          "rel": "self",
          "type": "application/opds+json"
        }
      ]
    }
    """
    
    let data = json.data(using: .utf8)!
    let feed = try OPDS2Feed.from(data: data)
    
    XCTAssertEqual(feed.title, "Test Library")
    XCTAssertEqual(feed.links.count, 1)
    XCTAssertEqual(feed.selfURL?.absoluteString, "https://example.com/feed")
  }
  
  func testParseFeedWithNavigation() throws {
    let json = """
    {
      "metadata": {
        "title": "Library Catalog"
      },
      "links": [
        {"href": "https://example.com/catalog", "rel": "self"}
      ],
      "navigation": [
        {"href": "/ebooks", "title": "Ebooks", "type": "application/opds+json"},
        {"href": "/audiobooks", "title": "Audiobooks", "type": "application/opds+json"}
      ]
    }
    """
    
    let data = json.data(using: .utf8)!
    let feed = try OPDS2Feed.from(data: data)
    
    XCTAssertTrue(feed.isNavigationFeed)
    XCTAssertFalse(feed.isPublicationFeed)
    XCTAssertEqual(feed.navigation?.count, 2)
    XCTAssertEqual(feed.navigation?.first?.title, "Ebooks")
  }
  
  func testParseFeedWithPublications() throws {
    let json = """
    {
      "metadata": {
        "title": "Featured Books"
      },
      "links": [
        {"href": "https://example.com/featured", "rel": "self"}
      ],
      "publications": [
        {
          "metadata": {
            "id": "book1",
            "title": "Test Book",
            "updated": "2026-01-01T00:00:00Z"
          },
          "links": [
            {"href": "/book1/manifest", "rel": "http://opds-spec.org/acquisition/open-access", "type": "application/epub+zip"}
          ],
          "images": [
            {"href": "/book1/cover.jpg", "type": "image/jpeg"}
          ]
        }
      ]
    }
    """
    
    let data = json.data(using: .utf8)!
    let feed = try OPDS2Feed.from(data: data)
    
    XCTAssertTrue(feed.isPublicationFeed)
    XCTAssertEqual(feed.publications?.count, 1)
    XCTAssertEqual(feed.publications?.first?.metadata.title, "Test Book")
  }
  
  func testParseFeedWithPagination() throws {
    let json = """
    {
      "metadata": {
        "title": "Search Results",
        "numberOfItems": 100,
        "itemsPerPage": 20,
        "currentPage": 1
      },
      "links": [
        {"href": "https://example.com/search?page=1", "rel": "self"},
        {"href": "https://example.com/search?page=2", "rel": "next"},
        {"href": "https://example.com/catalog", "rel": "start"}
      ]
    }
    """
    
    let data = json.data(using: .utf8)!
    let feed = try OPDS2Feed.from(data: data)
    
    XCTAssertEqual(feed.metadata.numberOfItems, 100)
    XCTAssertEqual(feed.metadata.itemsPerPage, 20)
    XCTAssertNotNil(feed.nextPageURL)
    XCTAssertEqual(feed.nextPageURL?.absoluteString, "https://example.com/search?page=2")
    XCTAssertNotNil(feed.startURL)
  }
  
  func testParseFeedWithGroups() throws {
    let json = """
    {
      "metadata": {"title": "Home"},
      "links": [{"href": "/home", "rel": "self"}],
      "groups": [
        {
          "metadata": {"title": "New Releases"},
          "links": [{"href": "/new", "rel": "self"}],
          "publications": [
            {
              "metadata": {"id": "b1", "title": "New Book", "updated": "2026-01-01T00:00:00Z"},
              "links": [{"href": "/b1", "rel": "http://opds-spec.org/acquisition"}]
            }
          ]
        },
        {
          "metadata": {"title": "Popular"},
          "links": [{"href": "/popular", "rel": "subsection"}],
          "publications": []
        }
      ]
    }
    """
    
    let data = json.data(using: .utf8)!
    let feed = try OPDS2Feed.from(data: data)
    
    XCTAssertTrue(feed.isGroupedFeed)
    XCTAssertEqual(feed.groups?.count, 2)
    XCTAssertEqual(feed.groups?.first?.title, "New Releases")
    XCTAssertEqual(feed.groups?.first?.publications?.count, 1)
    XCTAssertNotNil(feed.groups?[1].moreURL)
  }
  
  func testParseFeedWithFacets() throws {
    let json = """
    {
      "metadata": {"title": "Books"},
      "links": [{"href": "/books", "rel": "self"}],
      "facets": [
        {
          "metadata": {"title": "Sort By"},
          "links": [
            {"href": "/books?sort=title", "title": "Title"},
            {"href": "/books?sort=author", "title": "Author"},
            {"href": "/books?sort=date", "title": "Date Added", "properties": {"numberOfItems": 50}}
          ]
        }
      ]
    }
    """
    
    let data = json.data(using: .utf8)!
    let feed = try OPDS2Feed.from(data: data)
    
    XCTAssertEqual(feed.facets?.count, 1)
    XCTAssertEqual(feed.facets?.first?.title, "Sort By")
    XCTAssertEqual(feed.facets?.first?.links.count, 3)
  }
  
  // MARK: - Link Parsing
  
  func testParseLinkWithProperties() throws {
    let json = """
    {
      "href": "https://example.com/borrow",
      "rel": "http://opds-spec.org/acquisition/borrow",
      "type": "application/vnd.readium.lcp.license.v1.0+json",
      "properties": {
        "availability": {
          "state": "available"
        },
        "copies": {
          "total": 5,
          "available": 2
        },
        "holds": {
          "total": 3,
          "position": 1
        }
      }
    }
    """
    
    let data = json.data(using: .utf8)!
    let link = try JSONDecoder().decode(OPDS2Link.self, from: data)
    
    XCTAssertTrue(link.isBorrow)
    XCTAssertTrue(link.properties?.availability?.isAvailable ?? false)
    XCTAssertEqual(link.properties?.copies?.total, 5)
    XCTAssertEqual(link.properties?.copies?.available, 2)
    XCTAssertEqual(link.properties?.holds?.position, 1)
  }
  
  func testParseLinkWithIndirectAcquisition() throws {
    let json = """
    {
      "href": "https://example.com/fulfill",
      "rel": "http://opds-spec.org/acquisition",
      "type": "application/atom+xml;type=entry;profile=opds-catalog",
      "properties": {
        "indirectAcquisition": [
          {
            "type": "application/vnd.adobe.adept+xml",
            "child": [
              {"type": "application/epub+zip"}
            ]
          }
        ]
      }
    }
    """
    
    let data = json.data(using: .utf8)!
    let link = try JSONDecoder().decode(OPDS2Link.self, from: data)
    
    XCTAssertTrue(link.isAcquisition)
    XCTAssertEqual(link.properties?.indirectAcquisition?.count, 1)
    XCTAssertEqual(link.properties?.indirectAcquisition?.first?.type, "application/vnd.adobe.adept+xml")
    XCTAssertEqual(link.properties?.indirectAcquisition?.first?.child?.first?.type, "application/epub+zip")
  }
  
  // MARK: - Date Parsing
  
  func testParseDateWithFractionalSeconds() throws {
    let json = """
    {
      "metadata": {
        "title": "Test",
        "modified": "2026-01-15T10:30:45.123Z"
      },
      "links": []
    }
    """
    
    let data = json.data(using: .utf8)!
    let feed = try OPDS2Feed.from(data: data)
    
    XCTAssertNotNil(feed.metadata.modified)
  }
  
  func testParseDateWithoutFractionalSeconds() throws {
    let json = """
    {
      "metadata": {
        "title": "Test",
        "modified": "2026-01-15T10:30:45Z"
      },
      "links": []
    }
    """
    
    let data = json.data(using: .utf8)!
    let feed = try OPDS2Feed.from(data: data)
    
    XCTAssertNotNil(feed.metadata.modified)
  }
  
  // MARK: - Format Detection
  
  func testDetectOPDS2FromContentType() {
    XCTAssertEqual(OPDSFormat.detect(from: "application/opds+json"), .opds2)
    XCTAssertEqual(OPDSFormat.detect(from: "application/json"), .opds2)
    XCTAssertEqual(OPDSFormat.detect(from: "application/atom+xml"), .opds1)
    XCTAssertEqual(OPDSFormat.detect(from: "text/xml"), .opds1)
    XCTAssertEqual(OPDSFormat.detect(from: nil), .unknown)
  }
  
  func testDetectOPDS2FromData() {
    let json = "{\"metadata\":{}}".data(using: .utf8)!
    let xml = "<?xml version=\"1.0\"?>".data(using: .utf8)!
    
    XCTAssertEqual(OPDSFormat.detect(from: json), .opds2)
    XCTAssertEqual(OPDSFormat.detect(from: xml), .opds1)
  }
  
  // MARK: - Equatable
  
  func testFeedEquatable() throws {
    let json = """
    {
      "metadata": {"title": "Test"},
      "links": [{"href": "/test", "rel": "self"}]
    }
    """
    
    let data = json.data(using: .utf8)!
    let feed1 = try OPDS2Feed.from(data: data)
    let feed2 = try OPDS2Feed.from(data: data)
    
    XCTAssertEqual(feed1, feed2)
  }
}
