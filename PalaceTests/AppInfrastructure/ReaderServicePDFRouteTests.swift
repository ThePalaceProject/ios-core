//
//  ReaderServicePDFRouteTests.swift
//
//  `ReaderService.pdfOpenRoute(for:)` decides whether `openPDF` sends a book to
//  the LCP extract pipeline or plain PDFKit. The Continue-reading card calls
//  `openPDF` directly, and while it was LCP-only an open-access PDF failed with
//  a spurious "unable to open" alert. The gate now lives in `openPDF`, so every
//  caller routes through one seam: non-LCP → `.plain`, LCP → `.lcp`.
//

import XCTest
import PalaceCatalog
@testable import Palace
import PalaceBookModel

final class ReaderServicePDFRouteTests: XCTestCase {

    // MARK: - MIME constants (mirrored from production for fixture readability)

    private let lcpLicenseMIME = "application/vnd.readium.lcp.license.v1.0+json"
    private let opdsPublicationMIME = "application/opds-publication+json"
    private let pdfMIME = "application/pdf"

    // MARK: - Fixture helpers

    private func makeBook(acquisitions: [TPPOPDSAcquisition]) -> TPPBook {
        TPPBook(
            acquisitions: acquisitions,
            authors: [],
            categoryStrings: [],
            distributor: "Test",
            identifier: UUID().uuidString,
            imageURL: nil,
            imageThumbnailURL: nil,
            published: Date(),
            publisher: "Test",
            subtitle: nil,
            summary: nil,
            title: "Test Book",
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
            contributors: [:],
            bookDuration: nil,
            imageCache: MockImageCache()
        )
    }

    private func acquisition(
        type: String,
        indirect: [TPPOPDSIndirectAcquisition] = []
    ) -> TPPOPDSAcquisition {
        TPPOPDSAcquisition(
            relation: .generic,
            type: type,
            hrefURL: URL(string: "https://library.test/book.lcpl")!,
            indirectAcquisitions: indirect,
            availability: TPPOPDSAcquisitionAvailabilityUnlimited()
        )
    }

    private func indirect(_ type: String, _ children: [TPPOPDSIndirectAcquisition] = []) -> TPPOPDSIndirectAcquisition {
        TPPOPDSIndirectAcquisition(type: type, indirectAcquisitions: children)
    }

    // MARK: - Tests

    /// Open-access PDF — no LCP MIME anywhere. MUST route `.plain` so the
    /// Continue card (and every other caller) opens it via PDFKit rather than
    /// driving it through the LCP extract pipeline that produced the reported
    /// "loading then error". This is the direct regression kill point.
    func testPDFOpenRoute_plainPDF_routesPlain() {
        let book = makeBook(acquisitions: [acquisition(type: pdfMIME)])

        XCTAssertEqual(book.defaultBookContentType, .pdf,
                       "Pre-condition: open-access PDF resolves as .pdf")
        XCTAssertEqual(ReaderService.pdfOpenRoute(for: book), .plain,
                       "A non-LCP PDF MUST route to the plain PDFKit path — routing it to .lcp is exactly the Continue-card regression")
    }

    #if LCP
    /// Classic LCP-license-wrapped PDF — top-level LCP MIME. MUST route `.lcp`
    /// so the Readium extract pipeline runs. Flipping the gate would send an
    /// encrypted PDF to the plain path, where PDFKit cannot decrypt it.
    func testPDFOpenRoute_topLevelLCPPDF_routesLCP() {
        let book = makeBook(acquisitions: [
            acquisition(type: lcpLicenseMIME, indirect: [indirect(pdfMIME)])
        ])

        XCTAssertEqual(book.defaultBookContentType, .pdf,
                       "Pre-condition: LCP-license-wrapped PDF resolves as .pdf")
        XCTAssertEqual(ReaderService.pdfOpenRoute(for: book), .lcp,
                       "A top-level-LCP PDF MUST route to the LCP extract pipeline")
    }

    /// Marketplace `/groups/` JSON shape — LCP MIME nested one level deep under
    /// `application/opds-publication+json`. MUST still route `.lcp` (mirrors the
    /// PP-4454 nested-chain kill point). This proves the gate uses the recursive
    /// `hasLCPAcquisition` predicate, not a shallow `defaultAcquisition.type`.
    func testPDFOpenRoute_nestedMarketplaceLCPPDF_routesLCP() {
        let book = makeBook(acquisitions: [
            acquisition(
                type: opdsPublicationMIME,
                indirect: [indirect(lcpLicenseMIME, [indirect(pdfMIME)])]
            )
        ])

        XCTAssertEqual(book.defaultBookContentType, .pdf,
                       "Pre-condition: Marketplace-shaped LCP PDF still resolves as .pdf")
        XCTAssertEqual(ReaderService.pdfOpenRoute(for: book), .lcp,
                       "A nested/Marketplace LCP PDF MUST route .lcp — the gate must walk the indirect chain")
    }
    #endif
}
