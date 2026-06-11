//
//  AudiobookLoaderOPDSShapeMatrixTests.swift
//  PalaceTests
//
//  The PP-4407 regression matrix. Module D of swarm_5c8ddbd5
//  (Audiobook Vendor Adapter Extraction).
//
//  Every row in this matrix corresponds to a real-world OPDS feed shape the
//  loader has been observed to handle (or misroute) in production. The
//  tests construct realistic `TPPBook` fixtures, feed them through an
//  adapter chain whose `canHandle` predicates mirror the production
//  adapters (LCP > LocalFile > BearerToken > OpenAccess), and assert
//  which adapter claims the book.
//
//  THE LOAD-BEARING ROW IS `testMatrix_OPDS2JSONFeedNestedLCP_routesToLCP`:
//  the `/groups/` JSON feed shape Marketplace returns, where the LCP MIME
//  is nested inside `indirectAcquisitions[*].type` instead of at the
//  acquisition's top-level `type`. Pre-swarm code (and the property-check
//  loader exercised in the META-TEST below) used only the top-level type,
//  which misrouted these books to OpenAccess and produced the PP-4407
//  failure (parse-binary-as-JSON crash, no fallback, no retry surface).
//
//  Reference: PP-4407, hotfix commit `ca2ff13b6` on the 3.0.3 release branch
//  (never forward-merged to develop). Module C's `hasLCPAcquisition` ports
//  the recursive predicate; Module D's adapter chain wires it through the
//  LCPAdapter's `canHandle`.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceCatalog
@preconcurrency import PalaceAudiobookToolkit
@testable import Palace

@MainActor
final class AudiobookLoaderOPDSShapeMatrixTests: XCTestCase {

    // MARK: - Hermetic auth-state guard
    //
    // AudiobookLoader.load() runs refreshTokenIfNeeded() BEFORE the adapter
    // chain; that gate reads AppContainer.production().accountsManager
    // .currentUserAccount. A leftover EXPIRED token in the sim keychain (e.g.
    // inherited from a suite killed mid-run, between a writer test's
    // setAuthToken(expired) and its removeAll()) makes authTokenHasExpired==true,
    // so the gate fails and the adapter chain is skipped → every spy's
    // resolveCallCount stays 0 and the routing assertions fail "0 != 1". Clearing
    // the shared account's credentials in setUp makes the gate deterministically
    // pass, so these tests assert routing regardless of inherited sim state.

    override func setUpWithError() throws {
        try super.setUpWithError()
        try KeychainAvailability.skipIfUnavailable()
        AppContainer.production().accountsManager.currentUserAccount.removeAll()
    }

    override func tearDown() {
        AppContainer.production().accountsManager.currentUserAccount.removeAll()
        super.tearDown()
    }

    // MARK: - MIME constants (mirrored from production for fixture readability)

    private let lcpLicenseMIME = "application/vnd.readium.lcp.license.v1.0+json"
    private let opdsPublicationMIME = "application/opds-publication+json"
    private let audiobookLCPMIME = "application/audiobook+lcp"
    private let openAccessAudiobookMIME = "application/audiobook+json"
    private let bearerTokenMIME = "application/vnd.librarysimplified.bearer-token+json"
    private let findawayMIME = "application/vnd.librarysimplified.findaway.license+json"

    // MARK: - Predicate spy adapters
    //
    // These spies emulate the PRODUCTION `canHandle` predicate of each
    // adapter so we can drive the routing matrix without instantiating the
    // real adapters (which would require real network, real disk, real
    // AppContainer). `resolveManifest` is stubbed — we only assert which
    // adapter is invoked.

    /// Spy whose `canHandle` invokes a closure that mirrors the production
    /// predicate. Records `resolveCallCount` so the test can assert which
    /// row of the matrix routed where.
    private final class PredicateSpyAdapter: AudiobookVendorAdapter {
        let label: String
        let predicate: (TPPBook) -> Bool
        private(set) var canHandleCallCount = 0
        private(set) var resolveCallCount = 0

        init(label: String, predicate: @escaping (TPPBook) -> Bool) {
            self.label = label
            self.predicate = predicate
        }

