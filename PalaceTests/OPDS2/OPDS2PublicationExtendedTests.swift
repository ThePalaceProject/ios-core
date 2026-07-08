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
import PalaceCatalog
@testable import Palace

final class OPDS2PublicationExtendedTests: XCTestCase {

    // MARK: - OPDS2BookBridge.relation(from:) Tests

    func testRelationFromGenericAcquisition() {
        XCTAssertEqual(OPDS2BookBridge.relation(from: "http://opds-spec.org/acquisition"), .generic)
        // Must differ from all non-generic relation types
        XCTAssertNotEqual(TPPOPDSAcquisitionRelation.generic, .borrow)
        XCTAssertNotEqual(TPPOPDSAcquisitionRelation.generic, .openAccess)
    }

    func testRelationFromOpenAccess() {
        XCTAssertEqual(OPDS2BookBridge.relation(from: "http://opds-spec.org/acquisition/open-access"), .openAccess)
        // open-access and borrow are distinct relations
        XCTAssertNotEqual(TPPOPDSAcquisitionRelation.openAccess, .borrow)
        XCTAssertNotEqual(TPPOPDSAcquisitionRelation.openAccess, .generic)
    }

    func testRelationFromBorrow() {
        XCTAssertEqual(OPDS2BookBridge.relation(from: "http://opds-spec.org/acquisition/borrow"), .borrow)
        // borrow must map to the right enum case and not to buy or sample
        XCTAssertNotEqual(TPPOPDSAcquisitionRelation.borrow, .buy)
        XCTAssertNotEqual(TPPOPDSAcquisitionRelation.borrow, .sample)
    }

    func testRelationFromBuy() {
        XCTAssertEqual(OPDS2BookBridge.relation(from: "http://opds-spec.org/acquisition/buy"), .buy)
        XCTAssertNotEqual(TPPOPDSAcquisitionRelation.buy, .borrow)
        XCTAssertNotEqual(TPPOPDSAcquisitionRelation.buy, .openAccess)
    }

    func testRelationFromSample() {
        XCTAssertEqual(OPDS2BookBridge.relation(from: "http://opds-spec.org/acquisition/sample"), .sample)
        // "sample" rel and "preview" rel must both map to .sample
        XCTAssertEqual(OPDS2BookBridge.relation(from: "preview"), .sample)
        XCTAssertNotEqual(TPPOPDSAcquisitionRelation.sample, .borrow)
    }

    func testRelationFromSubscribe() {
        XCTAssertEqual(OPDS2BookBridge.relation(from: "http://opds-spec.org/acquisition/subscribe"), .subscribe)
        XCTAssertNotEqual(TPPOPDSAcquisitionRelation.subscribe, .borrow)
        XCTAssertNotEqual(TPPOPDSAcquisitionRelation.subscribe, .buy)
    }

    func testRelationFromPreview() {
        XCTAssertEqual(OPDS2BookBridge.relation(from: "preview"), .sample)
        // Verify consistency: "preview" and "sample" rel both map to the same enum case
        XCTAssertEqual(
            OPDS2BookBridge.relation(from: "preview"),
            OPDS2BookBridge.relation(from: "http://opds-spec.org/acquisition/sample"),
            "preview and sample rels must map to the same relation"
        )
    }

    func testRelationFromNonAcquisitionRel() {
        XCTAssertNil(OPDS2BookBridge.relation(from: "alternate"))
        XCTAssertNil(OPDS2BookBridge.relation(from: "self"))
        XCTAssertNil(OPDS2BookBridge.relation(from: nil))
    }

    func testRelationFromRevokeRelIsNil() {
        XCTAssertNil(OPDS2BookBridge.relation(from: "http://opds-spec.org/acquisition/revoke"))
        // Revoke must not map to any acquisition relation
        XCTAssertNil(OPDS2BookBridge.relation(from: "http://opds-spec.org/acquisition/revoke"),
                     "Revoke rel must consistently return nil")
    }

    func testRelationFromIssuesRelIsNil() {
        XCTAssertNil(OPDS2BookBridge.relation(from: "http://opds-spec.org/acquisition/issues"))
        // Issues and revoke must both be nil (they are excluded from acquisition relations)
        XCTAssertNil(OPDS2BookBridge.relation(from: "http://opds-spec.org/acquisition/revoke"),
                     "Revoke and issues must both return nil")
    }

    func testRelationFromUnknownAcquisitionSubtype() {
        // Unknown acquisition subtypes that aren't revoke/issues should map to .generic
        XCTAssertEqual(OPDS2BookBridge.relation(from: "http://opds-spec.org/acquisition/custom"), .generic)
        // Multiple unknown subtypes must all map to .generic
        XCTAssertEqual(OPDS2BookBridge.relation(from: "http://opds-spec.org/acquisition/special"), .generic,
                       "Any unknown acquisition subtype must map to .generic")
    }

