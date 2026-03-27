//
//  OPDS2LinkAndPublicationTests.swift
//  PalaceTests
//
//  Tests for OPDS2Link, OPDS2LinkArray, OPDS2Publication, and OPDS2PublicationExtended
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

// MARK: - OPDS2Link Computed Properties Tests

/// SRS: CAT-002 — OPDS 2.0 feed parsing with authentication documents
final class OPDS2LinkComputedPropertyTests: XCTestCase {

    // MARK: - hrefURL

    func testHrefURL_ValidURL_ReturnsURL() {
        let link = OPDS2Link(href: "https://example.com/book")
        XCTAssertEqual(link.hrefURL?.absoluteString, "https://example.com/book")
    }

    func testHrefURL_InvalidURL_ReturnsNil() {
        let link = OPDS2Link(href: "not a valid url with spaces")
        XCTAssertNil(link.hrefURL)
    }

    // MARK: - isAcquisition

    func testIsAcquisition_BorrowRel_ReturnsTrue() {
        let link = OPDS2Link(href: "/borrow", rel: "http://opds-spec.org/acquisition/borrow")
        XCTAssertTrue(link.isAcquisition)
    }

    func testIsAcquisition_OpenAccessRel_ReturnsTrue() {
        let link = OPDS2Link(href: "/open", rel: "http://opds-spec.org/acquisition/open-access")
        XCTAssertTrue(link.isAcquisition)
    }

    func testIsAcquisition_SelfRel_ReturnsFalse() {
        let link = OPDS2Link(href: "/self", rel: "self")
        XCTAssertFalse(link.isAcquisition)
    }

    func testIsAcquisition_NilRel_ReturnsFalse() {
        let link = OPDS2Link(href: "/book")
        XCTAssertFalse(link.isAcquisition)
    }

    // MARK: - isOpenAccess

    func testIsOpenAccess_CorrectRel_ReturnsTrue() {
        let link = OPDS2Link(href: "/open", rel: "http://opds-spec.org/acquisition/open-access")
        XCTAssertTrue(link.isOpenAccess)
    }

    func testIsOpenAccess_BorrowRel_ReturnsFalse() {
        let link = OPDS2Link(href: "/borrow", rel: "http://opds-spec.org/acquisition/borrow")
        XCTAssertFalse(link.isOpenAccess)
    }

    // MARK: - isBorrow

    func testIsBorrow_CorrectRel_ReturnsTrue() {
        let link = OPDS2Link(href: "/borrow", rel: "http://opds-spec.org/acquisition/borrow")
        XCTAssertTrue(link.isBorrow)
    }

    func testIsBorrow_OpenAccessRel_ReturnsFalse() {
        let link = OPDS2Link(href: "/open", rel: "http://opds-spec.org/acquisition/open-access")
        XCTAssertFalse(link.isBorrow)
    }

    // MARK: - isSample

    func testIsSample_SampleRel_ReturnsTrue() {
        let link = OPDS2Link(href: "/sample", rel: "http://opds-spec.org/acquisition/sample")
        XCTAssertTrue(link.isSample)
    }

    func testIsSample_PreviewRel_ReturnsTrue() {
        let link = OPDS2Link(href: "/preview", rel: "preview")
        XCTAssertTrue(link.isSample)
    }

    func testIsSample_BorrowRel_ReturnsFalse() {
        let link = OPDS2Link(href: "/borrow", rel: "http://opds-spec.org/acquisition/borrow")
        XCTAssertFalse(link.isSample)
    }

    // MARK: - isImage

    func testIsImage_ImageType_ReturnsTrue() {
        let link = OPDS2Link(href: "/cover.jpg", type: "image/jpeg")
        XCTAssertTrue(link.isImage)
    }

    func testIsImage_ThumbnailRel_ReturnsTrue() {
        let link = OPDS2Link(href: "/thumb.png", rel: "http://opds-spec.org/image/thumbnail")
        XCTAssertTrue(link.isImage)
    }

    func testIsImage_CoverRel_ReturnsTrue() {
        let link = OPDS2Link(href: "/cover.png", rel: "http://opds-spec.org/cover")
        XCTAssertTrue(link.isImage)
    }

    func testIsImage_NonImageType_ReturnsFalse() {
        let link = OPDS2Link(href: "/book.epub", type: "application/epub+zip")
        XCTAssertFalse(link.isImage)
    }

