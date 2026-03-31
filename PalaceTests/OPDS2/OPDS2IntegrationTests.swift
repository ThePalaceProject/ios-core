//
//  OPDS2IntegrationTests.swift
//  PalaceTests
//
//  End-to-end integration tests: OPDS2 JSON fixture → OPDS2Feed → TPPBook
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class OPDS2IntegrationTests: XCTestCase {

    private var feed: OPDS2Feed!

    override func setUpWithError() throws {
        let bundle = Bundle(for: type(of: self))
        let url = bundle.url(forResource: "OPDS2CatalogFeed", withExtension: "json", subdirectory: "OPDS2/Fixtures")
            ?? bundle.url(forResource: "OPDS2CatalogFeed", withExtension: "json")
        let data = try XCTUnwrap(url.flatMap { try? Data(contentsOf: $0) }, "Could not load OPDS2CatalogFeed.json fixture")
        feed = try OPDS2Feed.from(data: data)
    }

    // MARK: - Feed Structure

    func testFeedMetadata() {
        XCTAssertEqual(feed.title, "Palace Test Library")
        XCTAssertEqual(feed.metadata.numberOfItems, 150)
        XCTAssertEqual(feed.metadata.itemsPerPage, 20)
        XCTAssertEqual(feed.metadata.currentPage, 1)
    }

    func testFeedIsGrouped() {
        XCTAssertTrue(feed.isGroupedFeed)
        XCTAssertFalse(feed.isNavigationFeed)
    }

    func testFeedLinks() {
        XCTAssertNotNil(feed.selfURL)
        XCTAssertNotNil(feed.nextPageURL)
        XCTAssertNotNil(feed.searchURL)
        XCTAssertNotNil(feed.startURL)
        XCTAssertEqual(feed.nextPageURL?.absoluteString, "https://library.example.com/feed?page=2")
    }

    func testFeedFacets() {
        XCTAssertEqual(feed.facets?.count, 1)
        XCTAssertEqual(feed.facets?.first?.title, "Sort By")
        XCTAssertEqual(feed.facets?.first?.links.count, 3)
    }

    // MARK: - Groups / Lanes

    func testGroupCount() {
        XCTAssertEqual(feed.groups?.count, 3)
    }

    func testNewAndNotableGroup() {
        let group = feed.groups?[0]
        XCTAssertEqual(group?.title, "New & Notable")
        XCTAssertEqual(group?.publications?.count, 2)
        XCTAssertNotNil(group?.moreURL)
    }

    func testPopularAudiobooksGroup() {
        let group = feed.groups?[1]
        XCTAssertEqual(group?.title, "Popular Audiobooks")
        XCTAssertEqual(group?.publications?.count, 1)
    }

    func testStaffPicksGroup() {
        let group = feed.groups?[2]
        XCTAssertEqual(group?.title, "Staff Picks")
        XCTAssertEqual(group?.publications?.count, 2)
    }

    // MARK: - Publication → TPPBook End-to-End

    func testBorrowableBookConversion() {
        let pub = feed.groups?[0].publications?[0]
        XCTAssertEqual(pub?.metadata.title, "The Catcher in the Rye")

        let book = pub?.toBook()
        XCTAssertNotNil(book)
        XCTAssertEqual(book?.identifier, "urn:isbn:9780316769174")
        XCTAssertEqual(book?.title, "The Catcher in the Rye")
        XCTAssertNotNil(book?.summary)

        // Acquisition
        XCTAssertEqual(book?.acquisitions.count, 1)
        XCTAssertEqual(book?.acquisitions.first?.relation, .borrow)

        // Availability (Limited)
        let availability = book?.acquisitions.first?.availability
        XCTAssertTrue(availability is TPPOPDSAcquisitionAvailabilityLimited)
        let limited = availability as? TPPOPDSAcquisitionAvailabilityLimited
        XCTAssertEqual(limited?.copiesAvailable, 2)
        XCTAssertEqual(limited?.copiesTotal, 5)

        // DRM chain
        let indirect = book?.acquisitions.first?.indirectAcquisitions
        XCTAssertEqual(indirect?.count, 1)
        XCTAssertEqual(indirect?.first?.type, "application/vnd.adobe.adept+xml")
        XCTAssertEqual(indirect?.first?.indirectAcquisitions.first?.type, "application/epub+zip")

        // Images
        XCTAssertEqual(book?.imageURL?.absoluteString, "https://library.example.com/covers/9780316769174.jpg")
        XCTAssertEqual(book?.imageThumbnailURL?.absoluteString, "https://library.example.com/thumbs/9780316769174.jpg")

        // Special links
        XCTAssertEqual(book?.alternateURL?.absoluteString, "https://library.example.com/detail/9780316769174")
        XCTAssertEqual(book?.revokeURL?.absoluteString, "https://library.example.com/revoke/9780316769174")
    }

    func testOpenAccessBookConversion() {
        let pub = feed.groups?[0].publications?[1]
        XCTAssertEqual(pub?.metadata.title, "To Kill a Mockingbird")

        let book = pub?.toBook()
        XCTAssertNotNil(book)

        // Has both open-access and sample links
        XCTAssertEqual(book?.acquisitions.count, 2)

        let openAccess = book?.acquisitions.first { $0.relation == .openAccess }
        XCTAssertNotNil(openAccess)
        XCTAssertEqual(openAccess?.type, "application/epub+zip")

        // Availability should be Unlimited (no availability properties)
        XCTAssertTrue(openAccess?.availability is TPPOPDSAcquisitionAvailabilityUnlimited)

        // Image (no explicit rel, falls back to first)
        XCTAssertNotNil(book?.imageURL)
    }

    func testUnavailableAudiobookConversion() {
        let pub = feed.groups?[1].publications?[0]
        XCTAssertEqual(pub?.metadata.title, "Atomic Habits")

        let book = pub?.toBook()
        XCTAssertNotNil(book)

        // Acquisition
        XCTAssertEqual(book?.acquisitions.first?.type, "application/audiobook+json")

        // Availability (Unavailable)
        let availability = book?.acquisitions.first?.availability
        XCTAssertTrue(availability is TPPOPDSAcquisitionAvailabilityUnavailable)
        let unavailable = availability as? TPPOPDSAcquisitionAvailabilityUnavailable
        XCTAssertEqual(unavailable?.copiesTotal, 3)
        XCTAssertEqual(unavailable?.copiesHeld, 12)
    }

    func testReservedBookWithLCPConversion() {
        let pub = feed.groups?[2].publications?[0]
        XCTAssertEqual(pub?.metadata.title, "On the Road")

        let book = pub?.toBook()
        XCTAssertNotNil(book)

        // LCP type
        XCTAssertEqual(book?.acquisitions.first?.type, "application/vnd.readium.lcp.license.v1.0+json")

        // Indirect acquisition (LCP → EPUB)
        XCTAssertEqual(book?.acquisitions.first?.indirectAcquisitions.first?.type, "application/epub+zip")

        // Reserved availability
        let availability = book?.acquisitions.first?.availability
        XCTAssertTrue(availability is TPPOPDSAcquisitionAvailabilityReserved)
        let reserved = availability as? TPPOPDSAcquisitionAvailabilityReserved
        XCTAssertEqual(reserved?.holdPosition, 3)
        XCTAssertEqual(reserved?.copiesTotal, 2)
        XCTAssertNotNil(reserved?.since)
        XCTAssertNotNil(reserved?.until)

        // Preview link
        XCTAssertNotNil(book?.previewLink)
        XCTAssertEqual(book?.previewLink?.hrefURL.absoluteString, "https://library.example.com/preview/9780140283334.epub")
    }

    func testReadyBookConversion() {
        let pub = feed.groups?[2].publications?[1]
        XCTAssertEqual(pub?.metadata.title, "The Wright Brothers")

        let book = pub?.toBook()
        XCTAssertNotNil(book)

        let availability = book?.acquisitions.first?.availability
        XCTAssertTrue(availability is TPPOPDSAcquisitionAvailabilityReady)
        let ready = availability as? TPPOPDSAcquisitionAvailabilityReady
        XCTAssertNotNil(ready?.since)
        XCTAssertNotNil(ready?.until)
    }

    // MARK: - Bulk Conversion (all publications)

    func testAllPublicationsConvertSuccessfully() {
        let allPubs = feed.groups?.flatMap { $0.publications ?? [] } ?? []
        XCTAssertEqual(allPubs.count, 5)

        let books = allPubs.compactMap { $0.toBook() }
        XCTAssertEqual(books.count, 5, "All 5 publications should convert to TPPBook")

        // All have titles
        for book in books {
            XCTAssertFalse(book.title.isEmpty)
        }

        // All have at least one acquisition
        for book in books {
            XCTAssertGreaterThan(book.acquisitions.count, 0)
        }

        // All have identifiers
        let identifiers = Set(books.map { $0.identifier })
        XCTAssertEqual(identifiers.count, 5, "All books should have unique identifiers")
    }

    // MARK: - Format Detection

    func testFormatDetection_JSON() {
        let bundle = Bundle(for: type(of: self))
        let url = bundle.url(forResource: "OPDS2CatalogFeed", withExtension: "json", subdirectory: "OPDS2/Fixtures")
            ?? bundle.url(forResource: "OPDS2CatalogFeed", withExtension: "json")
        let data = try! Data(contentsOf: url!)

        XCTAssertEqual(OPDSFormat.detect(from: data), .opds2)
    }

    func testFormatDetection_XML() {
        let xmlData = "<?xml version=\"1.0\"?><feed></feed>".data(using: .utf8)!
        XCTAssertEqual(OPDSFormat.detect(from: xmlData), .opds1)
    }

    func testFormatDetection_contentType() {
        XCTAssertEqual(OPDSFormat.detect(from: "application/opds+json"), .opds2)
        XCTAssertEqual(OPDSFormat.detect(from: "application/json; charset=utf-8"), .opds2)
        XCTAssertEqual(OPDSFormat.detect(from: "application/atom+xml"), .opds1)
    }

    // MARK: - Full Publication JSON (extended metadata)

    func testFullPublicationFromJSON() throws {
        let json = """
        {
          "metadata": {
            "@id": "urn:isbn:9780735211292",
            "title": "Atomic Habits",
            "subtitle": "An Easy & Proven Way to Build Good Habits & Break Bad Ones",
            "author": [{"name": "James Clear"}],
            "narrator": [{"name": "James Clear"}],
            "publisher": "Avery",
            "published": "2018-10-16T00:00:00Z",
            "language": "en",
            "description": "A supremely practical and useful book.",
            "subject": [
              {"name": "Self-Help"},
              {"name": "Psychology", "scheme": "http://librarysimplified.org/terms/genres/Simplified/"}
            ],
            "duration": 19200,
            "belongsTo": {
              "series": [{"name": "Clear Habits Series", "position": 1}]
            }
          },
          "links": [
            {
              "href": "https://library.example.com/borrow/9780735211292",
              "rel": "http://opds-spec.org/acquisition/borrow",
              "type": "application/audiobook+json",
              "properties": {
                "availability": {"state": "available"},
                "copies": {"total": 3, "available": 1}
              }
            },
            {
              "href": "https://library.example.com/related/9780735211292",
              "rel": "related",
              "type": "application/opds+json"
            },
            {
              "href": "https://library.example.com/timetrack/9780735211292",
              "rel": "http://palaceproject.io/terms/timeTracking",
              "type": "application/json"
            }
          ],
          "images": [
            {
              "href": "https://library.example.com/covers/9780735211292.jpg",
              "type": "image/jpeg",
              "rel": "http://opds-spec.org/image"
            },
            {
              "href": "https://library.example.com/thumbs/9780735211292_sm.jpg",
              "type": "image/jpeg",
              "rel": "http://opds-spec.org/image/thumbnail"
            }
          ]
        }
        """

        let data = json.data(using: .utf8)!
        let fullPub = try OPDS2Feed.makeDecoder().decode(OPDS2FullPublication.self, from: data)
        let book = fullPub.toBook()

        XCTAssertNotNil(book)

        // Basic metadata
        XCTAssertEqual(book?.identifier, "urn:isbn:9780735211292")
        XCTAssertEqual(book?.title, "Atomic Habits")
        XCTAssertEqual(book?.subtitle, "An Easy & Proven Way to Build Good Habits & Break Bad Ones")
        XCTAssertEqual(book?.publisher, "Avery")
        XCTAssertEqual(book?.summary, "A supremely practical and useful book.")

        // Authors
        XCTAssertEqual(book?.bookAuthors?.count, 1)
        XCTAssertEqual(book?.bookAuthors?.first?.name, "James Clear")

        // Narrators
        let narrators = book?.contributors?["nrt"] as? [String]
        XCTAssertEqual(narrators, ["James Clear"])

        // Categories
        XCTAssertTrue(book?.categoryStrings?.contains("Self-Help") == true)
        XCTAssertTrue(book?.categoryStrings?.contains("Psychology") == true)

        // Published date
        XCTAssertNotNil(book?.published)

        // Duration (5h 20m)
        XCTAssertNotNil(book?.bookDuration)

        // Acquisition
        XCTAssertEqual(book?.acquisitions.count, 1)
        XCTAssertEqual(book?.acquisitions.first?.type, "application/audiobook+json")

        let avail = book?.acquisitions.first?.availability as? TPPOPDSAcquisitionAvailabilityLimited
        XCTAssertNotNil(avail)
        XCTAssertEqual(avail?.copiesAvailable, 1)
        XCTAssertEqual(avail?.copiesTotal, 3)

        // Images
        XCTAssertEqual(book?.imageURL?.absoluteString, "https://library.example.com/covers/9780735211292.jpg")
        XCTAssertEqual(book?.imageThumbnailURL?.absoluteString, "https://library.example.com/thumbs/9780735211292_sm.jpg")

        // Special links
        XCTAssertEqual(book?.relatedWorksURL?.absoluteString, "https://library.example.com/related/9780735211292")
        XCTAssertEqual(book?.timeTrackingURL?.absoluteString, "https://library.example.com/timetrack/9780735211292")
    }
}
