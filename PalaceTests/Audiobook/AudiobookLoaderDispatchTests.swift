//
//  AudiobookLoaderDispatchTests.swift
//
//  The loader dispatches through one linear adapter chain
//  (`adapters.first(where: { $0.canHandle(book) })`). These tests inject a
//  chain via `AudiobookLoader(adapters:)` and assert the order LCP > LocalFile
//  > BearerToken > OpenAccess, with `.manifestFetchFailed` when none claims.
//  `load(book:completion:)` is frozen; AudiobookSessionManager depends on it.
//  Every loader here gets its own account through `makeLoader`, so the
//  pre-chain token gate never reads the shared container (PP-5295).
//  See also AudiobookLoaderOPDSShapeMatrixTests and AudiobookLoaderPredicateTests.
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

    /// Shared account a test wrote to; cleared in tearDown so the seeded
    /// expired token cannot reach a later test.
    private var seededSharedAccount: TPPUserAccount?

    override func tearDownWithError() throws {
        seededSharedAccount?.removeAll()
        seededSharedAccount = nil
        try super.tearDownWithError()
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

    /// Loader whose token gate reads `account` instead of the shared
    /// container's current account (PP-5295). The default is a keychain-free
    /// mock with no credentials, so the gate passes and the chain runs no
    /// matter what an earlier test left on the shared account.
    private func makeLoader(
        _ adapters: [AudiobookVendorAdapter],
        account: TPPUserAccount = TPPUserAccountMock()
    ) -> AudiobookLoader {
        AudiobookLoader(adapters: adapters, currentUserAccount: { account })
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

    // MARK: - Token gate reads the injected account (PP-5295)

    /// An expired token with no token URL to refresh against fails the load
    /// with `.missingCredentialsForTokenRefresh` before any adapter is asked.
    func testLoad_injectedAccountExpiredWithoutTokenURL_failsBeforeAnyAdapter() {
        let expired = TPPUserAccountMock()
        expired.setAuthToken("stale", barcode: "b", pin: "p",
                             expirationDate: Date(timeIntervalSinceNow: -3600))
        let openAccess = SpyAdapter(label: "open", handles: true,
                                    stubbedResult: .success((json: manifestStub, decryptor: nil)))
        let loader = makeLoader([openAccess], account: expired)

        let result = runLoad(loader: loader, book: makeBook())

        guard case .failure(.missingCredentialsForTokenRefresh) = result else {
            XCTFail("expected .missingCredentialsForTokenRefresh, got \(String(describing: result))")
            return
        }
        XCTAssertEqual(openAccess.canHandleCallCount, 0,
                       "The token gate fails before the adapter chain is consulted")
    }

    /// The shared container's current account holds an expired token (the
    /// state an earlier test can leave behind), but the loader was given a
    /// clean account. The gate must read the injected one and dispatch.
    func testLoad_sharedAccountExpired_injectedAccountClean_stillDispatches() {
        let shared = AppContainer.production().accountsManager.currentUserAccount // MIGRATED-DEFERRED: seeds the shared state this test proves the loader no longer reads
        shared.setAuthToken("leaked", barcode: "b", pin: "p",
                            expirationDate: Date(timeIntervalSinceNow: -3600))
        seededSharedAccount = shared
        XCTAssertTrue(shared.authTokenHasExpired,
                      "Precondition: the shared account holds an expired token")

        let openAccess = SpyAdapter(label: "open", handles: true,
                                    stubbedResult: .success((json: manifestStub, decryptor: nil)))
        let loader = makeLoader([openAccess])

        _ = runLoad(loader: loader, book: makeBook())

        XCTAssertEqual(openAccess.resolveCallCount, 1,
                       "The loader must gate on its injected account, not the shared one")
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
        let loader = makeLoader([lcp, localFile, bearerToken, openAccess])

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
        let loader = makeLoader([lcp, localFile, bearerToken, openAccess])
#else
        let loader = makeLoader([localFile, bearerToken, openAccess])
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
        let loader = makeLoader([lcp, localFile, bearerToken, openAccess])
#else
        let loader = makeLoader([localFile, bearerToken, openAccess])
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
        let loader = makeLoader([lcp, localFile, bearerToken, openAccess])
#else
        let loader = makeLoader([localFile, bearerToken, openAccess])
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
        let loader = makeLoader([lcp, localFile, bearerToken, openAccess])

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
    /// This is the original "no default acquisition URL" failure mode
    /// preserved verbatim. Without this assertion, a regression that
    /// changed the fallback to `.manifestParseFailed` (or worse, succeeded
    /// silently) would not be caught.
    func testLoad_noAdapterMatches_failsWithManifestFetchFailed() {
        let localFile = SpyAdapter(label: "local", handles: false,
                                   stubbedResult: .failure(.manifestParseFailed))
        let openAccess = SpyAdapter(label: "open", handles: false,
                                    stubbedResult: .failure(.manifestFetchFailed))
        let loader = makeLoader([localFile, openAccess])

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
        let loader = makeLoader([openAccess])

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
}