        func canHandle(_ book: TPPBook) -> Bool {
            canHandleCallCount += 1
            return predicate(book)
        }

        func resolveManifest(
            for book: TPPBook,
            completion: @escaping (Result<(json: [String: Any], decryptor: DRMDecryptor?), AudiobookLoadError>) -> Void
        ) {
            resolveCallCount += 1
            completion(.success((json: ["@type": "Audiobook"], decryptor: nil)))
        }
    }

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
            title: "Matrix Fixture",
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

    private func indirect(
        _ type: String,
        _ children: [TPPOPDSIndirectAcquisition] = []
    ) -> TPPOPDSIndirectAcquisition {
        TPPOPDSIndirectAcquisition(type: type, indirectAcquisitions: children)
    }

    // MARK: - Production-mirroring adapter chain factories

    /// Build a chain whose `canHandle` predicates exactly mirror
    /// `AudiobookLoader.makeProductionAdapters()`. The returned spies are
    /// directly inspectable for `resolveCallCount`.
    private func makeProductionChainSpies() -> (
        lcp: PredicateSpyAdapter?,
        localFile: PredicateSpyAdapter,
        bearerToken: PredicateSpyAdapter,
        openAccess: PredicateSpyAdapter,
        chain: [AudiobookVendorAdapter]
    ) {
        // No local files in any fixture — local always declines.
        let localFile = PredicateSpyAdapter(label: "local", predicate: { _ in false })

        // BearerToken's production placement is MIME-gated (see
        // BearerTokenMIMEGate). We mirror the gate here.
        let bearerToken = PredicateSpyAdapter(label: "bearer", predicate: { [bearerTokenMIME] book in
            book.defaultAcquisition?.type == bearerTokenMIME
        })

        // OpenAccess always claims (fallback).
        let openAccess = PredicateSpyAdapter(label: "open", predicate: { _ in true })

#if LCP
        // LCP uses the recursive predicate Module C ported.
        let lcp = PredicateSpyAdapter(label: "lcp", predicate: { book in
            LCPAudiobooks.hasLCPAcquisition(book)
        })
        return (lcp, localFile, bearerToken, openAccess,
                [lcp, localFile, bearerToken, openAccess])
#else
        return (nil, localFile, bearerToken, openAccess,
                [localFile, bearerToken, openAccess])
#endif
    }

    /// Build a chain whose LCP predicate uses the OLD top-level-only
    /// `canOpenBook` instead of the recursive `hasLCPAcquisition`. This
    /// is the "property-check loader" the meta-test exercises to prove
    /// the architectural improvement.
    private func makePropertyCheckChainSpies() -> (
        lcp: PredicateSpyAdapter?,
        openAccess: PredicateSpyAdapter,
        chain: [AudiobookVendorAdapter]
    ) {
        let localFile = PredicateSpyAdapter(label: "local", predicate: { _ in false })
        let bearerToken = PredicateSpyAdapter(label: "bearer", predicate: { [bearerTokenMIME] book in
            book.defaultAcquisition?.type == bearerTokenMIME
        })
        let openAccess = PredicateSpyAdapter(label: "open", predicate: { _ in true })

#if LCP
        // Property-check predicate — TOP-LEVEL only (the pre-swarm bug).
        let lcp = PredicateSpyAdapter(label: "lcp-property-check", predicate: { book in
            LCPAudiobooks.canOpenBook(book)
        })
        return (lcp, openAccess, [lcp, localFile, bearerToken, openAccess])
#else
        return (nil, openAccess, [localFile, bearerToken, openAccess])
#endif
    }

    /// Drive `load()` and tolerate downstream `build()` failure — we only
    /// care which adapter's `resolveManifest` is invoked.
    private func runLoad(book: TPPBook, chain: [AudiobookVendorAdapter]) {
        let loader = AudiobookLoader(adapters: chain)
        let exp = expectation(description: "load completes")
        exp.assertForOverFulfill = false
        loader.load(book) { _ in exp.fulfill() }
        wait(for: [exp], timeout: 5.0)
    }