    // MARK: - Identifiable

    func testId_ReturnsHref() {
        let link = OPDS2Link(href: "https://example.com/link")
        XCTAssertEqual(link.id, "https://example.com/link")
    }

    // MARK: - Codable Round-Trip

    func testLink_CodableRoundTrip_PreservesAllFields() throws {
        let link = OPDS2Link(
            href: "https://example.com/borrow",
            type: "application/epub+zip",
            rel: "http://opds-spec.org/acquisition/borrow",
            templated: true,
            title: "Borrow",
            height: 600,
            width: 400,
            bitrate: 128.0,
            duration: 3600.5,
            language: "en"
        )

        let data = try JSONEncoder().encode(link)
        let decoded = try JSONDecoder().decode(OPDS2Link.self, from: data)

        XCTAssertEqual(link, decoded)
    }

    func testLink_CodableRoundTrip_MinimalFields() throws {
        let link = OPDS2Link(href: "https://example.com")

        let data = try JSONEncoder().encode(link)
        let decoded = try JSONDecoder().decode(OPDS2Link.self, from: data)

        XCTAssertEqual(link, decoded)
        XCTAssertNil(decoded.type)
        XCTAssertNil(decoded.rel)
    }
}

// MARK: - OPDS2 Availability Tests

final class OPDS2AvailabilityTests: XCTestCase {

    func testIsAvailable_AvailableState_ReturnsTrue() {
        let availability = OPDS2Availability(state: "available")
        XCTAssertTrue(availability.isAvailable)
        XCTAssertFalse(availability.isUnavailable)
        XCTAssertFalse(availability.isReserved)
        XCTAssertFalse(availability.isReady)
    }

    func testIsUnavailable_UnavailableState_ReturnsTrue() {
        let availability = OPDS2Availability(state: "unavailable")
        XCTAssertTrue(availability.isUnavailable)
        XCTAssertFalse(availability.isAvailable)
    }

    func testIsReserved_ReservedState_ReturnsTrue() {
        let availability = OPDS2Availability(state: "reserved")
        XCTAssertTrue(availability.isReserved)
    }

    func testIsReady_ReadyState_ReturnsTrue() {
        let availability = OPDS2Availability(state: "ready")
        XCTAssertTrue(availability.isReady)
    }
}

// MARK: - OPDS2LinkArray Extension Tests

/// SRS: CAT-002 — OPDS 2.0 feed parsing with authentication documents
final class OPDS2LinkArrayTests: XCTestCase {

    func testAllRel_MatchingLinks_ReturnsFiltered() {
        let links = [
            OPDS2Link(href: "/reset", rel: OPDS2LinkRel.passwordReset.rawValue),
            OPDS2Link(href: "/other", rel: "self"),
            OPDS2Link(href: "/reset2", rel: OPDS2LinkRel.passwordReset.rawValue)
        ]

        let result = links.all(rel: .passwordReset)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].href, "/reset")
        XCTAssertEqual(result[1].href, "/reset2")
    }

    func testAllRel_NoMatchingLinks_ReturnsEmpty() {
        let links = [
            OPDS2Link(href: "/self", rel: "self"),
            OPDS2Link(href: "/next", rel: "next")
        ]

        let result = links.all(rel: .passwordReset)
        XCTAssertTrue(result.isEmpty)
    }

    func testFirstRel_MatchingLink_ReturnsFirst() {
        let links = [
            OPDS2Link(href: "/other", rel: "self"),
            OPDS2Link(href: "/reset1", rel: OPDS2LinkRel.passwordReset.rawValue),
            OPDS2Link(href: "/reset2", rel: OPDS2LinkRel.passwordReset.rawValue)
        ]

        let result = links.first(rel: .passwordReset)
        XCTAssertEqual(result?.href, "/reset1")
    }

    func testFirstRel_NoMatch_ReturnsNil() {
        let links = [OPDS2Link(href: "/self", rel: "self")]
        XCTAssertNil(links.first(rel: .passwordReset))
    }

    func testFirstRel_EmptyArray_ReturnsNil() {
        let links: [OPDS2Link] = []
        XCTAssertNil(links.first(rel: .passwordReset))
    }
}

// MARK: - OPDS2Publication Tests

/// SRS: CAT-002 — OPDS 2.0 feed parsing with authentication documents
final class OPDS2PublicationImageTests: XCTestCase {