    // MARK: - convertAvailability Tests

    func testConvertAvailabilityNil() {
        let result = OPDS2BookBridge.convertAvailability(availability: nil, copies: nil, holds: nil)
        XCTAssertTrue(result is TPPOPDSAcquisitionAvailabilityUnlimited)
        XCTAssertFalse(result is TPPOPDSAcquisitionAvailabilityLimited)
        XCTAssertFalse(result is TPPOPDSAcquisitionAvailabilityUnavailable)
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
        XCTAssertTrue(result is TPPOPDSAcquisitionAvailabilityLimited,
                      "available + copies → Limited")
        // The Limited variant must NOT be a Reserved or Unavailable instance —
        // those are distinct states from "available with copies".
        XCTAssertFalse(result is TPPOPDSAcquisitionAvailabilityReserved,
                       "available + copies must not classify as Reserved")
        XCTAssertFalse(result is TPPOPDSAcquisitionAvailabilityUnavailable,
                       "available + copies must not classify as Unavailable")
    }

    func testConvertAvailabilityAvailableWithoutCopies() {
        let avail = OPDS2Availability(state: "available")

        let result = OPDS2BookBridge.convertAvailability(availability: avail, copies: nil, holds: nil)
        XCTAssertTrue(result is TPPOPDSAcquisitionAvailabilityUnlimited)
        // Without copy counts, the resource must be freely available (unlimited)
        XCTAssertFalse(result is TPPOPDSAcquisitionAvailabilityLimited,
                       "Available state with no copies must not be Limited")
    }

    func testConvertAvailabilityReserved() {
        let avail = OPDS2Availability(state: "reserved")
        let holds = OPDS2Holds(total: 3, position: 2)

        let result = OPDS2BookBridge.convertAvailability(availability: avail, copies: nil, holds: holds)
        XCTAssertTrue(result is TPPOPDSAcquisitionAvailabilityReserved)
        // The hold position must be preserved
        let reserved = result as? TPPOPDSAcquisitionAvailabilityReserved
        XCTAssertEqual(reserved?.holdPosition, 2, "Hold position must be preserved from OPDS2Holds")
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
        // Try several distinct unknown state strings — all must default to
        // Unlimited (the failsafe/permissive choice). A mutant that defaults
        // to Unavailable would block the user from acquiring a book whose
        // state we simply don't recognize.
        for state in ["something_else", "futureState", "garbage_value", ""] {
            let avail = OPDS2Availability(state: state)
            let result = OPDS2BookBridge.convertAvailability(
                availability: avail, copies: nil, holds: nil)
            XCTAssertTrue(result is TPPOPDSAcquisitionAvailabilityUnlimited,
                          "Unknown state '\(state)' must default to Unlimited (the permissive choice)")
            XCTAssertFalse(result is TPPOPDSAcquisitionAvailabilityUnavailable,
                           "Unknown state '\(state)' must NOT default to Unavailable — that would block the user")
        }
    }

    // MARK: - convertIndirectAcquisitions Tests

