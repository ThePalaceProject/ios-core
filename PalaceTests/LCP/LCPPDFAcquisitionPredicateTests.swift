//
//  LCPPDFAcquisitionPredicateTests.swift
//  PalaceTests
//
//  Behavior tests for `LCPPDFs.hasLCPAcquisition(_:)` — the recursive
//  predicate that catches Marketplace LCP-wrapped PDFs regardless of which
//  OPDS feed shape (XML `/loans/` vs. JSON `/groups/`) populated the book
//  record. Direct mirror of `LCPAcquisitionPredicateTests` (audiobooks).
//
//  Closes PP-4454. The structural bug fixed for audiobooks in PR #958 /
//  3.0.3 hotfix `ca2ff13b6` (PP-4407) was never ported to the PDF path —
//  `LCPPDFs.canOpenBook` still inspects only `defaultAcquisition.type`, so
//  Marketplace LCP PDFs whose top-level type is `opds-publication+json`
//  (with the LCP MIME nested in `indirectAcquisitions`) save with the wrong
//  on-disk extension and never decrypt cleanly. Patrons see "an error
//  message" instead of the PDF rendering.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

#if LCP

import XCTest
import PalaceCatalog
@testable import Palace
import PalaceBookModel

@MainActor
final class LCPPDFAcquisitionPredicateTests: XCTestCase {

    // MARK: - MIME constants (mirrored from production for fixture readability)

    private let lcpLicenseMIME = "application/vnd.readium.lcp.license.v1.0+json"
    private let opdsPublicationMIME = "application/opds-publication+json"
    private let opdsCatalogMIME = "application/atom+xml;type=entry;profile=opds-catalog"
    private let pdfMIME = "application/pdf"
    private let audiobookLCPMIME = "application/audiobook+lcp"

    // MARK: - Fixture helpers

