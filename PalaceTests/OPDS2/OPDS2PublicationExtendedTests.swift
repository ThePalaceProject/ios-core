//
//  OPDS2PublicationExtendedTests.swift
//  PalaceTests
//
//  Tests for OPDS2BookBridge conversion utilities and OPDS2FullPublication model.
//  Covers: relation mapping, availability conversion, image URL extraction,
//  special link extraction, indirect acquisition synthesis, and full metadata codability.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class OPDS2PublicationExtendedTests: XCTestCase {

    // MARK: - OPDS2BookBridge.relation(from:) Tests

    func testRelationFromGenericAcquisition() {
        XCTAssertEqual(OPDS2BookBridge.relation(from: "http://opds-spec.org/acquisition"), .generic)
    }

    func testRelationFromOpenAccess() {
        XCTAssertEqual(OPDS2BookBridge.relation(from: "http://opds-spec.org/acquisition/open-access"), .openAccess)
    }

    func testRelationFromBorrow() {
        XCTAssertEqual(OPDS2BookBridge.relation(from: "http://opds-spec.org/acquisition/borrow"), .borrow)
    }

    func testRelationFromBuy() {
        XCTAssertEqual(OPDS2BookBridge.relation(from: "http://opds-spec.org/acquisition/buy"), .buy)
    }

    func testRelationFromSample() {
        XCTAssertEqual(OPDS2BookBridge.relation(from: "http://opds-spec.org/acquisition/sample"), .sample)
    }

    func testRelationFromSubscribe() {
        XCTAssertEqual(OPDS2BookBridge.relation(from: "http://opds-spec.org/acquisition/subscribe"), .subscribe)
    }

    func testRelationFromPreview() {
        XCTAssertEqual(OPDS2BookBridge.relation(from: "preview"), .sample)
    }

    func testRelationFromNonAcquisitionRel() {
        XCTAssertNil(OPDS2BookBridge.relation(from: "alternate"))
        XCTAssertNil(OPDS2BookBridge.relation(from: "self"))
        XCTAssertNil(OPDS2BookBridge.relation(from: nil))
    }

    func testRelationFromRevokeRelIsNil() {
        XCTAssertNil(OPDS2BookBridge.relation(from: "http://opds-spec.org/acquisition/revoke"))
    }

    func testRelationFromIssuesRelIsNil() {
        XCTAssertNil(OPDS2BookBridge.relation(from: "http://opds-spec.org/acquisition/issues"))
    }

    func testRelationFromUnknownAcquisitionSubtype() {
        // Unknown acquisition subtypes that aren't revoke/issues should map to .generic
        XCTAssertEqual(OPDS2BookBridge.relation(from: "http://opds-spec.org/acquisition/custom"), .generic)
    }

    // MARK: - convertAvailability Tests

    func testConvertAvailabilityNil() {
        let result = OPDS2BookBridge.convertAvailability(availability: nil, copies: nil, holds: nil)
        XCTAssertTrue(result is TPPOPDSAcquisitionAvailabilityUnlimited)
    }

    func testConvertAvailabilityUnavailable() {
        let avail = OPDS2Availability(state: "unavailable")
        let holds = OPDS2Holds(total: 5)
        let copies = OPDS2Copies(total: 10)

        let result = OPDS2BookBridge.convertAvailability(availability: avail, copies: copies, holds: holds)
        XCTAssertTrue(result is TPPOPDSAcquisitionAvailabilityUnavailable)
    }

    func testConvertAvailabilityAvailableWithCopies() {
        let avail = OPDS2Availability(state: "available")
        let copies = OPDS2Copies(total: 10, available: 3)

        let result = OPDS2BookBridge.convertAvailability(availability: avail, copies: copies, holds: nil)
        XCTAssertTrue(result is TPPOPDSAcquisitionAvailabilityLimited)
    }

    func testConvertAvailabilityAvailableWithoutCopies() {
        let avail = OPDS2Availability(state: "available")

        let result = OPDS2BookBridge.convertAvailability(availability: avail, copies: nil, holds: nil)
        XCTAssertTrue(result is TPPOPDSAcquisitionAvailabilityUnlimited)
    }

    func testConvertAvailabilityReserved() {
        let avail = OPDS2Availability(state: "reserved")
        let holds = OPDS2Holds(total: 3, position: 2)

        let result = OPDS2BookBridge.convertAvailability(availability: avail, copies: nil, holds: holds)
        XCTAssertTrue(result is TPPOPDSAcquisitionAvailabilityReserved)
    }

    func testConvertAvailabilityReservedWithZeroPosition() {
        let avail = OPDS2Availability(state: "reserved")
        let holds = OPDS2Holds(total: 3, position: 0)

        let result = OPDS2BookBridge.convertAvailability(availability: avail, copies: nil, holds: holds)
        // Position 0 should be clamped to 1
        if let reserved = result as? TPPOPDSAcquisitionAvailabilityReserved {
            XCTAssertEqual(reserved.holdPosition, 1, "Hold position 0 should be clamped to 1")
        } else {
            XCTFail("Expected TPPOPDSAcquisitionAvailabilityReserved")
        }
    }

    func testConvertAvailabilityReady() {
        let since = Date()
        let until = Date().addingTimeInterval(86400)
        let avail = OPDS2Availability(state: "ready", since: since, until: until)

        let result = OPDS2BookBridge.convertAvailability(availability: avail, copies: nil, holds: nil)
        XCTAssertTrue(result is TPPOPDSAcquisitionAvailabilityReady)
    }

    func testConvertAvailabilityUnknownState() {
        let avail = OPDS2Availability(state: "something_else")

        let result = OPDS2BookBridge.convertAvailability(availability: avail, copies: nil, holds: nil)
        XCTAssertTrue(result is TPPOPDSAcquisitionAvailabilityUnlimited,
                       "Unknown state should default to unlimited")
    }

    // MARK: - convertIndirectAcquisitions Tests

    func testConvertIndirectAcquisitionsNil() {
        let result = OPDS2BookBridge.convertIndirectAcquisitions(nil)
        XCTAssertTrue(result.isEmpty)
    }

    func testConvertIndirectAcquisitionsFlat() {
        let indirect = [OPDS2IndirectAcquisition(type: "application/epub+zip")]
        let result = OPDS2BookBridge.convertIndirectAcquisitions(indirect)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.type, "application/epub+zip")
    }

    func testConvertIndirectAcquisitionsNested() {
        let child = OPDS2IndirectAcquisition(type: "application/epub+zip")
        let parent = OPDS2IndirectAcquisition(type: "application/vnd.adobe.adept+xml", child: [child])
        let result = OPDS2BookBridge.convertIndirectAcquisitions([parent])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.type, "application/vnd.adobe.adept+xml")
        XCTAssertEqual(result.first?.indirectAcquisitions.count, 1)
        XCTAssertEqual(result.first?.indirectAcquisitions.first?.type, "application/epub+zip")
    }

    // MARK: - extractImageURLs Tests

    func testExtractImageURLsNil() {
        let (image, thumbnail) = OPDS2BookBridge.extractImageURLs(from: nil)
        XCTAssertNil(image)
        XCTAssertNil(thumbnail)
    }

    func testExtractImageURLsWithExplicitRels() {
        let images = [
            OPDS2Link(href: "https://example.com/cover.jpg", rel: "http://opds-spec.org/image"),
            OPDS2Link(href: "https://example.com/thumb.jpg", rel: "http://opds-spec.org/image/thumbnail")
        ]
        let (image, thumbnail) = OPDS2BookBridge.extractImageURLs(from: images)

        XCTAssertEqual(image?.absoluteString, "https://example.com/cover.jpg")
        XCTAssertEqual(thumbnail?.absoluteString, "https://example.com/thumb.jpg")
    }

    func testExtractImageURLsFallsBackToFirstImage() {
        let images = [
            OPDS2Link(href: "https://example.com/only-image.jpg")
        ]
        let (image, thumbnail) = OPDS2BookBridge.extractImageURLs(from: images)

        XCTAssertEqual(image?.absoluteString, "https://example.com/only-image.jpg")
        XCTAssertNil(thumbnail)
    }

    // MARK: - extractSpecialLinks Tests

    func testExtractSpecialLinks() {
        let links = [
            OPDS2Link(href: "https://example.com/alt", rel: "alternate"),
            OPDS2Link(href: "https://example.com/related", rel: "related"),
            OPDS2Link(href: "https://example.com/revoke", rel: "http://opds-spec.org/acquisition/revoke"),
            OPDS2Link(href: "https://example.com/issues", rel: "issues"),
            OPDS2Link(href: "https://example.com/annotations", rel: "http://www.w3.org/ns/oa#annotationService"),
            OPDS2Link(href: "https://example.com/time", rel: "http://palaceproject.io/terms/timeTracking"),
        ]

        let result = OPDS2BookBridge.extractSpecialLinks(from: links)

        XCTAssertEqual(result.alternate?.absoluteString, "https://example.com/alt")
        XCTAssertEqual(result.related?.absoluteString, "https://example.com/related")
        XCTAssertEqual(result.revoke?.absoluteString, "https://example.com/revoke")
        XCTAssertEqual(result.report?.absoluteString, "https://example.com/issues")
        XCTAssertEqual(result.annotations?.absoluteString, "https://example.com/annotations")
        XCTAssertEqual(result.timeTracking?.absoluteString, "https://example.com/time")
        // analytics is derived from alternate
        XCTAssertEqual(result.analytics?.absoluteString, "https://example.com/alt")
    }

    func testExtractSpecialLinksEmpty() {
        let result = OPDS2BookBridge.extractSpecialLinks(from: [])

        XCTAssertNil(result.alternate)
        XCTAssertNil(result.related)
        XCTAssertNil(result.revoke)
        XCTAssertNil(result.report)
        XCTAssertNil(result.annotations)
        XCTAssertNil(result.analytics)
        XCTAssertNil(result.timeTracking)
    }

    // MARK: - convertAcquisition Tests

    func testConvertAcquisitionFromBorrowLink() {
        let link = OPDS2Link(
            href: "https://example.com/borrow",
            type: "application/atom+xml;type=entry;profile=opds-catalog",
            rel: "http://opds-spec.org/acquisition/borrow"
        )

        let acq = OPDS2BookBridge.convertAcquisition(from: link)

        XCTAssertNotNil(acq)
        XCTAssertEqual(acq?.relation, .borrow)
        XCTAssertEqual(acq?.hrefURL.absoluteString, "https://example.com/borrow")
    }

    func testConvertAcquisitionFromNonAcquisitionLink() {
        let link = OPDS2Link(
            href: "https://example.com/info",
            type: "text/html",
            rel: "alternate"
        )

        let acq = OPDS2BookBridge.convertAcquisition(from: link)
        XCTAssertNil(acq, "Non-acquisition links should return nil")
    }

    func testConvertAcquisitionSynthesizesIndirectForBearerToken() {
        let link = OPDS2Link(
            href: "https://example.com/fulfill",
            type: "application/vnd.librarysimplified.bearer-token+json",
            rel: "http://opds-spec.org/acquisition/open-access"
        )

        let acq = OPDS2BookBridge.convertAcquisition(from: link)

        XCTAssertNotNil(acq)
        XCTAssertFalse(acq!.indirectAcquisitions.isEmpty,
                        "Should synthesize indirect acquisitions for bearer-token type")

        let types = acq!.indirectAcquisitions.map { $0.type }
        XCTAssertTrue(types.contains("application/epub+zip"))
        XCTAssertTrue(types.contains("application/pdf"))
        XCTAssertTrue(types.contains("application/audiobook+json"))
    }

    func testConvertAcquisitionSynthesizesIndirectForLCP() {
        let link = OPDS2Link(
            href: "https://example.com/lcp",
            type: "application/vnd.readium.lcp.license.v1.0+json",
            rel: "http://opds-spec.org/acquisition/open-access"
        )

        let acq = OPDS2BookBridge.convertAcquisition(from: link)

        XCTAssertNotNil(acq)
        let types = acq!.indirectAcquisitions.map { $0.type }
        XCTAssertTrue(types.contains("application/epub+zip"))
        XCTAssertTrue(types.contains("application/pdf"))
        XCTAssertTrue(types.contains("application/audiobook+lcp"))
    }

    func testConvertAcquisitionWithExplicitIndirectAcquisitions() {
        let properties = OPDS2LinkProperties(
            indirectAcquisition: [OPDS2IndirectAcquisition(type: "application/epub+zip")]
        )
        let link = OPDS2Link(
            href: "https://example.com/borrow",
            type: "application/atom+xml;type=entry;profile=opds-catalog",
            rel: "http://opds-spec.org/acquisition/borrow",
            properties: properties
        )

        let acq = OPDS2BookBridge.convertAcquisition(from: link)

        XCTAssertNotNil(acq)
        XCTAssertEqual(acq!.indirectAcquisitions.count, 1)
        XCTAssertEqual(acq!.indirectAcquisitions.first?.type, "application/epub+zip")
    }

    // MARK: - OPDS2FullPublication Tests

    func testFullPublicationImageURLs() {
        let pub = OPDS2FullPublication(
            metadata: makeMinimalMetadata(),
            links: [],
            images: [
                OPDS2Link(href: "https://example.com/cover.jpg", rel: "http://opds-spec.org/image"),
                OPDS2Link(href: "https://example.com/thumb.jpg", width: 100),
            ]
        )

        XCTAssertEqual(pub.imageURL?.absoluteString, "https://example.com/cover.jpg")
        XCTAssertEqual(pub.thumbnailURL?.absoluteString, "https://example.com/thumb.jpg")
    }

    func testFullPublicationAcquisitionLinks() {
        let pub = OPDS2FullPublication(
            metadata: makeMinimalMetadata(),
            links: [
                OPDS2Link(href: "https://example.com/borrow", rel: "http://opds-spec.org/acquisition/borrow"),
                OPDS2Link(href: "https://example.com/info", rel: "alternate"),
            ],
            images: nil
        )

        XCTAssertEqual(pub.acquisitionLinks.count, 1)
        XCTAssertNotNil(pub.borrowLink)
        XCTAssertNil(pub.openAccessLink)
    }

    func testFullPublicationContentType() {
        let audiobookPub = OPDS2FullPublication(
            metadata: makeMinimalMetadata(),
            links: [
                OPDS2Link(href: "https://example.com/borrow", type: "application/audiobook+json", rel: "http://opds-spec.org/acquisition/borrow"),
            ],
            images: nil
        )

        XCTAssertTrue(audiobookPub.isAudiobook)
        XCTAssertFalse(audiobookPub.isEPUB)
        XCTAssertFalse(audiobookPub.isPDF)

        let epubPub = OPDS2FullPublication(
            metadata: makeMinimalMetadata(),
            links: [
                OPDS2Link(href: "https://example.com/borrow", type: "application/epub+zip", rel: "http://opds-spec.org/acquisition/open-access"),
            ],
            images: nil
        )

        XCTAssertFalse(epubPub.isAudiobook)
        XCTAssertTrue(epubPub.isEPUB)
    }

    func testFullPublicationId() {
        let metadata = makeMinimalMetadata(identifier: "urn:isbn:1234567890")
        let pub = OPDS2FullPublication(metadata: metadata, links: [], images: nil)

        XCTAssertEqual(pub.id, "urn:isbn:1234567890")
    }

    // MARK: - OPDS2FullMetadata Codable Tests

    func testFullMetadataCodableRoundTrip() throws {
        let metadata = OPDS2FullMetadata(
            identifier: "urn:test:123",
            title: "Test Book",
            subtitle: "A Subtitle",
            language: "en",
            description: "A test description",
            author: [OPDS2Contributor(name: "Jane Author")],
            publisher: "Test Publisher",
            subject: [OPDS2Subject(name: "Fiction")],
            duration: 3600,
            numberOfPages: 250
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(metadata)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(OPDS2FullMetadata.self, from: data)

        XCTAssertEqual(decoded.identifier, "urn:test:123")
        XCTAssertEqual(decoded.title, "Test Book")
        XCTAssertEqual(decoded.subtitle, "A Subtitle")
        XCTAssertEqual(decoded.language, "en")
        XCTAssertEqual(decoded.description, "A test description")
        XCTAssertEqual(decoded.author?.first?.name, "Jane Author")
        XCTAssertEqual(decoded.publisher, "Test Publisher")
        XCTAssertEqual(decoded.subject?.first?.name, "Fiction")
        XCTAssertEqual(decoded.duration, 3600)
        XCTAssertEqual(decoded.numberOfPages, 250)
    }

    func testFullMetadataDecodesWithAlternateIdKey() throws {
        let json = """
        {
            "id": "fallback-id",
            "title": "Fallback Test"
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(OPDS2FullMetadata.self, from: json)
        XCTAssertEqual(decoded.identifier, "fallback-id")
        XCTAssertEqual(decoded.title, "Fallback Test")
    }

    func testFullMetadataDecodesWithMissingIdentifier() throws {
        let json = """
        {
            "title": "No ID Book"
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(OPDS2FullMetadata.self, from: json)
        // Should generate a UUID
        XCTAssertFalse(decoded.identifier.isEmpty)
        XCTAssertEqual(decoded.title, "No ID Book")
    }

    // MARK: - OPDS2Contributor Codable Tests

    func testContributorDecodesFromString() throws {
        let json = "\"John Smith\"".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(OPDS2Contributor.self, from: json)

        XCTAssertEqual(decoded.name, "John Smith")
        XCTAssertNil(decoded.sortAs)
        XCTAssertNil(decoded.identifier)
    }

    func testContributorDecodesFromObject() throws {
        let json = """
        {
            "name": "Jane Doe",
            "sortAs": "Doe, Jane",
            "identifier": "urn:author:jane"
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(OPDS2Contributor.self, from: json)

        XCTAssertEqual(decoded.name, "Jane Doe")
        XCTAssertEqual(decoded.sortAs, "Doe, Jane")
        XCTAssertEqual(decoded.identifier, "urn:author:jane")
    }

    // MARK: - OPDS2Subject Codable Tests

    func testSubjectDecodesFromString() throws {
        let json = "\"Science Fiction\"".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(OPDS2Subject.self, from: json)

        XCTAssertEqual(decoded.name, "Science Fiction")
        XCTAssertNil(decoded.scheme)
        XCTAssertNil(decoded.code)
    }

    func testSubjectDecodesFromObject() throws {
        let json = """
        {
            "name": "Fiction",
            "scheme": "http://librarysimplified.org/terms/genres/Simplified/",
            "code": "FIC000000"
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(OPDS2Subject.self, from: json)

        XCTAssertEqual(decoded.name, "Fiction")
        XCTAssertEqual(decoded.scheme, "http://librarysimplified.org/terms/genres/Simplified/")
        XCTAssertEqual(decoded.code, "FIC000000")
    }

    // MARK: - Duration Formatting in toBook

    func testFullPublicationDurationFormatting() {
        // 2 hours 30 minutes = 9000 seconds
        let metadata = OPDS2FullMetadata(
            identifier: "urn:test:duration",
            title: "Long Audiobook",
            duration: 9000
        )
        let pub = OPDS2FullPublication(
            metadata: metadata,
            links: [
                OPDS2Link(
                    href: "https://example.com/borrow",
                    type: "application/audiobook+json",
                    rel: "http://opds-spec.org/acquisition/borrow"
                )
            ],
            images: nil
        )

        let book = pub.toBook()
        XCTAssertNotNil(book)
        XCTAssertEqual(book?.bookDuration, "2:30:00")
    }

    func testFullPublicationDurationFormattingSubHour() {
        // 45 minutes = 2700 seconds
        let metadata = OPDS2FullMetadata(
            identifier: "urn:test:short",
            title: "Short Audiobook",
            duration: 2700
        )
        let pub = OPDS2FullPublication(
            metadata: metadata,
            links: [
                OPDS2Link(
                    href: "https://example.com/borrow",
                    type: "application/audiobook+json",
                    rel: "http://opds-spec.org/acquisition/borrow"
                )
            ],
            images: nil
        )

        let book = pub.toBook()
        XCTAssertEqual(book?.bookDuration, "45:00")
    }

    func testFullPublicationToBookReturnsNilWithNoAcquisitions() {
        let pub = OPDS2FullPublication(
            metadata: makeMinimalMetadata(),
            links: [
                OPDS2Link(href: "https://example.com/info", rel: "alternate"),
            ],
            images: nil
        )

        XCTAssertNil(pub.toBook(), "toBook should return nil if no acquisition links exist")
    }

    // MARK: - Helpers

    private func makeMinimalMetadata(identifier: String = "urn:test:minimal") -> OPDS2FullMetadata {
        OPDS2FullMetadata(identifier: identifier, title: "Minimal Book")
    }
}
