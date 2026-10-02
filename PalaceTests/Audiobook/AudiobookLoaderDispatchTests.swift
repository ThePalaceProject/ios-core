//
//  AudiobookLoaderDispatchTests.swift
//  PalaceTests
//
//  Dispatch tests for the AudiobookLoader adapter chain. Module D of
//  swarm_5c8ddbd5 (Audiobook Vendor Adapter Extraction) rewrote the loader's
//  source-shape dispatch from two implicit branches inside
//  `resolveManifestAndDecryptor` + `fetchOpenAccessManifest` into a single
//  linear chain:
//
//      let adapter = adapters.first(where: { $0.canHandle(book) })
//
//  These tests inject a custom adapter chain (via `AudiobookLoader(adapters:)`)
//  and assert the loader dispatches to the right adapter for each shape:
//  LCP > LocalFile > BearerToken > OpenAccess. If no adapter claims, the
//  loader surfaces `.manifestFetchFailed` (preserving the pre-swarm
//  "no default acquisition URL" failure mode).
//
//  The `load(book:completion:)` public API is FROZEN — these tests gate the
//  call path AudiobookSessionManager.swift:321 depends on.
//
//  Companion to:
//    - AudiobookLoaderOPDSShapeMatrixTests.swift (PP-4407 regression matrix)
//    - AudiobookLoaderPredicateTests.swift (extracted helpers)
//    - AudiobookLoaderTests.swift (public API contract — cancel + error)
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@preconcurrency import PalaceAudiobookToolkit
@testable import Palace
import PalaceBookModel

@MainActor
final class AudiobookLoaderDispatchTests: XCTestCase {

    // MARK: - Spy adapter

    /// Spy conforming to `AudiobookVendorAdapter`. Pre-program whether the
    /// adapter claims the book and what its `resolveManifest` returns; the
    /// spy records every invocation so the test can assert dispatch order.
    private final class SpyAdapter: AudiobookVendorAdapter {
        let label: String
        var handles: Bool
        var stubbedResult: Result<(json: [String: Any], decryptor: DRMDecryptor?), AudiobookLoadError>
        private(set) var canHandleCallCount = 0
        private(set) var resolveCallCount = 0

        init(
            label: String,
            handles: Bool,
            stubbedResult: Result<(json: [String: Any], decryptor: DRMDecryptor?), AudiobookLoadError>
        ) {
            self.label = label
            self.handles = handles
            self.stubbedResult = stubbedResult
        }

        func canHandle(_ book: TPPBook) -> Bool {
            canHandleCallCount += 1
            return handles
        }

        func resolveManifest(
            for book: TPPBook,
            completion: @escaping (Result<(json: [String: Any], decryptor: DRMDecryptor?), AudiobookLoadError>) -> Void
        ) {
            resolveCallCount += 1
            completion(stubbedResult)
        }
    }

    // MARK: - Fixture helpers

    /// JSON shaped as the chain would receive it from an open-access
    /// adapter. The bytes don't matter for dispatch — we only assert which
    /// adapter is invoked. Manifest decoding (in `build()`) is exercised
    /// by AudiobookLoaderFinalizeBuildTests and intentionally allowed to
    /// fail here; we assert the dispatch result through `resolveCallCount`.
    private let manifestStub: [String: Any] = ["@type": "Audiobook", "title": "Stub"]

    /// Standard non-LCP, non-bearer-token, non-local audiobook fixture
    /// used as the dispatch trigger.
    private func makeBook() -> TPPBook {
        return TPPBookMocker.mockBook(distributorType: .OpenAccessAudiobook)
    }