    // MARK: - The matrix

#if LCP
    /// Row 1 — `/loans/` XML feed shape: LCP license MIME is at the
    /// acquisition's TOP-LEVEL `type`. This is the legacy / classic path
    /// PP-4407 worked fine on. Both the recursive predicate and the
    /// property-check predicate agree on TRUE here, so routing is
    /// identical: LCP wins.
    func testMatrix_OPDS1XMLFeedTopLevelLCP_routesToLCP() {
        let book = makeBook(acquisitions: [
            acquisition(
                type: lcpLicenseMIME,
                indirect: [indirect(audiobookLCPMIME)]
            )
        ])
        let spies = makeProductionChainSpies()

        runLoad(book: book, chain: spies.chain)

        XCTAssertEqual(spies.lcp?.resolveCallCount, 1,
                       "XML /loans/ shape with top-level LCP MIME must route to LCP adapter")
        XCTAssertEqual(spies.bearerToken.resolveCallCount, 0, "BearerToken must NOT claim this fixture")
        XCTAssertEqual(spies.openAccess.resolveCallCount, 0, "OpenAccess must NOT claim this fixture")
    }

    /// Row 2 — `/groups/` JSON feed shape: LCP license MIME is NESTED in
    /// `indirectAcquisitions[*].type`. Top-level type is
    /// `application/opds-publication+json`. The PRODUCTION recursive
    /// predicate (`hasLCPAcquisition`) catches this; the property-check
    /// predicate misses it. The production chain MUST route to LCP.
    ///
    /// **THIS IS THE PP-4407 REGRESSION KILL POINT** — commit `ca2ff13b6`
    /// on the 3.0.3 release branch (never forward-merged to develop). If
    /// this test ever fails, the Marketplace audiobook open regression has
    /// reopened.
    func testMatrix_OPDS2JSONFeedNestedLCP_routesToLCP() {
        // PP-4407 / commit ca2ff13b6: Marketplace OPDS-2 JSON shape.
        let book = makeBook(acquisitions: [
            acquisition(
                type: opdsPublicationMIME,
                indirect: [
                    indirect(lcpLicenseMIME, [indirect(audiobookLCPMIME)])
                ]
            )
        ])
        let spies = makeProductionChainSpies()

        runLoad(book: book, chain: spies.chain)

        XCTAssertEqual(spies.lcp?.resolveCallCount, 1,
                       "JSON /groups/ shape with nested LCP MIME must route to LCP — PP-4407 kill point (commit ca2ff13b6)")
        XCTAssertEqual(spies.openAccess.resolveCallCount, 0,
                       "OpenAccess must NOT claim this Marketplace fixture — that was the PP-4407 misroute")
        XCTAssertEqual(spies.bearerToken.resolveCallCount, 0,
                       "BearerToken must NOT claim this fixture")
    }

    /// Row 3 — META-TEST. **Retired by swarm_162a3219 / Module D1.**
    ///
    /// This row originally pinned `canOpenBook`'s narrow top-level
    /// predicate misrouting Marketplace fixtures to OpenAccess (the
    /// PP-4407 bug). Module D1 (swarm_162a3219) upgraded `canOpenBook`
    /// to delegate to `hasLCPAcquisition` — eliminating the divergence.
    /// Per the original author's documented contingency (case (a)):
    /// "Row 2 already catches the regression and this row is redundant."
    ///
    /// Row 2 (`testMatrix_OPDS2JSONFeedNestedLCP_routesToLCPAdapter`)
    /// remains as the PP-4407 kill point. Row 3 deleted to honor the
    /// author's explicit guidance.
#endif

    /// Row 4 — Findaway-typed manifest. Findaway DRM is handled inside
    /// PalaceAudiobookToolkit; from Palace's adapter perspective, a
    /// Findaway book is shaped like a regular OpenAccess audiobook
    /// record (the toolkit picks up Findaway from `manifest.@type` at
    /// `build()` time). The loader's chain MUST route this to
    /// OpenAccessAdapter — never LCP, never BearerToken.
    func testMatrix_findawayTypedManifest_routesToOpenAccessAdapter() {
        let book = makeBook(acquisitions: [
            acquisition(type: findawayMIME)
        ])
        let spies = makeProductionChainSpies()

        runLoad(book: book, chain: spies.chain)

#if LCP
        XCTAssertEqual(spies.lcp?.resolveCallCount, 0,
                       "Findaway-typed book must NOT route to LCP — Findaway is toolkit-side, not Palace-side LCP")
#endif
        XCTAssertEqual(spies.bearerToken.resolveCallCount, 0,
                       "Findaway book has no bearer-token MIME — BearerToken must NOT claim")
        XCTAssertEqual(spies.openAccess.resolveCallCount, 1,
                       "Findaway book must route to OpenAccessAdapter — toolkit-side AudiobookFactory picks Findaway during build()")
    }