    /// `convertIndirectAcquisitions(nil)` and `convertIndirectAcquisitions([])`
    /// must both yield an empty result without crashing. Pin both shapes.
    /// A mutant that returned a single empty placeholder on nil would fail
    /// the count assertion.
    func testConvertIndirectAcquisitions_nilOrEmptyInputYieldsEmptyResult() {
        XCTAssertTrue(OPDS2BookBridge.convertIndirectAcquisitions(nil).isEmpty,
                      "nil input must yield empty array")
        XCTAssertEqual(OPDS2BookBridge.convertIndirectAcquisitions(nil).count, 0,
                       "nil input must yield exactly zero entries — guards a placeholder-on-nil mutant")
        XCTAssertTrue(OPDS2BookBridge.convertIndirectAcquisitions([]).isEmpty,
                      "Empty input array must yield empty result")
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

    /// `OPDS2FullPublication.id` delegates to `metadata.identifier`. Lock
    /// distinct ids across two instances to catch a mutant that returns a
    /// hard-coded constant from `id`. Identifiable-instance distinctness
    /// matters for SwiftUI list diffing.
    func testFullPublicationId_delegatesToMetadataIdentifierAcrossInstances() {
        let pubA = OPDS2FullPublication(
            metadata: makeMinimalMetadata(identifier: "urn:isbn:1234567890"),
            links: [], images: nil)
        let pubB = OPDS2FullPublication(
            metadata: makeMinimalMetadata(identifier: "urn:isbn:0987654321"),
            links: [], images: nil)

        XCTAssertEqual(pubA.id, "urn:isbn:1234567890")
        XCTAssertEqual(pubB.id, "urn:isbn:0987654321")
        XCTAssertNotEqual(pubA.id, pubB.id,
                          "Distinct metadata identifiers must yield distinct ids — guards a constant-return mutant on `id`")
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

    // MARK: - Series Metadata (PP-4463)

    /// PP-4463: when an OPDS2 publication carries `belongsTo.series[]`,
    /// `OPDS2FullPublication.toBook()` must surface the first series's name
    /// and the href of its first link onto the resulting `TPPBook`. The Book
    /// Detail SERIES row keys off both fields; dropping either hides the row.
    func testFullPublication_seriesNameAndURL_extractedFromBelongsTo() {
        let seriesLink = OPDS2Link(href: "https://example.com/series/foundation")
        let series = OPDS2Collection(name: "Foundation", links: [seriesLink])
        let metadata = OPDS2FullMetadata(
            identifier: "urn:test:series",
            title: "Foundation: Book 1",
            belongsTo: OPDS2BelongsTo(series: [series])
        )
        let pub = OPDS2FullPublication(
            metadata: metadata,
            links: [
                OPDS2Link(
                    href: "https://example.com/borrow",
                    type: "application/epub+zip",
                    rel: "http://opds-spec.org/acquisition/borrow"
                )
            ],
            images: nil
        )

        let book = pub.toBook()

        XCTAssertEqual(book?.seriesName, "Foundation",
                       "Series name from belongsTo.series.first.name must reach TPPBook.seriesName")
        XCTAssertEqual(book?.seriesURL?.absoluteString,
                       "https://example.com/series/foundation",
                       "Series link href from belongsTo.series.first.links.first must reach TPPBook.seriesURL")
    }

    func testFullPublication_seriesNil_whenBelongsToAbsent() {
        let pub = OPDS2FullPublication(
            metadata: makeMinimalMetadata(),
            links: [
                OPDS2Link(
                    href: "https://example.com/borrow",
                    type: "application/epub+zip",
                    rel: "http://opds-spec.org/acquisition/borrow"
                )
            ],
            images: nil
        )

        let book = pub.toBook()

        XCTAssertNil(book?.seriesName,
                     "seriesName must be nil when belongsTo is absent — guards against a mutant that defaults to empty string")
        XCTAssertNil(book?.seriesURL,
                     "seriesURL must be nil when belongsTo is absent")
    }

    /// `OPDS2BelongsTo.series` is `[OPDS2Collection]?` — the toBook conversion
    /// picks the FIRST entry. Pin that contract: if a feed somehow ships an
    /// empty series array, the row stays hidden rather than crashing.
    func testFullPublication_seriesNil_whenBelongsToSeriesEmpty() {
        let metadata = OPDS2FullMetadata(
            identifier: "urn:test:empty-series",
            title: "Standalone",
            belongsTo: OPDS2BelongsTo(series: [])
        )
        let pub = OPDS2FullPublication(
            metadata: metadata,
            links: [
                OPDS2Link(
                    href: "https://example.com/borrow",
                    type: "application/epub+zip",
                    rel: "http://opds-spec.org/acquisition/borrow"
                )
            ],
            images: nil
        )

        let book = pub.toBook()

        XCTAssertNil(book?.seriesName,
                     "Empty belongsTo.series array must yield nil seriesName, not a crash")
        XCTAssertNil(book?.seriesURL)
    }

    /// A series may exist with no navigation link (rare but valid per spec).
    /// In that case `seriesName` is populated but `seriesURL` is nil, which
    /// the Book Detail view's render predicate treats as "hide the row" —
    /// there's no destination to navigate to.
    func testFullPublication_seriesNameOnly_whenLinksAbsent() {
        let series = OPDS2Collection(name: "Mystery Series", links: nil)
        let metadata = OPDS2FullMetadata(
            identifier: "urn:test:nolink",
            title: "Unlinked Series Title",
            belongsTo: OPDS2BelongsTo(series: [series])
        )
        let pub = OPDS2FullPublication(
            metadata: metadata,
            links: [
                OPDS2Link(
                    href: "https://example.com/borrow",
                    type: "application/epub+zip",
                    rel: "http://opds-spec.org/acquisition/borrow"
                )
            ],
            images: nil
        )

        let book = pub.toBook()

        XCTAssertEqual(book?.seriesName, "Mystery Series",
                       "seriesName must still extract from the collection even when links is nil")
        XCTAssertNil(book?.seriesURL,
                     "seriesURL must be nil when the series collection carries no links")
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

    // MARK: - PP-4161: Streaming-HTML pass-through (both toBook sites)

    /// PP-4161: lightweight `OPDS2Publication.toBook()` must NOT drop a
    /// publication whose only acquisition leaf is the LibrarySimplified
    /// streaming-media MIME. Pre-fix, the `hasOpenablePath` guard
    /// (lines 270-282) rejected streaming-media because
    /// `TPPOPDSAcquisitionPath.supportedTypes()` excluded it. This test
    /// fails until Module A adds `ContentTypeStreamingHTML` to
    /// `supportedTypes()` + the `supportedSubtypes(forType: ContentTypeOPDSPublication)`
    /// leaf set in PalaceCatalog — proving the filter behaviour, not the
    /// production-code edit at the filter site (which is generic).
    func testOPDS2Publication_toBook_streamingMediaOnlyAcquisition_doesNotDrop() {
        let indirect = OPDS2IndirectAcquisition(
            type: ContentTypeStreamingHTML,
            child: nil
        )
        let link = OPDS2Link(
            href: "https://example.com/borrow/streaming",
            type: ContentTypeOPDSPublication,
            rel: "http://opds-spec.org/acquisition/borrow",
            properties: OPDS2LinkProperties(indirectAcquisition: [indirect])
        )
        let metadata = OPDS2Publication.Metadata(
            id: "urn:uuid:84dac408-77ce-4afc-8393-9e0ced7ea3ef",
            title: "Streaming-HTML Test Publication"
        )
        let publication = OPDS2Publication(
            links: [link],
            metadata: metadata,
            images: nil
        )

        let book = publication.toBook()

        XCTAssertNotNil(book,
                        "Streaming-media-only publications must NOT be dropped by the hasOpenablePath filter once supportedTypes() includes ContentTypeStreamingHTML")
        XCTAssertEqual(book?.identifier,
                       "urn:uuid:84dac408-77ce-4afc-8393-9e0ced7ea3ef",
                       "Identifier must round-trip through toBook unchanged")
        XCTAssertEqual(book?.defaultBookContentType, .streamingHTML,
                       "Resulting TPPBook must report .streamingHTML so Book Detail routes to the streaming reader")
    }

    /// PP-4161: parallel filter at `OPDS2FullPublication.toBook()`
    /// (lines 386-398). Same contract — streaming-media-only publications
    /// pass through. Pins the second `hasOpenablePath` site.
    func testOPDS2FullPublication_toBook_streamingMediaOnlyAcquisition_doesNotDrop() {
        let indirect = OPDS2IndirectAcquisition(
            type: ContentTypeStreamingHTML,
            child: nil
        )
        let link = OPDS2Link(
            href: "https://example.com/borrow/streaming-full",
            type: ContentTypeOPDSPublication,
            rel: "http://opds-spec.org/acquisition/borrow",
            properties: OPDS2LinkProperties(indirectAcquisition: [indirect])
        )
        let metadata = OPDS2FullMetadata(
            identifier: "urn:uuid:full-streaming-test",
            title: "Full Streaming-HTML Publication"
        )
        let publication = OPDS2FullPublication(
            metadata: metadata,
            links: [link],
            images: nil
        )

        let book = publication.toBook()

        XCTAssertNotNil(book,
                        "Full-publication streaming-media-only books must NOT be dropped by the parallel hasOpenablePath filter")
        XCTAssertEqual(book?.identifier, "urn:uuid:full-streaming-test")
        XCTAssertEqual(book?.defaultBookContentType, .streamingHTML)
    }

    /// Sanity: a publication whose ONLY acquisition is a truly unsupported
    /// MIME (e.g. text/csv) is still dropped. Catches a mutant that made
    /// the filter universally permissive after the streaming-HTML edit.
    func testOPDS2Publication_toBook_trulyUnsupportedFormat_stillDropped() {
        let indirect = OPDS2IndirectAcquisition(
            type: "text/csv",
            child: nil
        )
        let link = OPDS2Link(
            href: "https://example.com/borrow/unsupported",
            type: ContentTypeOPDSPublication,
            rel: "http://opds-spec.org/acquisition/borrow",
            properties: OPDS2LinkProperties(indirectAcquisition: [indirect])
        )
        let metadata = OPDS2Publication.Metadata(
            id: "urn:test:unsupported",
            title: "Unsupported Format Publication"
        )
        let publication = OPDS2Publication(
            links: [link],
            metadata: metadata,
            images: nil
        )

        XCTAssertNil(publication.toBook(),
                     "Publications with truly unsupported formats (text/csv) must still be dropped by hasOpenablePath")
    }

    // MARK: - Helpers

    private func makeMinimalMetadata(identifier: String = "urn:test:minimal") -> OPDS2FullMetadata {
        OPDS2FullMetadata(identifier: identifier, title: "Minimal Book")
    }
}