    /// Drive `load()` and capture the result. The dispatch is async — we
    /// fulfill the expectation when the loader's outer completion fires.
    /// `manifestStub` is intentionally not a real audiobook manifest, so a
    /// success result from the adapter chain will subsequently fail in
    /// `build()` (manifest decoding); we tolerate that and only assert
    /// adapter invocation counts.
    private func runLoad(
        loader: AudiobookLoader,
        book: TPPBook,
        timeout: TimeInterval = 5.0
    ) -> Result<LoadedAudiobook, AudiobookLoadError>? {
        let exp = expectation(description: "load completes")
        exp.assertForOverFulfill = false
        var captured: Result<LoadedAudiobook, AudiobookLoadError>?
        loader.load(book) { result in
            captured = result
            exp.fulfill()
        }
        wait(for: [exp], timeout: timeout)
        return captured
    }

    // MARK: - Dispatch routing tests

#if LCP
    /// LCP fixture flows through the LCP adapter, NOT through any later
    /// adapter in the chain. The chain order is LCP > Local > Bearer >
    /// OpenAccess; LCP's `canHandle` returning true must short-circuit
    /// every downstream `canHandle`.
    func testLoad_lcpBook_dispatchesToLCPAdapter() {
        let lcp = SpyAdapter(label: "lcp", handles: true,
                             stubbedResult: .success((json: manifestStub, decryptor: nil)))
        let localFile = SpyAdapter(label: "local", handles: true,
                                   stubbedResult: .success((json: manifestStub, decryptor: nil)))
        let bearerToken = SpyAdapter(label: "bearer", handles: true,
                                     stubbedResult: .success((json: manifestStub, decryptor: nil)))
        let openAccess = SpyAdapter(label: "open", handles: true,
                                    stubbedResult: .success((json: manifestStub, decryptor: nil)))
        let loader = AudiobookLoader(adapters: [lcp, localFile, bearerToken, openAccess])

        _ = runLoad(loader: loader, book: makeBook())

        XCTAssertEqual(lcp.resolveCallCount, 1, "LCP adapter must be invoked when it claims the book")
        XCTAssertEqual(localFile.resolveCallCount, 0, "LocalFile must NOT run once LCP wins")
        XCTAssertEqual(bearerToken.resolveCallCount, 0, "BearerToken must NOT run once LCP wins")
        XCTAssertEqual(openAccess.resolveCallCount, 0, "OpenAccess must NOT run once LCP wins")
        XCTAssertEqual(localFile.canHandleCallCount, 0,
                       "Chain must short-circuit — downstream canHandle is NOT consulted after a win")
    }
#endif

    /// LocalFile fixture: LCP declines (gated #if LCP — when LCP is on, we
    /// still put a non-claiming LCP spy first to assert chain order; when
    /// LCP is off, the chain starts at LocalFile). LocalFile claims, and
    /// its `resolveManifest` is the one invoked.
    func testLoad_localFileBook_dispatchesToLocalFileAdapter() {
        let localFile = SpyAdapter(label: "local", handles: true,
                                   stubbedResult: .success((json: manifestStub, decryptor: nil)))
        let bearerToken = SpyAdapter(label: "bearer", handles: true,
                                     stubbedResult: .success((json: manifestStub, decryptor: nil)))
        let openAccess = SpyAdapter(label: "open", handles: true,
                                    stubbedResult: .success((json: manifestStub, decryptor: nil)))

#if LCP
        let lcp = SpyAdapter(label: "lcp", handles: false,
                             stubbedResult: .failure(.lcpNotAvailable))
        let loader = AudiobookLoader(adapters: [lcp, localFile, bearerToken, openAccess])
#else
        let loader = AudiobookLoader(adapters: [localFile, bearerToken, openAccess])
#endif

        _ = runLoad(loader: loader, book: makeBook())

        XCTAssertEqual(localFile.resolveCallCount, 1,
                       "LocalFile adapter must be invoked when it claims the book")
        XCTAssertEqual(bearerToken.resolveCallCount, 0, "BearerToken must NOT run once LocalFile wins")
        XCTAssertEqual(openAccess.resolveCallCount, 0, "OpenAccess must NOT run once LocalFile wins")
    }

