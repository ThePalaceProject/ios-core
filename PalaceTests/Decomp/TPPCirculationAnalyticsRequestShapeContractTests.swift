//
//  TPPCirculationAnalyticsRequestShapeContractTests.swift
//  PalaceTests
//
//  PRE-WAVE gate test for the god-class decomposition campaign — Wave 1c
//  (misfiles + inversions). See docs/architecture/god-class-decomposition-plan.md
//  §4 Wave 1c and §3b cycle 3.
//
//  Target: `Palace/Logging/TPPCirculationAnalytics.swift` — a circulation-domain
//  network client MISFILED under `Logging`. Wave 1c relocates it out of the
//  Logging folder (killing folder-cycle #3, Logging↔Network). The move is a
//  pure file relocation, so the pre-wave test must pin the analytics request
//  SHAPE (URL / HTTP method / what the offline path enqueues) so the relocation
//  is provably behavior-preserving.
//
//  ─────────────────────────────────────────────────────────────────────────
//  // SEAM: the request shape is NOT deterministically observable through the
//  //       current public surface. Two independent production seams block a
//  //       live contract snapshot; BOTH are read-only observations here (this
//  //       pack makes no production edits):
//  //
//  //   1. The only injectable method is `private static addToOfflineAnalytics
//  //      Queue(_:_:accountsManager:networkExecutor:)` — it already carries the
//  //      exact default-arg seams the wave brief points at
//  //      (`accountsManager:`, `networkExecutor:`) — but it is `private static`.
//  //      `@testable import Palace` elevates `internal`, NOT `private`, so the
//  //      method (and its spy-injectable params) cannot be called from a test.
//  //
//  //   2. The outbound event request in `post(_:withURL:)` is sent on a
//  //      SELF-CREATED `URLSession(configuration: .ephemeral)`. A custom-config
//  //      session consults ONLY `config.protocolClasses` — it ignores globally
//  //      registered `URLProtocol`s. This is documented in-repo at
//  //      `PalaceTests/PalaceTestSetup.swift` (~L50-57): "the SHARED
//  //      TPPNetworkExecutor builds its own URLSession(configuration:), which
//  //      consults only config.protocolClasses". So neither `HTTPStubURLProtocol`
//  //      (scoped to `URLSession.stubbedSession()`) nor `NoNetworkURLProtocol`
//  //      (global) can intercept it — the request would escape to the real
//  //      network in a unit test. There is no injection point for the session.
//  //
//  //   Consequence: the request shape cannot be pinned as a passing gate today
//  //   without either (a) making `addToOfflineAnalyticsQueue` `internal` (or
//  //   `package`) so spies inject via its existing default args, OR (b) taking
//  //   the `URLSession`/`TPPNetworkExecutor` as an injected seam on `post`.
//  //   The RECOMMENDATION for Wave 1c is to bundle seam (a) — a one-token
//  //   `private` → `internal` change — WITH the file move, then delete the
//  //   `XCTSkip` below so the spy-based contract snapshot goes live in the same
//  //   PR that relocates the file. Per CLAUDE.md's contract-test guidance:
//  //   "the inability to write the test IS the test feedback."
//  ─────────────────────────────────────────────────────────────────────────
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

@MainActor
final class TPPCirculationAnalyticsRequestShapeContractTests: XCTestCase {

    /// CONTRACT (to be pinned once the Wave-1c seam lands): the offline-retry
    /// enqueue shape of a failed analytics event. `addToOfflineAnalyticsQueue`
    /// must enqueue exactly:
    ///
    ///   networkQueue.addRequest(
    ///     libraryID: accountsManager.currentAccount?.uuid ?? "",   // "" when no account
    ///     updateID:  nil,
    ///     url:       <book.analyticsURL / event>,                  // the event URL
    ///     method:    .GET,
    ///     parameters: nil,
    ///     headers:   networkExecutor.request(for: url).allHTTPHeaderFields
    ///   )
    ///
    /// and the outbound live request in `post` must be an HTTP **GET** to
    /// `book.analyticsURL.appendingPathComponent(event)`.
    ///
    /// Once seam (a) exists, the live body is:
    ///
    ///   let netExec = SpyNetworkExecutor()           // records request(for:)
    ///   let accounts = SpyAccountsManager(uuid: "lib-uuid")
    ///   let url = URL(string: "https://analytics.example.org/events/open_book")!
    ///   TPPCirculationAnalytics.addToOfflineAnalyticsQueue(
    ///       "open_book", url, accountsManager: accounts, networkExecutor: netExec)
    ///   // then assert the CallLog snapshot of netExec + the enqueued request.
    ///   ContractSnapshot.assert(log, named: "offlineEnqueue_GET_open_book")
    ///
    /// NOTE while writing that body: `addToOfflineAnalyticsQueue` still calls
    /// `AppContainer.production().networkQueue.addRequest(...)` for the actual
    /// enqueue (only the header/libraryID derivation is injected). Pinning
    /// "what it enqueues" therefore ALSO requires the `networkQueue` to become
    /// an injected seam — otherwise the snapshot's enqueue leg hits the live
    /// container. Flag this to the Wave-1c implementer: the enqueue call itself
    /// is the third, still-uninjected dependency.
    func testOfflineEnqueue_pinnedRequestShape_GET_withLibraryHeaders() throws {
        throw XCTSkip("""
            SEAM (Wave 1c): TPPCirculationAnalytics exposes no reachable test seam. \
            `addToOfflineAnalyticsQueue(_:_:accountsManager:networkExecutor:)` is \
            private static (unreachable via @testable), and `post`'s ephemeral \
            URLSession(configuration:) ignores globally-registered URLProtocols \
            (see PalaceTests/PalaceTestSetup.swift ~L50-57), so the event request \
            cannot be intercepted. Make the method internal (and inject the \
            networkQueue) alongside the relocation, then remove this skip to \
            activate the spy-based ContractSnapshot documented above. This test \
            is a deliberate placeholder that names the exact production change \
            required — it must not be deleted without landing that change.
            """)
    }

    // LATENT-BUG NOTE (discovered while characterizing, reported not fixed):
    // `handleFailure` gates the offline enqueue on
    //   NetworkQueue.StatusCodes.contains(httpResponse.statusCode)
    // but `NetworkQueue.StatusCodes` are NEGATIVE NSURLError codes (e.g.
    // NSURLErrorTimedOut) while `httpResponse.statusCode` is a POSITIVE HTTP
    // status. The two sets never intersect, so this `if` can never be true for
    // a real HTTPURLResponse — the HTTP-response enqueue branch is effectively
    // dead. The timeout branch in `post` (NSURLErrorTimedOut) is the only path
    // that reaches `addToOfflineAnalyticsQueue`. When the seam lands, the live
    // contract should pin the timeout path, not a synthetic HTTP-status path.
}