    func testImageURL_PNGImage_ReturnsURL() {
        let pub = OPDS2Publication(
            links: [],
            metadata: .init(updated: Date(), description: nil, id: "id1", title: "Test"),
            images: [OPDS2Link(href: "https://example.com/cover.png", type: "image/png")]
        )
        XCTAssertEqual(pub.imageURL?.absoluteString, "https://example.com/cover.png")
    }

    func testImageURL_NonPNGImage_ReturnsNil() {
        let pub = OPDS2Publication(
            links: [],
            metadata: .init(updated: Date(), description: nil, id: "id1", title: "Test"),
            images: [OPDS2Link(href: "https://example.com/cover.jpg", type: "image/jpeg")]
        )
        XCTAssertNil(pub.imageURL)
    }

    func testImageURL_NoImages_ReturnsNil() {
        let pub = OPDS2Publication(
            links: [],
            metadata: .init(updated: Date(), description: nil, id: "id1", title: "Test"),
            images: nil
        )
        XCTAssertNil(pub.imageURL)
    }

    func testThumbnailURL_ThumbnailRel_ReturnsURL() {
        let pub = OPDS2Publication(
            links: [],
            metadata: .init(updated: Date(), description: nil, id: "id1", title: "Test"),
            images: [
                OPDS2Link(href: "https://example.com/thumb.png", type: "image/png", rel: "http://opds-spec.org/image/thumbnail")
            ]
        )
        XCTAssertEqual(pub.thumbnailURL?.absoluteString, "https://example.com/thumb.png")
    }

    func testThumbnailURL_NoThumbnailRel_ReturnsNil() {
        let pub = OPDS2Publication(
            links: [],
            metadata: .init(updated: Date(), description: nil, id: "id1", title: "Test"),
            images: [OPDS2Link(href: "https://example.com/cover.png", type: "image/png")]
        )
        XCTAssertNil(pub.thumbnailURL)
    }

    func testCoverURL_CoverRel_ReturnsURL() {
        let pub = OPDS2Publication(
            links: [],
            metadata: .init(updated: Date(), description: nil, id: "id1", title: "Test"),
            images: [
                OPDS2Link(href: "https://example.com/cover.png", type: "image/png", rel: "http://opds-spec.org/cover")
            ]
        )
        XCTAssertEqual(pub.coverURL?.absoluteString, "https://example.com/cover.png")
    }
}

// MARK: - OPDS2FullPublication Tests

/// SRS: CAT-002 — OPDS 2.0 feed parsing with authentication documents
final class OPDS2FullPublicationTests: XCTestCase {

    private func makeFullPublication(
        links: [OPDS2Link] = [],
        images: [OPDS2Link]? = nil
    ) throws -> OPDS2FullPublication {
        // Build JSON and decode to exercise the custom init(from:) on OPDS2FullMetadata
        let metadata: [String: Any] = [
            "@id": "urn:isbn:123",
            "title": "Test Book"
        ]
        let pubDict: [String: Any] = [
            "metadata": metadata,
            "links": links.map { ["href": $0.href, "rel": $0.rel as Any, "type": $0.type as Any] },
            "images": images?.map { ["href": $0.href, "rel": $0.rel as Any, "type": $0.type as Any, "width": $0.width as Any] } as Any
        ]
        let data = try JSONSerialization.data(withJSONObject: pubDict)
        return try JSONDecoder().decode(OPDS2FullPublication.self, from: data)
    }

    func testAcquisitionLinks_FiltersCorrectly() {
        let links = [
            OPDS2Link(href: "/borrow", rel: "http://opds-spec.org/acquisition/borrow"),
            OPDS2Link(href: "/self", rel: "self"),
            OPDS2Link(href: "/open", rel: "http://opds-spec.org/acquisition/open-access")
        ]
        let pub = OPDS2FullPublication(
            metadata: makeMinimalFullMetadata(),
            links: links,
            images: nil
        )

        XCTAssertEqual(pub.acquisitionLinks.count, 2)
    }

    func testBorrowLink_Found_ReturnsLink() {
        let links = [
            OPDS2Link(href: "/borrow", rel: "http://opds-spec.org/acquisition/borrow"),
            OPDS2Link(href: "/open", rel: "http://opds-spec.org/acquisition/open-access")
        ]
        let pub = OPDS2FullPublication(
            metadata: makeMinimalFullMetadata(),
            links: links,
            images: nil
        )

        XCTAssertEqual(pub.borrowLink?.href, "/borrow")
    }