    /// BearerToken fixture: LCP + LocalFile both decline; BearerToken
    /// claims. Pins the chain's middle-position adapter doesn't get skipped
    /// by a regression that flips `.first(where:)` to a naïve `for in`.
    func testLoad_bearerTokenBook_dispatchesToBearerTokenAdapter() {
        let localFile = SpyAdapter(label: "local", handles: false,
                                   stubbedResult: .failure(.manifestParseFailed))
        let bearerToken = SpyAdapter(label: "bearer", handles: true,
                                     stubbedResult: .success((json: manifestStub, decryptor: nil)))
        let openAccess = SpyAdapter(label: "open", handles: true,
                                    stubbedResult: .success((json: manifestStub, decryptor: nil)))

#if LCP
        let lcp = SpyAdapter(label: "lcp", handles: false,
                             stubbedResult: .failure(.lcpNotAvailable))
        let loader = AudiobookLoader(adapters: [lcp, localFile, bearerToken, openAccess])
#else
        let loader = AudiobookLoader(adapters: [localFile, bearerToken, openAccess])
#endif

        _ = runLoad(loader: loader, book: makeBook())

        XCTAssertEqual(bearerToken.resolveCallCount, 1,
                       "BearerToken adapter must be invoked when it claims the book")
        XCTAssertEqual(openAccess.resolveCallCount, 0,
                       "OpenAccess must NOT run once BearerToken wins")
        XCTAssertEqual(localFile.canHandleCallCount, 1,
                       "LocalFile is asked exactly once before declining")
    }

    /// OpenAccess fixture: every earlier adapter declines; the fallback
    /// OpenAccess claims. Pins that the chain's terminal adapter is reachable
    /// after all earlier declines.
    func testLoad_openAccessBook_dispatchesToOpenAccessAdapter() {
        let localFile = SpyAdapter(label: "local", handles: false,
                                   stubbedResult: .failure(.manifestParseFailed))
        let bearerToken = SpyAdapter(label: "bearer", handles: false,
                                     stubbedResult: .failure(.manifestFetchFailed))
        let openAccess = SpyAdapter(label: "open", handles: true,
                                    stubbedResult: .success((json: manifestStub, decryptor: nil)))

#if LCP
        let lcp = SpyAdapter(label: "lcp", handles: false,
                             stubbedResult: .failure(.lcpNotAvailable))
        let loader = AudiobookLoader(adapters: [lcp, localFile, bearerToken, openAccess])
#else
        let loader = AudiobookLoader(adapters: [localFile, bearerToken, openAccess])
#endif

        _ = runLoad(loader: loader, book: makeBook())

        XCTAssertEqual(openAccess.resolveCallCount, 1,
                       "OpenAccess (fallback) must be invoked when no earlier adapter claims")
        XCTAssertEqual(localFile.canHandleCallCount, 1,
                       "LocalFile is asked before declining")
        XCTAssertEqual(bearerToken.canHandleCallCount, 1,
                       "BearerToken is asked before declining")
    }

#if LCP
    /// Priority test: a book where BOTH LCP and LocalFile (and BearerToken
    /// and OpenAccess) would claim. LCP must win regardless of what comes
    /// after. This is the regression gate for any chain-reordering
    /// refactor — if a future change accidentally moves LCP behind another
    /// adapter (e.g. because adapter construction order changed), Marketplace
    /// audiobooks that ALSO happen to have a local cache would be misrouted.
    func testLoad_lcpPriorityOverOthers() {
        let lcp = SpyAdapter(label: "lcp", handles: true,
                             stubbedResult: .success((json: manifestStub, decryptor: nil)))
        let localFile = SpyAdapter(label: "local", handles: true,
                                   stubbedResult: .success((json: manifestStub, decryptor: nil)))
        let bearerToken = SpyAdapter(label: "bearer", handles: true,
                                     stubbedResult: .success((json: manifestStub, decryptor: nil)))
        let openAccess = SpyAdapter(label: "open", handles: true,
                                    stubbedResult: .success((json: manifestStub, decryptor: nil)))
        let loader = AudiobookLoader(adapters: [lcp, localFile, bearerToken, openAccess])

        _ = runLoad(loader: loader, book: makeBook())

        XCTAssertEqual(lcp.resolveCallCount, 1,
                       "LCP wins when multiple adapters would claim — priority order is load-bearing")
        XCTAssertEqual(localFile.resolveCallCount, 0,
                       "LocalFile must NOT run even though it would claim — LCP has priority")
        XCTAssertEqual(bearerToken.resolveCallCount, 0,
                       "BearerToken must NOT run — LCP has priority")
        XCTAssertEqual(openAccess.resolveCallCount, 0,
                       "OpenAccess must NOT run — LCP has priority")
    }
#endif