    /// Row 5 — open-access audiobook with a bearer-token wrapper at the
    /// top-level acquisition `type`. Routes to BearerTokenAdapter (the
    /// MIME-gated adapter in the production chain).
    func testMatrix_openAccessWithBearerToken_routesToBearerTokenAdapter() {
        let book = makeBook(acquisitions: [
            acquisition(type: bearerTokenMIME)
        ])
        let spies = makeProductionChainSpies()

        runLoad(book: book, chain: spies.chain)

#if LCP
        XCTAssertEqual(spies.lcp?.resolveCallCount, 0,
                       "Bearer-token book without LCP MIME must NOT route to LCP")
#endif
        XCTAssertEqual(spies.bearerToken.resolveCallCount, 1,
                       "Bearer-token MIME at top level must route to BearerTokenAdapter")
        XCTAssertEqual(spies.openAccess.resolveCallCount, 0,
                       "BearerToken MIME-gate wins before OpenAccess fallback")
    }

    /// Row 6 — plain open-access audiobook, no DRM, no bearer-token.
    /// Routes to OpenAccessAdapter (the chain's fallback). This pins
    /// the "do nothing fancy" base case — a regression that accidentally
    /// MIME-matched everything would short-circuit OpenAccess and fail
    /// this test.
    func testMatrix_openAccessNoDRM_routesToOpenAccessAdapter() {
        let book = makeBook(acquisitions: [
            acquisition(type: openAccessAudiobookMIME)
        ])
        let spies = makeProductionChainSpies()

        runLoad(book: book, chain: spies.chain)

#if LCP
        XCTAssertEqual(spies.lcp?.resolveCallCount, 0,
                       "Plain open-access book must NOT route to LCP — no LCP MIME anywhere in the chain")
#endif
        XCTAssertEqual(spies.bearerToken.resolveCallCount, 0,
                       "Plain open-access book has no bearer-token MIME — BearerToken must NOT claim")
        XCTAssertEqual(spies.openAccess.resolveCallCount, 1,
                       "Plain open-access book must route to OpenAccessAdapter (chain fallback)")
    }

    // MARK: - Red-first hermetic-guard proof
    //
    // Pins the mechanism the setUp guard relies on: an EXPIRED token in the
    // shared account trips AudiobookLoader's pre-chain token gate (skipping the
    // adapter chain → resolveCallCount 0), and clearing it via the production
    // removeAll() restores routing. Stub the clear to a no-op and this test goes
    // red (authTokenHasExpired stays true + resolveCallCount 0) — that's the
    // red-first guarantee that the hermetic reset is load-bearing.
    func testHermeticGuard_clearingExpiredToken_unblocksAdapterRouting() {
        let account = AppContainer.production().accountsManager.currentUserAccount
        account.setAuthToken("stale-token", barcode: "b", pin: "p",
                             expirationDate: Date(timeIntervalSinceNow: -3600)) // expired 1h ago
        XCTAssertTrue(account.authTokenHasExpired,
                      "Precondition: an expired token is present (the inherited-dirty-start condition)")

        // The guard under test — the production sign-out/clear API.
        account.removeAll()

        XCTAssertFalse(account.authTokenHasExpired,
                       "removeAll() must clear the expired token so the token gate no longer trips")

        let book = makeBook(acquisitions: [acquisition(type: openAccessAudiobookMIME)])
        let spies = makeProductionChainSpies()
        runLoad(book: book, chain: spies.chain)

        XCTAssertEqual(spies.openAccess.resolveCallCount, 1,
                       "With auth state cleared, the loader's token gate passes and the adapter chain routes (no longer skipped)")
    }
}
