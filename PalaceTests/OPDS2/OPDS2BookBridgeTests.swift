//
//  OPDS2BookBridgeTests.swift
//  PalaceTests
//
//  TDD tests for OPDS2Publication → TPPBook bridge
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class OPDS2BookBridgeTests: XCTestCase {

    // MARK: - Basic Metadata Mapping

    func testToBook_mapsIdentifier() {
        let pub = makePublication(id: "urn:isbn:9780316769174", title: "The Catcher in the Rye")
        let book = pub.toBook()

        XCTAssertNotNil(book)
        XCTAssertEqual(book?.identifier, "urn:isbn:9780316769174")
    }

    func testToBook_mapsTitle() {
        let pub = makePublication(id: "book1", title: "Moby-Dick")
        let book = pub.toBook()

        XCTAssertEqual(book?.title, "Moby-Dick")
    }

    func testToBook_mapsUpdatedDate() {
        let date = Date(timeIntervalSince1970: 1700000000)
        let pub = makePublication(id: "book1", title: "Test", updated: date)
        let book = pub.toBook()

        XCTAssertEqual(book?.updated, date)
    }

    func testToBook_mapsDescription() {
        let pub = makePublication(
            id: "book1",
            title: "Test",
            description: "A great novel about whales."
        )
        let book = pub.toBook()

        XCTAssertEqual(book?.summary, "A great novel about whales.")
    }

    func testToBook_nilDescriptionMapsToNilSummary() {
        let pub = makePublication(id: "book1", title: "Test", description: nil)
        let book = pub.toBook()

        XCTAssertNil(book?.summary)
    }

    // MARK: - Acquisition Link Mapping

    func testToBook_mapsBorrowLink() {
        let links = [
            OPDS2Link(
                href: "https://example.com/borrow",
                type: "application/atom+xml;type=entry;profile=opds-catalog",
                rel: "http://opds-spec.org/acquisition/borrow"
            )
        ]
        let pub = makePublication(id: "book1", title: "Test", links: links)
        let book = pub.toBook()

        XCTAssertNotNil(book)
        XCTAssertEqual(book?.acquisitions.count, 1)
        XCTAssertEqual(book?.acquisitions.first?.relation, .borrow)
        XCTAssertEqual(book?.acquisitions.first?.hrefURL.absoluteString, "https://example.com/borrow")
        XCTAssertEqual(book?.acquisitions.first?.type, "application/atom+xml;type=entry;profile=opds-catalog")
    }

    func testToBook_mapsOpenAccessLink() {
        let links = [
            OPDS2Link(
                href: "https://example.com/download.epub",
                type: "application/epub+zip",
                rel: "http://opds-spec.org/acquisition/open-access"
            )
        ]
        let pub = makePublication(id: "book1", title: "Test", links: links)
        let book = pub.toBook()

        XCTAssertEqual(book?.acquisitions.first?.relation, .openAccess)
        XCTAssertEqual(book?.acquisitions.first?.type, "application/epub+zip")
    }

    func testToBook_mapsGenericAcquisitionLink() {
        let links = [
            OPDS2Link(
                href: "https://example.com/fulfill",
                type: "application/epub+zip",
                rel: "http://opds-spec.org/acquisition"
            )
        ]
        let pub = makePublication(id: "book1", title: "Test", links: links)
        let book = pub.toBook()

        XCTAssertEqual(book?.acquisitions.first?.relation, .generic)
    }

    func testToBook_mapsSampleLink() {
        let links = [
            OPDS2Link(
                href: "https://example.com/sample.epub",
                type: "application/epub+zip",
                rel: "http://opds-spec.org/acquisition/sample"
            )
        ]
        let pub = makePublication(id: "book1", title: "Test", links: links)
        let book = pub.toBook()

        XCTAssertEqual(book?.acquisitions.first?.relation, .sample)
    }

    func testToBook_mapsBuyLink() {
        let links = [
            OPDS2Link(
                href: "https://example.com/buy",
                type: "application/epub+zip",
                rel: "http://opds-spec.org/acquisition/buy"
            )
        ]
        let pub = makePublication(id: "book1", title: "Test", links: links)
        let book = pub.toBook()

        XCTAssertEqual(book?.acquisitions.first?.relation, .buy)
    }

    func testToBook_mapsPreviewLink() {
        let links = [
            OPDS2Link(
                href: "https://example.com/borrow",
                type: "application/epub+zip",
                rel: "http://opds-spec.org/acquisition/borrow"
            ),
            OPDS2Link(
                href: "https://example.com/preview.epub",
                type: "application/epub+zip",
                rel: "preview"
            )
        ]
        let pub = makePublication(id: "book1", title: "Test", links: links)
        let book = pub.toBook()

        XCTAssertNotNil(book?.previewLink)
        XCTAssertEqual(book?.previewLink?.hrefURL.absoluteString, "https://example.com/preview.epub")
    }

    func testToBook_multipleAcquisitionLinks() {
        let links = [
            OPDS2Link(
                href: "https://example.com/borrow",
                type: "application/atom+xml;type=entry;profile=opds-catalog",
                rel: "http://opds-spec.org/acquisition/borrow"
            ),
            OPDS2Link(
                href: "https://example.com/open",
                type: "application/epub+zip",
                rel: "http://opds-spec.org/acquisition/open-access"
            )
        ]
        let pub = makePublication(id: "book1", title: "Test", links: links)
        let book = pub.toBook()

        XCTAssertEqual(book?.acquisitions.count, 2)
    }

    func testToBook_filtersNonAcquisitionLinks() {
        let links = [
            OPDS2Link(
                href: "https://example.com/borrow",
                type: "application/epub+zip",
                rel: "http://opds-spec.org/acquisition/borrow"
            ),
            OPDS2Link(
                href: "https://example.com/related",
                type: "application/opds+json",
                rel: "related"
            ),
            OPDS2Link(
                href: "https://example.com/self",
                type: "application/opds+json",
                rel: "self"
            )
        ]
        let pub = makePublication(id: "book1", title: "Test", links: links)
        let book = pub.toBook()

        XCTAssertEqual(book?.acquisitions.count, 1)
    }

    func testToBook_returnsNilWhenNoAcquisitionLinks() {
        let links = [
            OPDS2Link(
                href: "https://example.com/self",
                type: "application/opds+json",
                rel: "self"
            )
        ]
        let pub = makePublication(id: "book1", title: "Test", links: links)
        let book = pub.toBook()

        XCTAssertNil(book)
    }

    // MARK: - Indirect Acquisition (DRM Chain)

    func testToBook_mapsIndirectAcquisition() {
        let indirectAcq = OPDS2IndirectAcquisition(
            type: "application/vnd.adobe.adept+xml",
            child: [OPDS2IndirectAcquisition(type: "application/epub+zip")]
        )
        let props = OPDS2LinkProperties(indirectAcquisition: [indirectAcq])
        let links = [
            OPDS2Link(
                href: "https://example.com/fulfill",
                type: "application/atom+xml;type=entry;profile=opds-catalog",
                rel: "http://opds-spec.org/acquisition",
                properties: props
            )
        ]
        let pub = makePublication(id: "book1", title: "Test", links: links)
        let book = pub.toBook()

        XCTAssertEqual(book?.acquisitions.first?.indirectAcquisitions.count, 1)
        XCTAssertEqual(book?.acquisitions.first?.indirectAcquisitions.first?.type, "application/vnd.adobe.adept+xml")
        XCTAssertEqual(book?.acquisitions.first?.indirectAcquisitions.first?.indirectAcquisitions.first?.type, "application/epub+zip")
    }

    func testToBook_mapsLCPIndirectAcquisition() {
        let indirectAcq = OPDS2IndirectAcquisition(
            type: "application/epub+zip",
            child: nil
        )
        let props = OPDS2LinkProperties(indirectAcquisition: [indirectAcq])
        let links = [
            OPDS2Link(
                href: "https://example.com/fulfill",
                type: "application/vnd.readium.lcp.license.v1.0+json",
                rel: "http://opds-spec.org/acquisition/borrow",
                properties: props
            )
        ]
        let pub = makePublication(id: "book1", title: "Test", links: links)
        let book = pub.toBook()

        XCTAssertEqual(book?.acquisitions.first?.type, "application/vnd.readium.lcp.license.v1.0+json")
        XCTAssertEqual(book?.acquisitions.first?.indirectAcquisitions.first?.type, "application/epub+zip")
    }

    // MARK: - Availability Mapping

    func testToBook_mapsAvailableState() {
        let props = OPDS2LinkProperties(
            availability: OPDS2Availability(state: "available"),
            copies: OPDS2Copies(total: 5, available: 3)
        )
        let links = [
            OPDS2Link(
                href: "https://example.com/borrow",
                type: "application/epub+zip",
                rel: "http://opds-spec.org/acquisition/borrow",
                properties: props
            )
        ]
        let pub = makePublication(id: "book1", title: "Test", links: links)
        let book = pub.toBook()

        let availability = book?.acquisitions.first?.availability
        XCTAssertNotNil(availability)
        XCTAssertTrue(availability is TPPOPDSAcquisitionAvailabilityLimited)

        let limited = availability as? TPPOPDSAcquisitionAvailabilityLimited
        XCTAssertEqual(limited?.copiesAvailable, 3)
        XCTAssertEqual(limited?.copiesTotal, 5)
    }

    func testToBook_mapsUnavailableState() {
        let props = OPDS2LinkProperties(
            availability: OPDS2Availability(state: "unavailable"),
            copies: OPDS2Copies(total: 5, available: 0),
            holds: OPDS2Holds(total: 10)
        )
        let links = [
            OPDS2Link(
                href: "https://example.com/borrow",
                type: "application/epub+zip",
                rel: "http://opds-spec.org/acquisition/borrow",
                properties: props
            )
        ]
        let pub = makePublication(id: "book1", title: "Test", links: links)
        let book = pub.toBook()

        let availability = book?.acquisitions.first?.availability
        XCTAssertTrue(availability is TPPOPDSAcquisitionAvailabilityUnavailable)

        let unavailable = availability as? TPPOPDSAcquisitionAvailabilityUnavailable
        XCTAssertEqual(unavailable?.copiesTotal, 5)
        XCTAssertEqual(unavailable?.copiesHeld, 10)
    }

    func testToBook_mapsReservedState() {
        let props = OPDS2LinkProperties(
            availability: OPDS2Availability(state: "reserved"),
            copies: OPDS2Copies(total: 5, available: 0),
            holds: OPDS2Holds(total: 8, position: 3)
        )
        let links = [
            OPDS2Link(
                href: "https://example.com/borrow",
                type: "application/epub+zip",
                rel: "http://opds-spec.org/acquisition/borrow",
                properties: props
            )
        ]
        let pub = makePublication(id: "book1", title: "Test", links: links)
        let book = pub.toBook()

        let availability = book?.acquisitions.first?.availability
        XCTAssertTrue(availability is TPPOPDSAcquisitionAvailabilityReserved)

        let reserved = availability as? TPPOPDSAcquisitionAvailabilityReserved
        XCTAssertEqual(reserved?.holdPosition, 3)
        XCTAssertEqual(reserved?.copiesTotal, 5)
    }

    func testToBook_mapsReadyState() {
        let since = Date(timeIntervalSince1970: 1700000000)
        let until = Date(timeIntervalSince1970: 1702000000)
        let props = OPDS2LinkProperties(
            availability: OPDS2Availability(state: "ready", since: since, until: until)
        )
        let links = [
            OPDS2Link(
                href: "https://example.com/borrow",
                type: "application/epub+zip",
                rel: "http://opds-spec.org/acquisition/borrow",
                properties: props
            )
        ]
        let pub = makePublication(id: "book1", title: "Test", links: links)
        let book = pub.toBook()

        let availability = book?.acquisitions.first?.availability
        XCTAssertTrue(availability is TPPOPDSAcquisitionAvailabilityReady)

        let ready = availability as? TPPOPDSAcquisitionAvailabilityReady
        XCTAssertEqual(ready?.since, since)
        XCTAssertEqual(ready?.until, until)
    }

    func testToBook_noAvailabilityDefaultsToUnlimited() {
        let links = [
            OPDS2Link(
                href: "https://example.com/open",
                type: "application/epub+zip",
                rel: "http://opds-spec.org/acquisition/open-access"
            )
        ]
        let pub = makePublication(id: "book1", title: "Test", links: links)
        let book = pub.toBook()

        let availability = book?.acquisitions.first?.availability
        XCTAssertTrue(availability is TPPOPDSAcquisitionAvailabilityUnlimited)
    }

    // MARK: - Image URL Mapping

    func testToBook_mapsImageURLFromImages() {
        let images = [
            OPDS2Link(
                href: "https://example.com/cover.jpg",
                type: "image/jpeg",
                rel: "http://opds-spec.org/image"
            )
        ]
        let pub = makePublication(id: "book1", title: "Test", images: images)
        let book = pub.toBook()

        XCTAssertEqual(book?.imageURL?.absoluteString, "https://example.com/cover.jpg")
    }

    func testToBook_mapsThumbnailURL() {
        let images = [
            OPDS2Link(
                href: "https://example.com/cover.jpg",
                type: "image/jpeg"
            ),
            OPDS2Link(
                href: "https://example.com/thumb.jpg",
                type: "image/jpeg",
                rel: "http://opds-spec.org/image/thumbnail"
            )
        ]
        let pub = makePublication(id: "book1", title: "Test", images: images)
        let book = pub.toBook()

        XCTAssertEqual(book?.imageThumbnailURL?.absoluteString, "https://example.com/thumb.jpg")
    }

    func testToBook_fallsBackToFirstImageWhenNoRelSpecified() {
        let images = [
            OPDS2Link(
                href: "https://example.com/cover.jpg",
                type: "image/jpeg"
            )
        ]
        let pub = makePublication(id: "book1", title: "Test", images: images)
        let book = pub.toBook()

        XCTAssertEqual(book?.imageURL?.absoluteString, "https://example.com/cover.jpg")
    }

    // MARK: - Special Links

    func testToBook_mapsAlternateLink() {
        let links = [
            OPDS2Link(
                href: "https://example.com/borrow",
                type: "application/epub+zip",
                rel: "http://opds-spec.org/acquisition/borrow"
            ),
            OPDS2Link(
                href: "https://example.com/book/detail",
                type: "text/html",
                rel: "alternate"
            )
        ]
        let pub = makePublication(id: "book1", title: "Test", links: links)
        let book = pub.toBook()

        XCTAssertEqual(book?.alternateURL?.absoluteString, "https://example.com/book/detail")
    }

    func testToBook_mapsRelatedWorksLink() {
        let links = [
            OPDS2Link(
                href: "https://example.com/borrow",
                type: "application/epub+zip",
                rel: "http://opds-spec.org/acquisition/borrow"
            ),
            OPDS2Link(
                href: "https://example.com/related",
                type: "application/opds+json",
                rel: "related"
            )
        ]
        let pub = makePublication(id: "book1", title: "Test", links: links)
        let book = pub.toBook()

        XCTAssertEqual(book?.relatedWorksURL?.absoluteString, "https://example.com/related")
    }

    func testToBook_mapsRevokeLink() {
        let links = [
            OPDS2Link(
                href: "https://example.com/borrow",
                type: "application/epub+zip",
                rel: "http://opds-spec.org/acquisition/borrow"
            ),
            OPDS2Link(
                href: "https://example.com/revoke",
                type: "application/atom+xml;type=entry;profile=opds-catalog",
                rel: "http://opds-spec.org/acquisition/revoke"
            )
        ]
        let pub = makePublication(id: "book1", title: "Test", links: links)
        let book = pub.toBook()

        XCTAssertEqual(book?.revokeURL?.absoluteString, "https://example.com/revoke")
    }

    // MARK: - Edge Cases

    func testToBook_handlesEmptyLinksArray() {
        let pub = makePublication(id: "book1", title: "Test", links: [])
        let book = pub.toBook()

        XCTAssertNil(book, "Should return nil when there are no links at all")
    }

    func testToBook_handlesInvalidHrefURL() {
        let links = [
            OPDS2Link(
                href: "",
                type: "application/epub+zip",
                rel: "http://opds-spec.org/acquisition/borrow"
            )
        ]
        let pub = makePublication(id: "book1", title: "Test", links: links)
        let book = pub.toBook()

        XCTAssertNil(book)
    }

    func testToBook_handlesLinkWithNoType() {
        let links = [
            OPDS2Link(
                href: "https://example.com/borrow",
                type: nil,
                rel: "http://opds-spec.org/acquisition/borrow"
            )
        ]
        let pub = makePublication(id: "book1", title: "Test", links: links)
        let book = pub.toBook()

        XCTAssertNotNil(book)
        XCTAssertEqual(book?.acquisitions.count, 1)
    }

    // MARK: - Full Publication (Extended Metadata)

    func testFullPublicationToBook_mapsAuthors() {
        let fullPub = makeFullPublication(
            id: "book1",
            title: "Moby-Dick",
            authors: [OPDS2Contributor(name: "Herman Melville")]
        )
        let book = fullPub.toBook()

        XCTAssertNotNil(book)
        XCTAssertEqual(book?.bookAuthors?.count, 1)
        XCTAssertEqual(book?.bookAuthors?.first?.name, "Herman Melville")
    }

    func testFullPublicationToBook_mapsMultipleAuthors() {
        let fullPub = makeFullPublication(
            id: "book1",
            title: "Good Omens",
            authors: [
                OPDS2Contributor(name: "Terry Pratchett"),
                OPDS2Contributor(name: "Neil Gaiman")
            ]
        )
        let book = fullPub.toBook()

        XCTAssertEqual(book?.bookAuthors?.count, 2)
        XCTAssertEqual(book?.bookAuthors?[0].name, "Terry Pratchett")
        XCTAssertEqual(book?.bookAuthors?[1].name, "Neil Gaiman")
    }

    func testFullPublicationToBook_mapsPublisher() {
        let fullPub = makeFullPublication(
            id: "book1",
            title: "Test",
            publisher: "Penguin Books"
        )
        let book = fullPub.toBook()

        XCTAssertEqual(book?.publisher, "Penguin Books")
    }

    func testFullPublicationToBook_mapsSubtitle() {
        let fullPub = makeFullPublication(
            id: "book1",
            title: "Test",
            subtitle: "A Wonderful Journey"
        )
        let book = fullPub.toBook()

        XCTAssertEqual(book?.subtitle, "A Wonderful Journey")
    }

    func testFullPublicationToBook_mapsPublishedDate() {
        let publishDate = Date(timeIntervalSince1970: 1600000000)
        let fullPub = makeFullPublication(
            id: "book1",
            title: "Test",
            published: publishDate
        )
        let book = fullPub.toBook()

        XCTAssertEqual(book?.published, publishDate)
    }

    func testFullPublicationToBook_mapsNarrators() {
        let fullPub = makeFullPublication(
            id: "book1",
            title: "Test",
            narrators: [OPDS2Contributor(name: "Morgan Freeman")]
        )
        let book = fullPub.toBook()

        let narrators = book?.contributors?["nrt"] as? [String]
        XCTAssertEqual(narrators, ["Morgan Freeman"])
    }

    func testFullPublicationToBook_mapsSubjectsAsCategories() {
        let fullPub = makeFullPublication(
            id: "book1",
            title: "Test",
            subjects: [
                OPDS2Subject(name: "Fiction"),
                OPDS2Subject(name: "Adventure")
            ]
        )
        let book = fullPub.toBook()

        XCTAssertTrue(book?.categoryStrings?.contains("Fiction") == true)
        XCTAssertTrue(book?.categoryStrings?.contains("Adventure") == true)
    }

    func testFullPublicationToBook_mapsDescription() {
        let fullPub = makeFullPublication(
            id: "book1",
            title: "Test",
            description: "An epic tale of the sea."
        )
        let book = fullPub.toBook()

        XCTAssertEqual(book?.summary, "An epic tale of the sea.")
    }

    // MARK: - Bridge Utility Tests

    func testRelationMapping_allStandardRelations() {
        XCTAssertEqual(OPDS2BookBridge.relation(from: "http://opds-spec.org/acquisition"), .generic)
        XCTAssertEqual(OPDS2BookBridge.relation(from: "http://opds-spec.org/acquisition/open-access"), .openAccess)
        XCTAssertEqual(OPDS2BookBridge.relation(from: "http://opds-spec.org/acquisition/borrow"), .borrow)
        XCTAssertEqual(OPDS2BookBridge.relation(from: "http://opds-spec.org/acquisition/buy"), .buy)
        XCTAssertEqual(OPDS2BookBridge.relation(from: "http://opds-spec.org/acquisition/sample"), .sample)
        XCTAssertEqual(OPDS2BookBridge.relation(from: "http://opds-spec.org/acquisition/subscribe"), .subscribe)
        XCTAssertEqual(OPDS2BookBridge.relation(from: "preview"), .sample)
    }

    func testRelationMapping_nonAcquisitionRelReturnsNil() {
        XCTAssertNil(OPDS2BookBridge.relation(from: "self"))
        XCTAssertNil(OPDS2BookBridge.relation(from: "related"))
        XCTAssertNil(OPDS2BookBridge.relation(from: "alternate"))
        XCTAssertNil(OPDS2BookBridge.relation(from: nil))
    }

    func testConvertAvailability_unknownStateDefaultsToUnlimited() {
        let avail = OPDS2BookBridge.convertAvailability(
            availability: OPDS2Availability(state: "some-future-state"),
            copies: nil,
            holds: nil
        )
        XCTAssertTrue(avail is TPPOPDSAcquisitionAvailabilityUnlimited)
    }

    func testConvertAvailability_availableWithoutCopiesIsUnlimited() {
        let avail = OPDS2BookBridge.convertAvailability(
            availability: OPDS2Availability(state: "available"),
            copies: nil,
            holds: nil
        )
        XCTAssertTrue(avail is TPPOPDSAcquisitionAvailabilityUnlimited)
    }

    // MARK: - JSON Round-Trip

    func testToBook_fromDecodedJSON() throws {
        let json = """
        {
          "metadata": {
            "id": "urn:isbn:9780316769174",
            "title": "The Catcher in the Rye",
            "updated": "2026-01-01T00:00:00Z",
            "description": "A classic novel."
          },
          "links": [
            {
              "href": "https://example.com/borrow",
              "rel": "http://opds-spec.org/acquisition/borrow",
              "type": "application/atom+xml;type=entry;profile=opds-catalog",
              "properties": {
                "availability": {"state": "available"},
                "copies": {"total": 10, "available": 3}
              }
            }
          ],
          "images": [
            {"href": "https://example.com/cover.jpg", "type": "image/jpeg"}
          ]
        }
        """

        let data = json.data(using: .utf8)!
        let pub = try OPDS2Feed.makeDecoder().decode(OPDS2Publication.self, from: data)
        let book = pub.toBook()

        XCTAssertNotNil(book)
        XCTAssertEqual(book?.identifier, "urn:isbn:9780316769174")
        XCTAssertEqual(book?.title, "The Catcher in the Rye")
        XCTAssertEqual(book?.summary, "A classic novel.")
        XCTAssertEqual(book?.acquisitions.count, 1)
        XCTAssertEqual(book?.imageURL?.absoluteString, "https://example.com/cover.jpg")
    }

    func testFullPublicationToBook_fromDecodedJSON() throws {
        let json = """
        {
          "metadata": {
            "@id": "urn:isbn:9780140283334",
            "title": "On the Road",
            "author": [{"name": "Jack Kerouac"}],
            "publisher": "Penguin",
            "subject": [{"name": "Fiction"}, {"name": "Beat Literature"}],
            "language": "en",
            "description": "A beat generation classic."
          },
          "links": [
            {
              "href": "https://example.com/borrow",
              "rel": "http://opds-spec.org/acquisition/borrow",
              "type": "application/epub+zip"
            }
          ],
          "images": [
            {"href": "https://example.com/cover.jpg", "type": "image/jpeg"}
          ]
        }
        """

        let data = json.data(using: .utf8)!
        let pub = try OPDS2Feed.makeDecoder().decode(OPDS2FullPublication.self, from: data)
        let book = pub.toBook()

        XCTAssertNotNil(book)
        XCTAssertEqual(book?.identifier, "urn:isbn:9780140283334")
        XCTAssertEqual(book?.title, "On the Road")
        XCTAssertEqual(book?.bookAuthors?.first?.name, "Jack Kerouac")
        XCTAssertEqual(book?.publisher, "Penguin")
        XCTAssertEqual(book?.summary, "A beat generation classic.")
        XCTAssertTrue(book?.categoryStrings?.contains("Fiction") == true)
    }

    // MARK: - Helpers

    private func makePublication(
        id: String = "test-id",
        title: String = "Test Book",
        updated: Date = Date(),
        description: String? = nil,
        links: [OPDS2Link]? = nil,
        images: [OPDS2Link]? = nil
    ) -> OPDS2Publication {
        let acqLinks = links ?? [
            OPDS2Link(
                href: "https://example.com/borrow",
                type: "application/epub+zip",
                rel: "http://opds-spec.org/acquisition/borrow"
            )
        ]
        return OPDS2Publication(
            links: acqLinks,
            metadata: OPDS2Publication.Metadata(
                updated: updated,
                description: description,
                id: id,
                title: title
            ),
            images: images
        )
    }

    private func makeFullPublication(
        id: String = "test-id",
        title: String = "Test Book",
        subtitle: String? = nil,
        published: Date? = nil,
        description: String? = nil,
        authors: [OPDS2Contributor]? = nil,
        publisher: String? = nil,
        narrators: [OPDS2Contributor]? = nil,
        subjects: [OPDS2Subject]? = nil
    ) -> OPDS2FullPublication {
        let metadata = OPDS2FullMetadata(
            identifier: id,
            title: title,
            subtitle: subtitle,
            published: published,
            description: description,
            author: authors,
            narrator: narrators,
            publisher: publisher,
            subject: subjects
        )
        let links = [
            OPDS2Link(
                href: "https://example.com/borrow",
                type: "application/epub+zip",
                rel: "http://opds-spec.org/acquisition/borrow"
            )
        ]
        return OPDS2FullPublication(
            metadata: metadata,
            links: links,
            images: nil
        )
    }
}