    /// No adapter claims the book — the loader surfaces `.manifestFetchFailed`.
    /// This is the pre-swarm "no default acquisition URL" failure mode
    /// preserved verbatim. Without this assertion, a regression that
    /// changed the fallback to `.manifestParseFailed` (or worse, succeeded
    /// silently) would not be caught.
    func testLoad_noAdapterMatches_failsWithManifestFetchFailed() {
        let localFile = SpyAdapter(label: "local", handles: false,
                                   stubbedResult: .failure(.manifestParseFailed))
        let openAccess = SpyAdapter(label: "open", handles: false,
                                    stubbedResult: .failure(.manifestFetchFailed))
        let loader = AudiobookLoader(adapters: [localFile, openAccess])

        let result = runLoad(loader: loader, book: makeBook())

        guard case .failure(let err) = result ?? .failure(.cancelled) else {
            XCTFail("expected failure when no adapter claims, got \(String(describing: result))")
            return
        }
        guard case .manifestFetchFailed = err else {
            XCTFail("expected .manifestFetchFailed, got \(err)")
            return
        }
        XCTAssertEqual(localFile.canHandleCallCount, 1, "Every adapter is asked before fallback fires")
        XCTAssertEqual(openAccess.canHandleCallCount, 1, "Every adapter is asked before fallback fires")
        XCTAssertEqual(localFile.resolveCallCount, 0, "No adapter's resolveManifest is invoked on whole-chain miss")
        XCTAssertEqual(openAccess.resolveCallCount, 0, "No adapter's resolveManifest is invoked on whole-chain miss")
    }

    /// Cancellation between adapter selection and `resolveManifest`: the
    /// loader's outer completion must surface `.cancelled`, not whatever
    /// the adapter would have returned. This pins the cancel() seam — a
    /// regression that forgot to check `isCancelled` in the final
    /// completion hop would leak adapter results to a discarded loader.
    func testLoad_cancelDuringDispatch_surfacesCancelled() {
        let openAccess = SpyAdapter(label: "open", handles: true,
                                    stubbedResult: .success((json: manifestStub, decryptor: nil)))
        let loader = AudiobookLoader(adapters: [openAccess])

        let exp = expectation(description: "load completes")
        exp.assertForOverFulfill = false
        var seenError: AudiobookLoadError?
        loader.cancel()
        loader.load(makeBook()) { result in
            if case .failure(let err) = result { seenError = err }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5.0)

        guard case .cancelled = seenError else {
            XCTFail("expected .cancelled when loader is cancelled before dispatch, got \(String(describing: seenError))")
            return
        }
    }

    // MARK: - PP-5299 — token-refresh delivery must reach the main actor

    // These assert the delivery CONTEXT *and* the delivered VALUE. Context alone
    // leaves `fire(true)`/`fire(false)` interchangeable, and swapping them opens
    // the audiobook with a still-expired token (the PP-4542 failure mode).
    //
    // Both branches are pinned rather than left to inherited simulator state.
    // `awaitTokenReady` polls `authTokenHasExpired` on the production shared
    // account, so without a reset the branch taken depends on what a previous
    // suite left in the keychain — which is why an earlier run of this test took
    // 1.132s (deadline branch) and the next 0.002s (token-already-valid branch).
    // Same hazard the sibling suite documents at
    // AudiobookLoaderOPDSShapeMatrixTests's hermetic auth-state guard.

