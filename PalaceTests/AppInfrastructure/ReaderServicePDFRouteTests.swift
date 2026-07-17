//
//  ReaderServicePDFRouteTests.swift
//  PalaceTests
//
//  Behavior tests for `ReaderService.pdfOpenRoute(for:)` — the pure routing
//  decision that `openPDF` dispatches on to send a book to either the LCP
//  extract pipeline (`openLCPPDF`) or the plain PDFKit path (`openPlainPDF`).
//
//  Regression context: the Continue-reading card calls `ReaderService.openPDF`
//  directly. While `openPDF` was LCP-only, tapping a *plain* (open-access)
//  downloaded PDF drove it through the Readium publication-open + disk-extract
//  pipeline, which failed with a spurious "unable to open" alert — the user
//  saw a loading spinner and then an error. BookDetail worked only because it
//  routed through `BookService.presentPDF`'s own LCP gate. The fix moves the
//  gate into `openPDF` (via `pdfOpenRoute`) so every caller routes correctly
//  through one seam. These tests pin that a non-LCP PDF routes `.plain` and an
//  LCP PDF routes `.lcp`; flipping the gate condition in production fails them.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceCatalog
@testable import Palace

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