    func testOpenAccessLink_Found_ReturnsLink() {
        let links = [
            OPDS2Link(href: "/open", rel: "http://opds-spec.org/acquisition/open-access")
        ]
        let pub = OPDS2FullPublication(
            metadata: makeMinimalFullMetadata(),
            links: links,
            images: nil
        )

        XCTAssertEqual(pub.openAccessLink?.href, "/open")
    }

    func testSampleLink_SampleRel_ReturnsLink() {
        let links = [
            OPDS2Link(href: "/sample", rel: "http://opds-spec.org/acquisition/sample")
        ]
        let pub = OPDS2FullPublication(
            metadata: makeMinimalFullMetadata(),
            links: links,
            images: nil
        )

        XCTAssertEqual(pub.sampleLink?.href, "/sample")
    }

    func testSampleLink_PreviewRel_ReturnsLink() {
        let links = [
            OPDS2Link(href: "/preview", rel: "preview")
        ]
        let pub = OPDS2FullPublication(
            metadata: makeMinimalFullMetadata(),
            links: links,
            images: nil
        )

        XCTAssertEqual(pub.sampleLink?.href, "/preview")
    }

    func testIsAudiobook_AudiobookType_ReturnsTrue() {
        let links = [
            OPDS2Link(href: "/acquire", type: "application/audiobook+json", rel: "http://opds-spec.org/acquisition")
        ]
        let pub = OPDS2FullPublication(
            metadata: makeMinimalFullMetadata(),
            links: links,
            images: nil
        )

        XCTAssertTrue(pub.isAudiobook)
        XCTAssertFalse(pub.isEPUB)
        XCTAssertFalse(pub.isPDF)
    }

    func testIsEPUB_EpubType_ReturnsTrue() {
        let links = [
            OPDS2Link(href: "/acquire", type: "application/epub+zip", rel: "http://opds-spec.org/acquisition")
        ]
        let pub = OPDS2FullPublication(
            metadata: makeMinimalFullMetadata(),
            links: links,
            images: nil
        )

        XCTAssertTrue(pub.isEPUB)
        XCTAssertFalse(pub.isAudiobook)
    }

    func testIsPDF_PdfType_ReturnsTrue() {
        let links = [
            OPDS2Link(href: "/acquire", type: "application/pdf", rel: "http://opds-spec.org/acquisition")
        ]
        let pub = OPDS2FullPublication(
            metadata: makeMinimalFullMetadata(),
            links: links,
            images: nil
        )

        XCTAssertTrue(pub.isPDF)
    }

    func testImageURL_NoRelImage_ReturnsFirst() {
        let images = [
            OPDS2Link(href: "https://example.com/image.jpg", type: "image/jpeg")
        ]
        let pub = OPDS2FullPublication(
            metadata: makeMinimalFullMetadata(),
            links: [],
            images: images
        )

        XCTAssertEqual(pub.imageURL?.absoluteString, "https://example.com/image.jpg")
    }

    func testThumbnailURL_ThumbnailRel_ReturnsCorrectURL() {
        let images = [
            OPDS2Link(href: "https://example.com/cover.jpg", type: "image/jpeg"),
            OPDS2Link(href: "https://example.com/thumb.jpg", type: "image/jpeg", rel: "http://opds-spec.org/image/thumbnail")
        ]
        let pub = OPDS2FullPublication(
            metadata: makeMinimalFullMetadata(),
            links: [],
            images: images
        )

        XCTAssertEqual(pub.thumbnailURL?.absoluteString, "https://example.com/thumb.jpg")
    }

    func testThumbnailURL_SmallWidth_FallsBackToSmallImage() {
        let images = [
            OPDS2Link(href: "https://example.com/small.jpg", type: "image/jpeg", width: 100),
            OPDS2Link(href: "https://example.com/large.jpg", type: "image/jpeg", width: 600)
        ]
        let pub = OPDS2FullPublication(
            metadata: makeMinimalFullMetadata(),
            links: [],
            images: images
        )

        XCTAssertEqual(pub.thumbnailURL?.absoluteString, "https://example.com/small.jpg")
    }

