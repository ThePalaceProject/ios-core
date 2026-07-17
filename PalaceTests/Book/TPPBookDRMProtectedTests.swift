//
//  TPPBookDRMProtectedTests.swift
//  PalaceTests
//
//  PP-4297: Gate copy/paste in the EPUB and PDF readers on a per-book
//  DRM-protected flag. The readers consult `TPPBook.isDRMProtected` to
//  decide whether the system text-selection edit menu appears on a long-
//  press. These tests pin the predicate's behavior against every DRM
//  scheme and content type Palace ships: Adobe ACS, Readium LCP (EPUB,
//  PDF, audiobook), and the open-access counterparts.
//

import XCTest
import PalaceCatalog
@testable import Palace

@MainActor
final class TPPBookIsDRMProtectedTests: XCTestCase {

    override func tearDown() {
        super.tearDown()
    }

    private static let testURL = URL(string: "https://test.example.com/borrow")!

    private func makeBook(
        identifier: String,
        acquisitions: [TPPOPDSAcquisition]
    ) -> TPPBook {
        TPPBook(
            acquisitions: acquisitions,
            authors: nil,
            categoryStrings: nil,
            distributor: nil,
            identifier: identifier,
            imageURL: nil,
            imageThumbnailURL: nil,
            published: Date(),
            publisher: nil,
            subtitle: nil,
            summary: nil,
            title: "Test",
            updated: Date(),
            annotationsURL: nil,
            analyticsURL: nil,
            alternateURL: nil,
            relatedWorksURL: nil,
            previewLink: nil,
            seriesURL: nil,
            revokeURL: nil,
            reportURL: nil,
            timeTrackingURL: nil,
            contributors: nil,
            bookDuration: nil,
            imageCache: ImageCache.shared
        )
    }

    // MARK: - DRM-protected → true

    func testIsDRMProtected_trueForAdobeAdeptEpub() {
        let adobeIndirect = TPPOPDSIndirectAcquisition(
            type: ContentTypeAdobeAdept,
            indirectAcquisitions: [
                TPPOPDSIndirectAcquisition(type: ContentTypeEpubZip, indirectAcquisitions: [])
            ]
        )
        let acquisition = TPPOPDSAcquisition(
            relation: .borrow,
            type: ContentTypeOPDSCatalog,
            hrefURL: Self.testURL,
            indirectAcquisitions: [adobeIndirect],
            availability: TPPOPDSAcquisitionAvailabilityUnlimited()
        )
        let book = makeBook(identifier: "adobe-epub", acquisitions: [acquisition])
        XCTAssertTrue(book.isDRMProtected,
                      "Adobe-DRM EPUB must be flagged DRM-protected so the reader suppresses the copy/paste menu.")
    }

    func testIsDRMProtected_trueForLCPEpub() {
        // LCP catalog → LCP license → EPUB. The MIME chain has the LCP
        // license type two levels deep — the predicate must walk the full
        // indirect chain (cf. PP-4407 acquisition-chain regression).
        let epubLeaf = TPPOPDSIndirectAcquisition(
            type: ContentTypeEpubZip,
            indirectAcquisitions: []
        )
        let lcpLicense = TPPOPDSIndirectAcquisition(
            type: ContentTypeReadiumLCP,
            indirectAcquisitions: [epubLeaf]
        )
        let acquisition = TPPOPDSAcquisition(
            relation: .borrow,
            type: ContentTypeOPDSCatalog,
            hrefURL: Self.testURL,
            indirectAcquisitions: [lcpLicense],
            availability: TPPOPDSAcquisitionAvailabilityUnlimited()
        )
        let book = makeBook(identifier: "lcp-epub", acquisitions: [acquisition])
        XCTAssertTrue(book.isDRMProtected,
                      "LCP EPUB (license nested two levels deep) must be flagged DRM-protected.")
    }

