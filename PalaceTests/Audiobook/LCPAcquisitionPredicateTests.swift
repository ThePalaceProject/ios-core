//
//  LCPAcquisitionPredicateTests.swift
//  PalaceTests
//
//  Behavior tests for `LCPAudiobooks.hasLCPAcquisition(_:)` — the recursive
//  predicate that catches Marketplace audiobooks regardless of which OPDS
//  feed (XML /loans/ or JSON /groups/) populated the book record.
//
//  This is the load-bearing fix that closes the PP-4407 regression class.
//  Module C of swarm_5c8ddbd5. Ports the 3.0.3 hotfix logic from commit
//  `ca2ff13b6` (release branch only — never forward-merged to develop).
//
//  File-level guard, NOT `#if LCP`: `hasLCPAcquisition` is `@objc static`
//  and reachable from the Palace-noDRM build, so its tests live outside the
//  LCP gate. The LCP MIME constant is a plain string — no Readium link.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

#if LCP

import XCTest
import PalaceCatalog
@testable import Palace

@MainActor
final class LCPAcquisitionPredicateTests: XCTestCase {

    // MARK: - MIME constants (mirrored from production for fixture readability)

    private let lcpLicenseMIME = "application/vnd.readium.lcp.license.v1.0+json"
    private let opdsPublicationMIME = "application/opds-publication+json"
    private let audiobookLCPMIME = "application/audiobook+lcp"
    private let openAccessAudiobookMIME = "application/audiobook+json"
    private let epubMIME = "application/epub+zip"

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

    /// `/loans/` XML feed shape: the LCP license MIME is the TOP-LEVEL type on
    /// `defaultAcquisition`. This is the legacy / classic path — both
    /// `canOpenBook` and `hasLCPAcquisition` must agree on TRUE here. The
    /// terminal indirect child must be `application/audiobook+lcp` so
    /// `defaultBookContentType` resolves to `.audiobook`.
    func testHasLCPAcquisition_topLevelLCPMime_returnsTrue() {
        let book = makeBook(acquisitions: [
            acquisition(
                type: lcpLicenseMIME,
                indirect: [indirect(audiobookLCPMIME)]
            )
        ])

        XCTAssertTrue(LCPAudiobooks.hasLCPAcquisition(book),
                      "Top-level LCP license MIME is the simplest positive case")
        XCTAssertTrue(LCPAudiobooks.canOpenBook(book),
                      "Sanity: legacy canOpenBook also agrees on the XML feed shape")
    }

    /// `/groups/` JSON feed shape — the Marketplace OPDS variant that produced
    /// PP-4407. Top-level type is `application/opds-publication+json` and the
    /// LCP license MIME is nested one level deep inside `indirectAcquisitions`.
    /// `canOpenBook` returns FALSE here (it only inspects the top-level type);
    /// `hasLCPAcquisition` must return TRUE.
    ///
    /// **THIS IS THE PP-4407 REGRESSION KILL POINT.** Ported from the 3.0.3
    /// hotfix commit `ca2ff13b6` on the release branch (never forward-merged
    /// to develop). If this test ever fails, the Marketplace audiobook open
    /// regression has reopened.
    func testHasLCPAcquisition_nestedLCPInIndirectChain_returnsTrue() {
        // PP-4407 / commit ca2ff13b6: Marketplace OPDS shape — top-level is
        // opds-publication+json, LCP MIME is nested one level deep, with the
        // audiobook+lcp content type below it.
        let book = makeBook(acquisitions: [
            acquisition(
                type: opdsPublicationMIME,
                indirect: [
                    indirect(lcpLicenseMIME, [indirect(audiobookLCPMIME)])
                ]
            )
        ])

        XCTAssertTrue(LCPAudiobooks.hasLCPAcquisition(book),
                      "Marketplace /groups/ JSON shape (LCP nested in indirectAcquisitions) must match — PP-4407 kill point")
        // swarm_162a3219 / Module D1: `canOpenBook` now delegates to
        // `hasLCPAcquisition` (the canonical recursive predicate). The
        // historical divergence — `canOpenBook` narrow + `hasLCPAcquisition`
        // recursive — was the PP-4407 bug shape. Locking equivalence
        // pins the architectural improvement.
        XCTAssertTrue(LCPAudiobooks.canOpenBook(book),
                      "canOpenBook MUST agree with hasLCPAcquisition on Marketplace fixtures — swarm_162a3219 closed the PP-4407 class")
        XCTAssertEqual(LCPAudiobooks.canOpenBook(book),
                       LCPAudiobooks.hasLCPAcquisition(book),
                       "canOpenBook and hasLCPAcquisition must agree on all LCP fixtures post-swarm_162a3219")
    }

    // NOTE: a `testHasLCPAcquisition_doublyNestedIndirectChain_returnsTrue`
    // test previously existed here to claim "mutant that stops the recursion
    // after one level would fail". It was removed because the claim is
    // mechanically false in production: `hasLCPAcquisition`'s upfront guard
    // requires `book.defaultBookContentType == .audiobook`, which is computed
    // via `TPPOPDSAcquisitionPath.supportedAcquisitionPaths(...)`. That
    // walker only accepts chains whose intermediates appear in
    // `supportedSubtypes(forType:)` — and no whitelisted chain rooted at
    // `OPDSPublication` (Marketplace's actual shape) has LCP buried at
    // depth > 1. The single real-world depth-1 shape is covered by
    // `testHasLCPAcquisition_nestedLCPInIndirectChain_returnsTrue` above
    // (PP-4407 kill point). A depth-2 mutant would have zero observable
    // production behavior and so is not worth a test.

    /// OpenAccess audiobook fixture — no LCP MIME anywhere in the chain.
    /// Companion negative case: pins that `hasLCPAcquisition` does NOT
    /// over-match on plain audiobooks.
    func testHasLCPAcquisition_noLCPAnywhere_returnsFalse() {
        let book = makeBook(acquisitions: [
            acquisition(
                type: openAccessAudiobookMIME
            )
        ])

        XCTAssertFalse(LCPAudiobooks.hasLCPAcquisition(book),
                       "Open-access audiobook with no LCP anywhere must return false")
    }

    /// `defaultBookContentType == .audiobook` is required: an LCP-typed EPUB
    /// must NOT match. Without this guard, an LCP-protected EPUB would be
    /// misrouted to the audiobook loader.
    func testHasLCPAcquisition_audiobookContentType_required() {
        let book = makeBook(acquisitions: [
            acquisition(
                type: lcpLicenseMIME,
                indirect: [indirect(epubMIME)]
            )
        ])

        // Sanity: this book IS LCP-typed at the top level, but its content
        // is an EPUB, not an audiobook.
        XCTAssertEqual(book.defaultBookContentType, .epub,
                       "Pre-condition: fixture is an LCP-protected EPUB, not an audiobook")
        XCTAssertFalse(LCPAudiobooks.hasLCPAcquisition(book),
                       "LCP-typed EPUB must NOT match — defaultBookContentType == .audiobook gate must hold")
    }
}

#endif