    /// Token already valid: the poll fires on its first iteration with `true`.
    func testAwaitTokenReady_tokenAlreadyValid_deliversTrueOnTheMainActor() async throws {
        try KeychainAvailability.skipIfUnavailable()
        let account = AppContainer.production().accountsManager.currentUserAccount
        account.removeAll()
        XCTAssertFalse(account.authTokenHasExpired,
                       "Precondition: no credentials means the token does not read as expired")

        let delivered = expectation(description: "awaitTokenReady fired")
        AudiobookLoader.awaitTokenReady(timeout: 2.0, pollInterval: 0.05) { becameValid in
            XCTAssertTrue(Thread.isMainThread,
                          "delivered off the main thread; the caller continues into @MainActor work and will trap")
            XCTAssertTrue(becameValid,
                          "the token is valid, so the poll must report true, not the deadline value")
            delivered.fulfill()
        }
        await fulfillment(of: [delivered], timeout: 5.0)
        account.removeAll()
    }

    /// Token expired for the whole window: the poll reaches its deadline and
    /// fires `false`. Pins the other arm of the same `fire` funnel.
    func testAwaitTokenReady_tokenStaysExpired_deliversFalseOnTheMainActor() async throws {
        try KeychainAvailability.skipIfUnavailable()
        let account = AppContainer.production().accountsManager.currentUserAccount
        account.removeAll()
        account.setAuthToken("stale-token", barcode: "b", pin: "p",
                             expirationDate: Date(timeIntervalSinceNow: -3600))
        XCTAssertTrue(account.authTokenHasExpired,
                      "Precondition: the token must read as expired for the deadline branch")

        let delivered = expectation(description: "awaitTokenReady reached its deadline")
        AudiobookLoader.awaitTokenReady(timeout: 0.2, pollInterval: 0.05) { becameValid in
            XCTAssertTrue(Thread.isMainThread, "deadline branch delivered off the main thread")
            XCTAssertFalse(becameValid,
                           "the token never became valid, so the poll must report false")
            delivered.fulfill()
        }
        await fulfillment(of: [delivered], timeout: 5.0)
        account.removeAll()
    }

    /// The carrier the FIELD crash walked. `refreshTokenIfNeeded`'s two direct
    /// executor-callback exits deliver through `RefreshOutcomeDelivery`, and those
    /// are the exits the Crashlytics stack and log show ("Token refresh successful
    /// - proceeding to open audiobook" then the trap). Constructing it off-main is
    /// exactly the executor's situation.
    ///
    /// Empty `deliverOnMain()`'s body and this fails on the timeout — which is the
    /// mutant that otherwise hangs an audiobook open forever with no error.
    /// Drop `@MainActor` from its inner Task and it fails on the thread assertion.
    func testRefreshOutcomeDelivery_firedOffMain_deliversOnTheMainActorWithTheOutcome() async {
        let delivered = expectation(description: "the carrier delivered")
        let sut = RefreshOutcomeDelivery({ result in
            XCTAssertTrue(Thread.isMainThread,
                          "the carrier exists to hop; delivering off-main reproduces PP-5299")
            guard case .failure(.missingCredentialsForTokenRefresh) = result else {
                return XCTFail("the outcome must survive the hop unchanged, got \(result)")
            }
            delivered.fulfill()
        }, outcome: .failure(.missingCredentialsForTokenRefresh))

        // Detached so the construction and the fire both happen off the main
        // actor, as they do when the executor's Task calls back.
        await Task.detached {
            XCTAssertFalse(Thread.isMainThread, "precondition: firing from off-main")
            sut.deliverOnMain()
        }.value

        await fulfillment(of: [delivered], timeout: 5.0)
    }
}