    func testIsDRMProtected_trueForLCPPdf() {
        let pdfLeaf = TPPOPDSIndirectAcquisition(
            type: ContentTypeReadiumLCPPDF,
            indirectAcquisitions: []
        )
        let lcpLicense = TPPOPDSIndirectAcquisition(
            type: ContentTypeReadiumLCP,
            indirectAcquisitions: [pdfLeaf]
        )
        let acquisition = TPPOPDSAcquisition(
            relation: .borrow,
            type: ContentTypeOPDSCatalog,
            hrefURL: Self.testURL,
            indirectAcquisitions: [lcpLicense],
            availability: TPPOPDSAcquisitionAvailabilityUnlimited()
        )
        let book = makeBook(identifier: "lcp-pdf", acquisitions: [acquisition])
        XCTAssertTrue(book.isDRMProtected,
                      "LCP PDF must be flagged DRM-protected so PDF reader suppresses text selection.")
    }

    func testIsDRMProtected_trueForLCPAudiobook() {
        let audiobookLeaf = TPPOPDSIndirectAcquisition(
            type: ContentTypeAudiobookLCP,
            indirectAcquisitions: []
        )
        let lcpLicense = TPPOPDSIndirectAcquisition(
            type: ContentTypeReadiumLCP,
            indirectAcquisitions: [audiobookLeaf]
        )
        let acquisition = TPPOPDSAcquisition(
            relation: .borrow,
            type: ContentTypeOPDSCatalog,
            hrefURL: Self.testURL,
            indirectAcquisitions: [lcpLicense],
            availability: TPPOPDSAcquisitionAvailabilityUnlimited()
        )
        let book = makeBook(identifier: "lcp-audiobook", acquisitions: [acquisition])
        XCTAssertTrue(book.isDRMProtected,
                      "LCP audiobook must be flagged DRM-protected (predicate covers every DRM scheme).")
    }

    // MARK: - Open access → false

    func testIsDRMProtected_falseForOpenAccessEpub() {
        let acquisition = TPPOPDSAcquisition(
            relation: .openAccess,
            type: ContentTypeEpubZip,
            hrefURL: Self.testURL,
            indirectAcquisitions: [],
            availability: TPPOPDSAcquisitionAvailabilityUnlimited()
        )
        let book = makeBook(identifier: "open-epub", acquisitions: [acquisition])
        XCTAssertFalse(book.isDRMProtected,
                       "Open-access EPUB must NOT be flagged DRM-protected — copy/paste should be enabled.")
    }

    func testIsDRMProtected_falseForOpenAccessPdf() {
        let acquisition = TPPOPDSAcquisition(
            relation: .openAccess,
            type: ContentTypeOpenAccessPDF,
            hrefURL: Self.testURL,
            indirectAcquisitions: [],
            availability: TPPOPDSAcquisitionAvailabilityUnlimited()
        )
        let book = makeBook(identifier: "open-pdf", acquisitions: [acquisition])
        XCTAssertFalse(book.isDRMProtected,
                       "Open-access PDF must NOT be flagged DRM-protected — copy/paste should be enabled.")
    }

    func testIsDRMProtected_falseForOpenAccessAudiobook() {
        let acquisition = TPPOPDSAcquisition(
            relation: .openAccess,
            type: ContentTypeOpenAccessAudiobook,
            hrefURL: Self.testURL,
            indirectAcquisitions: [],
            availability: TPPOPDSAcquisitionAvailabilityUnlimited()
        )
        let book = makeBook(identifier: "open-audiobook", acquisitions: [acquisition])
        XCTAssertFalse(book.isDRMProtected,
                       "Open-access audiobook must NOT be flagged DRM-protected.")
    }

    func testIsDRMProtected_falseForBookWithNoAcquisitions() {
        let book = makeBook(identifier: "no-acq", acquisitions: [])
        XCTAssertFalse(book.isDRMProtected,
                       "Book with no acquisitions must NOT be flagged DRM-protected (defensive default).")
    }

    // MARK: - Boundary: TPPFake OPDS fixture

    func testIsDRMProtected_trueForOPDSFixtureEntry() {
        // TPPFake.opdsEntry carries Adobe-DRM indirect acquisitions, so the
        // predicate should consistently flag it as DRM-protected. Acts as a
        // smoke test against the shared fixture.
        guard let book = TPPBook(entry: TPPFake.opdsEntry) else {
            return XCTFail("TPPFake.opdsEntry must produce a TPPBook for this assertion.")
        }
        XCTAssertTrue(book.isDRMProtected,
                      "Shared Adobe-DRM OPDS fixture must be flagged DRM-protected.")
    }
}