    func testCoverURL_CoverRel_ReturnsCorrectURL() {
        let images = [
            OPDS2Link(href: "https://example.com/cover.jpg", type: "image/jpeg", rel: "http://opds-spec.org/cover")
        ]
        let pub = OPDS2FullPublication(
            metadata: makeMinimalFullMetadata(),
            links: [],
            images: images
        )

        XCTAssertEqual(pub.coverURL?.absoluteString, "https://example.com/cover.jpg")
    }

    func testCoverURL_LargeWidth_FallsBackToLargeImage() {
        let images = [
            OPDS2Link(href: "https://example.com/small.jpg", type: "image/jpeg", width: 100),
            OPDS2Link(href: "https://example.com/large.jpg", type: "image/jpeg", width: 600)
        ]
        let pub = OPDS2FullPublication(
            metadata: makeMinimalFullMetadata(),
            links: [],
            images: images
        )

        XCTAssertEqual(pub.coverURL?.absoluteString, "https://example.com/large.jpg")
    }

    // MARK: - Helpers

    private func makeMinimalFullMetadata() -> OPDS2FullMetadata {
        // Decode from JSON to exercise the custom decoder
        let json = Data("""
        {"@id": "urn:isbn:123", "title": "Test Book"}
        """.utf8)
        return try! JSONDecoder().decode(OPDS2FullMetadata.self, from: json)
    }
}

// MARK: - OPDS2FullMetadata Decoding Tests

/// SRS: CAT-002 — OPDS 2.0 feed parsing with authentication documents
final class OPDS2FullMetadataTests: XCTestCase {

    func testDecode_AtIdKey_ParsesIdentifier() throws {
        let json = Data("""
        {"@id": "urn:isbn:978-0-123456-78-9", "title": "My Book"}
        """.utf8)

        let metadata = try JSONDecoder().decode(OPDS2FullMetadata.self, from: json)
        XCTAssertEqual(metadata.identifier, "urn:isbn:978-0-123456-78-9")
        XCTAssertEqual(metadata.title, "My Book")
    }

    func testDecode_MissingId_GeneratesUUID() throws {
        let json = Data("""
        {"title": "No ID Book"}
        """.utf8)

        let metadata = try JSONDecoder().decode(OPDS2FullMetadata.self, from: json)
        XCTAssertFalse(metadata.identifier.isEmpty)
        XCTAssertEqual(metadata.title, "No ID Book")
    }

    func testDecode_AllOptionalFields_ParsesCorrectly() throws {
        let json = Data("""
        {
            "@id": "book-1",
            "title": "Full Book",
            "sortAs": "Full Book, The",
            "subtitle": "A Subtitle",
            "language": "en",
            "description": "A description",
            "publisher": "Test Publisher",
            "imprint": "Test Imprint",
            "duration": 7200.5,
            "numberOfPages": 350,
            "author": [{"name": "Jane Author", "sortAs": "Author, Jane"}],
            "subject": [{"name": "Fiction", "scheme": "http://example.com/subjects", "code": "FIC"}]
        }
        """.utf8)

        let metadata = try JSONDecoder().decode(OPDS2FullMetadata.self, from: json)
        XCTAssertEqual(metadata.sortAs, "Full Book, The")
        XCTAssertEqual(metadata.subtitle, "A Subtitle")
        XCTAssertEqual(metadata.language, "en")
        XCTAssertEqual(metadata.description, "A description")
        XCTAssertEqual(metadata.publisher, "Test Publisher")
        XCTAssertEqual(metadata.imprint, "Test Imprint")
        XCTAssertEqual(metadata.duration, 7200.5)
        XCTAssertEqual(metadata.numberOfPages, 350)
        XCTAssertEqual(metadata.author?.first?.name, "Jane Author")
        XCTAssertEqual(metadata.author?.first?.sortAs, "Author, Jane")
        XCTAssertEqual(metadata.subject?.first?.name, "Fiction")
        XCTAssertEqual(metadata.subject?.first?.code, "FIC")
    }

    func testEncodeDecode_RoundTrip_PreservesData() throws {
        let json = Data("""
        {"@id": "round-trip-id", "title": "Round Trip", "language": "fr", "numberOfPages": 200}
        """.utf8)

        let original = try JSONDecoder().decode(OPDS2FullMetadata.self, from: json)
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(OPDS2FullMetadata.self, from: encoded)

        XCTAssertEqual(original, decoded)
    }
}