    private func makeBook(acquisitions: [TPPOPDSAcquisition]) -> TPPBook {
        let identifier = UUID().uuidString
        return TPPBook(
            acquisitions: acquisitions,
            authors: [],
            categoryStrings: [],
            distributor: "Test",
            identifier: identifier,
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

    /// `/loans/` XML feed shape (legacy): LCP license MIME is the top-level
    /// type, terminal indirect is `application/pdf`. Both `canOpenBook` and
    /// `hasLCPAcquisition` must agree on TRUE — this is the shape both the
    /// new recursive predicate and the existing `defaultAcquisition.type ==
    /// LCP` check were authored for.
    func testHasLCPAcquisition_topLevelLCPMime_returnsTrue() {
        let book = makeBook(acquisitions: [
            acquisition(
                type: lcpLicenseMIME,
                indirect: [indirect(pdfMIME)]
            )
        ])

        XCTAssertEqual(book.defaultBookContentType, .pdf,
                       "Pre-condition: classic LCP-license-wrapped PDF resolves as .pdf")
        XCTAssertTrue(LCPPDFs.hasLCPAcquisition(book),
                      "Top-level LCP license MIME wrapping a PDF — simplest positive case")
        XCTAssertTrue(LCPPDFs.canOpenBook(book),
                      "Sanity: legacy canOpenBook also agrees on the XML feed shape — the recursive predicate must not regress this path")
    }

    /// `/groups/` JSON feed shape — the Marketplace OPDS variant that
    /// produced PP-4454. Top-level type is `application/opds-publication+json`,
    /// LCP license MIME is nested one level deep, terminal is `application/pdf`.
    /// `canOpenBook` returns FALSE (it only inspects the top-level type);
    /// `hasLCPAcquisition` must return TRUE.
    ///
    /// **THIS IS THE PP-4454 REGRESSION KILL POINT.** Ported in structure
    /// from `LCPAcquisitionPredicateTests.testHasLCPAcquisition_nestedLCPInIndirectChain_returnsTrue`
    /// (PP-4407 audiobook fix). If this test ever fails, the Marketplace
    /// LCP-wrapped PDF open regression has reopened.
    func testHasLCPAcquisition_nestedLCPInIndirectChain_returnsTrue() {
        let book = makeBook(acquisitions: [
            acquisition(
                type: opdsPublicationMIME,
                indirect: [
                    indirect(lcpLicenseMIME, [indirect(pdfMIME)])
                ]
            )
        ])

        XCTAssertEqual(book.defaultBookContentType, .pdf,
                       "Pre-condition: Marketplace OPDS shape still resolves the terminal type as .pdf")
        XCTAssertTrue(LCPPDFs.hasLCPAcquisition(book),
                      "Marketplace /groups/ JSON shape (LCP nested in indirectAcquisitions) must match — PP-4454 kill point")
        XCTAssertFalse(LCPPDFs.canOpenBook(book),
                       "Legacy canOpenBook MUST return false on this fixture — divergence asserts that hasLCPAcquisition is doing real recursive work, not duplicating canOpenBook")
    }

    /// OPDS-Catalog wrapping shape — the failing fixture from
    /// **Power Rangers Unlimited: Edge of Darkness** in PP-4454. The book
    /// exposes TWO top-level acquisitions: `[0]` is the OPDS Catalog entry
    /// (becomes `defaultAcquisition`), `[1]` is the LCP license MIME
    /// directly. A predicate that only inspects `defaultAcquisition` (or
    /// only its `indirectAcquisitions`) misses the LCP MIME entirely
    /// because it lives on a *sibling* acquisition, not nested under the
    /// default one.
    ///
    /// **THIS IS THE PP-4454 EDGE OF DARKNESS KILL POINT.** If this test
    /// fails, OPDS-Catalog-wrapped LCP PDFs route to the open-access
    /// PDFKit path and the user sees "Unable to load PDF file."
    func testHasLCPAcquisition_siblingLCPAcquisition_returnsTrue() {
        let book = makeBook(acquisitions: [
            acquisition(type: opdsCatalogMIME, indirect: [indirect(pdfMIME)]),
            acquisition(type: lcpLicenseMIME, indirect: [indirect(pdfMIME)])
        ])

        XCTAssertEqual(book.defaultBookContentType, .pdf,
                       "Pre-condition: OPDS-Catalog-wrapped LCP PDF resolves as .pdf")
        XCTAssertTrue(LCPPDFs.hasLCPAcquisition(book),
                      "OPDS-Catalog wrapping shape — LCP MIME on sibling acquisition must match — PP-4454 Edge of Darkness kill point")
        XCTAssertFalse(LCPPDFs.canOpenBook(book),
                       "Legacy canOpenBook only inspects defaultAcquisition (the OPDS Catalog one), so it returns false here — divergence asserts the new predicate is walking siblings")
    }

    /// Open-access PDF — no LCP MIME anywhere in the chain. Pins that
    /// `hasLCPAcquisition` does NOT over-match on plain PDFs (otherwise
    /// `BookFileManager.pathExtension` would route every PDF to `.zip` and
    /// the LCPFulfillmentHandler extract pass would fire spuriously).
    func testHasLCPAcquisition_noLCPAnywhere_returnsFalse() {
        let book = makeBook(acquisitions: [
            acquisition(type: pdfMIME)
        ])

        XCTAssertFalse(LCPPDFs.hasLCPAcquisition(book),
                       "Open-access PDF with no LCP anywhere must return false")
    }

    /// `defaultBookContentType == .pdf` is required: an LCP-typed audiobook
    /// must NOT match. Without this guard, an LCP-protected audiobook would
    /// be misrouted to the PDF pipeline (extract-to-tmp-then-PDFKit), which
    /// would silently fail and the audiobook would never play.
    func testHasLCPAcquisition_pdfContentType_required() {
        let book = makeBook(acquisitions: [
            acquisition(
                type: lcpLicenseMIME,
                indirect: [indirect(audiobookLCPMIME)]
            )
        ])

        XCTAssertEqual(book.defaultBookContentType, .audiobook,
                       "Pre-condition: fixture is an LCP-protected audiobook, not a PDF")
        XCTAssertFalse(LCPPDFs.hasLCPAcquisition(book),
                       "LCP-typed audiobook must NOT match — defaultBookContentType == .pdf gate must hold")
    }
}

#endif