// MARK: - OPDS2Contributor Decoding Tests

final class OPDS2ContributorTests: XCTestCase {

    func testDecode_StringValue_ParsesAsName() throws {
        let json = Data("\"Jane Doe\"".utf8)
        let contributor = try JSONDecoder().decode(OPDS2Contributor.self, from: json)

        XCTAssertEqual(contributor.name, "Jane Doe")
        XCTAssertNil(contributor.sortAs)
        XCTAssertNil(contributor.identifier)
        XCTAssertNil(contributor.links)
    }

    func testDecode_ObjectValue_ParsesAllFields() throws {
        let json = Data("""
        {"name": "John Smith", "sortAs": "Smith, John", "identifier": "author-123"}
        """.utf8)
        let contributor = try JSONDecoder().decode(OPDS2Contributor.self, from: json)

        XCTAssertEqual(contributor.name, "John Smith")
        XCTAssertEqual(contributor.sortAs, "Smith, John")
        XCTAssertEqual(contributor.identifier, "author-123")
    }
}

// MARK: - OPDS2Subject Decoding Tests

final class OPDS2SubjectTests: XCTestCase {

    func testDecode_StringValue_ParsesAsName() throws {
        let json = Data("\"Science Fiction\"".utf8)
        let subject = try JSONDecoder().decode(OPDS2Subject.self, from: json)

        XCTAssertEqual(subject.name, "Science Fiction")
        XCTAssertNil(subject.scheme)
        XCTAssertNil(subject.code)
    }

    func testDecode_ObjectValue_ParsesAllFields() throws {
        let json = Data("""
        {"name": "Mystery", "sortAs": "mystery", "scheme": "http://example.com/genres", "code": "MYS"}
        """.utf8)
        let subject = try JSONDecoder().decode(OPDS2Subject.self, from: json)

        XCTAssertEqual(subject.name, "Mystery")
        XCTAssertEqual(subject.sortAs, "mystery")
        XCTAssertEqual(subject.scheme, "http://example.com/genres")
        XCTAssertEqual(subject.code, "MYS")
    }
}

// MARK: - OPDS2 Supporting Types Tests

final class OPDS2SupportingTypesTests: XCTestCase {

    func testPrice_CodableRoundTrip() throws {
        let price = OPDS2Price(currency: "USD", value: 9.99)
        let data = try JSONEncoder().encode(price)
        let decoded = try JSONDecoder().decode(OPDS2Price.self, from: data)

        XCTAssertEqual(decoded.currency, "USD")
        XCTAssertEqual(decoded.value, 9.99, accuracy: 0.001)
    }

    func testIndirectAcquisition_NestedChild() throws {
        let acq = OPDS2IndirectAcquisition(
            type: "application/vnd.adobe.adept+xml",
            child: [OPDS2IndirectAcquisition(type: "application/epub+zip")]
        )
        let data = try JSONEncoder().encode(acq)
        let decoded = try JSONDecoder().decode(OPDS2IndirectAcquisition.self, from: data)

        XCTAssertEqual(decoded.type, "application/vnd.adobe.adept+xml")
        XCTAssertEqual(decoded.child?.first?.type, "application/epub+zip")
    }

    func testBelongsTo_SeriesWithPosition() throws {
        let belongsTo = OPDS2BelongsTo(
            series: [OPDS2Collection(name: "Harry Potter", position: 3.0)]
        )
        let data = try JSONEncoder().encode(belongsTo)
        let decoded = try JSONDecoder().decode(OPDS2BelongsTo.self, from: data)

        XCTAssertEqual(decoded.series?.first?.name, "Harry Potter")
        XCTAssertEqual(decoded.series?.first?.position, 3.0)
        XCTAssertNil(decoded.collection)
    }

    func testFacetLink_IsActive_WithNumberOfItems_ReturnsTrue() {
        let props = OPDS2FacetProperties(numberOfItems: 42)
        let link = OPDS2FacetLink(href: "/active", title: "Active", properties: props)

        XCTAssertTrue(link.isActive)
    }

    func testFacetLink_IsActive_WithoutProperties_ReturnsFalse() {
        let link = OPDS2FacetLink(href: "/inactive", title: "Inactive")
        XCTAssertFalse(link.isActive)
    }
}
