//
//  AudiobookLoaderDispatchTests.swift
//
//  The loader dispatches through one linear adapter chain
//  (`adapters.first(where: { $0.canHandle(book) })`). These tests inject a
//  chain via `AudiobookLoader(adapters:)` and assert the order LCP > LocalFile
//  > BearerToken > OpenAccess, with `.manifestFetchFailed` when none claims.
//  `load` is awaited by AudiobookSessionManager, which is its only caller.
//  Every loader here gets its own account through `makeLoader`, so the
//  pre-chain token gate never reads the shared container (PP-5295).
//  See also AudiobookLoaderOPDSShapeMatrixTests and AudiobookLoaderPredicateTests.
//

import XCTest
@preconcurrency import PalaceAudiobookToolkit
@testable import Palace
import PalaceBookModel
import PalaceCatalog

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
            for book: TPPBook
        ) async -> Result<(json: [String: Any], decryptor: DRMDecryptor?), AudiobookLoadError> {
            resolveCallCount += 1
            return stubbedResult
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

    /// Drive `load()` and return its result. `manifestStub` is intentionally
    /// not a real audiobook manifest, so a success result from the adapter
    /// chain will subsequently fail in `build()` (manifest decoding); we
    /// tolerate that and only assert adapter invocation counts.
    ///
    /// No deadline to choose: `load` is awaited, so there is nothing to starve
    /// under parallel simulator clones (STARVE-001).
    private func runLoad(
        loader: AudiobookLoader,
        book: TPPBook
    ) async -> Result<LoadedAudiobook, AudiobookLoadError> {
        await loader.load(book)
    }

    // MARK: - Token gate reads the injected account (PP-5295)

    /// An expired token with no token URL to refresh against fails the load
    /// with `.missingCredentialsForTokenRefresh` before any adapter is asked.
    func testLoad_injectedAccountExpiredWithoutTokenURL_failsBeforeAnyAdapter() async {
        let expired = TPPUserAccountMock()
        expired.setAuthToken("stale", barcode: "b", pin: "p",
                             expirationDate: Date(timeIntervalSinceNow: -3600))
        let openAccess = SpyAdapter(label: "open", handles: true,
                                    stubbedResult: .success((json: manifestStub, decryptor: nil)))
        let loader = makeLoader([openAccess], account: expired)

        let result = await runLoad(loader: loader, book: makeBook())

        guard case .failure(.missingCredentialsForTokenRefresh) = result else {
            XCTFail("expected .missingCredentialsForTokenRefresh, got \(String(describing: result))")
            return
        }
        XCTAssertEqual(openAccess.canHandleCallCount, 0,
                       "The token gate fails before the adapter chain is consulted")
    }

    // MARK: - Dispatch routing tests

#if LCP
    /// LCP fixture flows through the LCP adapter, NOT through any later
    /// adapter in the chain. The chain order is LCP > Local > Bearer >
    /// OpenAccess; LCP's `canHandle` returning true must short-circuit
    /// every downstream `canHandle`.
    func testLoad_lcpBook_dispatchesToLCPAdapter() async {
        let lcp = SpyAdapter(label: "lcp", handles: true,
                             stubbedResult: .success((json: manifestStub, decryptor: nil)))
        let localFile = SpyAdapter(label: "local", handles: true,
                                   stubbedResult: .success((json: manifestStub, decryptor: nil)))
        let bearerToken = SpyAdapter(label: "bearer", handles: true,
                                     stubbedResult: .success((json: manifestStub, decryptor: nil)))
        let openAccess = SpyAdapter(label: "open", handles: true,
                                    stubbedResult: .success((json: manifestStub, decryptor: nil)))
        let loader = makeLoader([lcp, localFile, bearerToken, openAccess])

        _ = await runLoad(loader: loader, book: makeBook())

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
    func testLoad_localFileBook_dispatchesToLocalFileAdapter() async {
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

        _ = await runLoad(loader: loader, book: makeBook())

        XCTAssertEqual(localFile.resolveCallCount, 1,
                       "LocalFile adapter must be invoked when it claims the book")
        XCTAssertEqual(bearerToken.resolveCallCount, 0, "BearerToken must NOT run once LocalFile wins")
        XCTAssertEqual(openAccess.resolveCallCount, 0, "OpenAccess must NOT run once LocalFile wins")
    }

    /// BearerToken fixture: LCP + LocalFile both decline; BearerToken
    /// claims. Pins the chain's middle-position adapter doesn't get skipped
    /// by a regression that flips `.first(where:)` to a naïve `for in`.
    func testLoad_bearerTokenBook_dispatchesToBearerTokenAdapter() async {
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

        _ = await runLoad(loader: loader, book: makeBook())

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
    func testLoad_openAccessBook_dispatchesToOpenAccessAdapter() async {
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

        _ = await runLoad(loader: loader, book: makeBook())

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
    func testLoad_lcpPriorityOverOthers() async {
        let lcp = SpyAdapter(label: "lcp", handles: true,
                             stubbedResult: .success((json: manifestStub, decryptor: nil)))
        let localFile = SpyAdapter(label: "local", handles: true,
                                   stubbedResult: .success((json: manifestStub, decryptor: nil)))
        let bearerToken = SpyAdapter(label: "bearer", handles: true,
                                     stubbedResult: .success((json: manifestStub, decryptor: nil)))
        let openAccess = SpyAdapter(label: "open", handles: true,
                                    stubbedResult: .success((json: manifestStub, decryptor: nil)))
        let loader = makeLoader([lcp, localFile, bearerToken, openAccess])

        _ = await runLoad(loader: loader, book: makeBook())

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
    func testLoad_noAdapterMatches_failsWithManifestFetchFailed() async {
        let localFile = SpyAdapter(label: "local", handles: false,
                                   stubbedResult: .failure(.manifestParseFailed))
        let openAccess = SpyAdapter(label: "open", handles: false,
                                    stubbedResult: .failure(.manifestFetchFailed))
        let loader = makeLoader([localFile, openAccess])

        let result = await runLoad(loader: loader, book: makeBook())

        guard case .failure(let err) = result else {
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
    func testLoad_cancelDuringDispatch_surfacesCancelled() async {
        let openAccess = SpyAdapter(label: "open", handles: true,
                                    stubbedResult: .success((json: manifestStub, decryptor: nil)))
        let loader = makeLoader([openAccess])

        var seenError: AudiobookLoadError?
        loader.cancel()
        if case .failure(let err) = await loader.load(makeBook()) { seenError = err }

        guard case .cancelled = seenError else {
            XCTFail("expected .cancelled when loader is cancelled before dispatch, got \(String(describing: seenError))")
            return
        }
        // The returned error alone cannot see the early return added for this:
        // without it `load` still walks the whole pipeline and the final
        // `settle` overrides the adapter's success to `.cancelled`, so the
        // assertion above passes either way. What distinguishes them is the
        // work NOT done — a superseded open must not spend a token refresh and
        // a manifest fetch whose result it will discard.
        XCTAssertEqual(openAccess.canHandleCallCount, 0,
                       "a loader cancelled before load must not consult the adapter chain at all")
        XCTAssertEqual(openAccess.resolveCallCount, 0,
                       "and must not fetch a manifest it is going to throw away")
    }

    // MARK: - PP-5299 — the refresh outcome must reach the main actor
    //
    // These drive `load` itself rather than a carrier. While `refreshTokenIfNeeded`
    // resolved its own dependencies from the shared container, its two
    // executor-callback exits could not be reached from a test at all, so the
    // main-actor hop they needed was pinned only on the carrier that performed
    // it. The refresh is injected now, and `load` is awaited, so each exit is
    // reachable and the hop is a property of the language rather than of a
    // carrier someone has to remember to use.

    /// The success exit the field crash walked. A refresh that answers from off
    /// the main actor — which is what the production executor does, firing from
    /// inside its own `Task` — must still have the chain run on the main actor.
    ///
    /// `resolveCallCount` is the assertion that goes red on a behaviour change:
    /// swapping this exit's outcome, or dropping the proceed, leaves it at 0.
    /// The isolation itself is asserted inside the probe, where the reason it
    /// is weaker is recorded.
    func testLoad_whenRefreshAnswersOffTheMainActor_runsTheAdapterChainOnIt() async {
        let expiredAccount = Self.refreshableExpiredAccount()
        let probe = MainActorProbeAdapter()
        let loader = AudiobookLoader(
            adapters: [probe],
            currentUserAccount: { expiredAccount },
            refreshToken: { _ in
                // Does its work off the main actor, the way the executor does:
                // `refreshTokenAndResume` fires from inside its own `Task`.
                //
                // Deliberately not asserted here. This closure is a stored
                // property on a `@MainActor` type, so it is main-actor isolated
                // whatever it delegates to, and an assertion that
                // `Task.detached` ran off-main would only restate that type's
                // definition. What the test turns on is below: the chain is
                // reached, and the probe asserts the actor it is reached on.
                _ = await Task.detached { Self.isOnMainThread() }.value
                return .success(Data(), nil)
            },
            currentAccountId: { "lib-1" },
            isTokenValid: { true }
        )

        _ = await loader.load(makeBook())

        XCTAssertEqual(probe.resolveCallCount, 1,
                       "a successful refresh must proceed to the adapter chain — reached on the main "
                       + "actor, which the probe asserts on entry, even though the refresh answered off it")
    }

    /// The failure exit. A refresh that fails must surface
    /// `.tokenRefreshFailed` and never reach an adapter — swapping this exit's
    /// outcome for `.success` would let a load proceed on a dead token.
    func testLoad_whenRefreshFails_failsWithTokenRefreshFailedAndAsksNoAdapter() async {
        let expiredAccount = Self.refreshableExpiredAccount()
        let probe = MainActorProbeAdapter()
        let refreshError = NSError(domain: "test.refresh", code: 401,
                                   userInfo: [NSLocalizedDescriptionKey: "refresh rejected"])
        let loader = AudiobookLoader(
            adapters: [probe],
            currentUserAccount: { expiredAccount },
            refreshToken: { _ in .failure(refreshError, nil) },
            currentAccountId: { nil },
            isTokenValid: { false }
        )

        let result = await loader.load(makeBook())

        guard case .failure(.tokenRefreshFailed(let underlying)) = result else {
            return XCTFail("expected .tokenRefreshFailed, got \(result)")
        }
        XCTAssertEqual((underlying as NSError?)?.code, 401,
                       "the refresh error must be carried, not replaced")
        XCTAssertEqual(probe.resolveCallCount, 0,
                       "a failed refresh must not reach the adapter chain")
    }

    /// PP-4542: another refresh already owns the single-flight slot, so the
    /// refresh fails immediately with that signal. The loader waits for the
    /// in-flight one and proceeds once the token is valid.
    func testLoad_whenRefreshIsAlreadyInProgressAndTokenBecomesValid_proceeds() async {
        let expiredAccount = Self.refreshableExpiredAccount()
        let probe = MainActorProbeAdapter()
        let loader = AudiobookLoader(
            adapters: [probe],
            currentUserAccount: { expiredAccount },
            refreshToken: { _ in .failure(Self.refreshInProgressError, nil) },
            currentAccountId: { nil },
            isTokenValid: { true },
            tokenReadyPolicy: .init(timeout: 1.0, pollInterval: 0.01)
        )

        _ = await loader.load(makeBook())

        XCTAssertEqual(probe.resolveCallCount, 1,
                       "an in-flight refresh that lands must let the load proceed")
    }

    /// The same path when the in-flight refresh never produces a valid token:
    /// the wait is bounded and the original error is surfaced, so a stuck
    /// refresh cannot hang the open.
    func testLoad_whenRefreshIsAlreadyInProgressAndTokenNeverBecomesValid_failsBounded() async {
        let expiredAccount = Self.refreshableExpiredAccount()
        let probe = MainActorProbeAdapter()
        let loader = AudiobookLoader(
            adapters: [probe],
            currentUserAccount: { expiredAccount },
            refreshToken: { _ in .failure(Self.refreshInProgressError, nil) },
            currentAccountId: { nil },
            isTokenValid: { false },
            tokenReadyPolicy: .init(timeout: 0.2, pollInterval: 0.01)
        )

        let result = await loader.load(makeBook())

        guard case .failure(.tokenRefreshFailed) = result else {
            return XCTFail("a timed-out in-flight wait must surface .tokenRefreshFailed, got \(result)")
        }
        XCTAssertEqual(probe.resolveCallCount, 0,
                       "the load must not proceed on a token that never became valid")
    }

    /// The wait has to actually wait. PP-4542's whole purpose is to give the
    /// in-flight refresh time to land, and a token that only becomes valid on a
    /// later poll must still let the load proceed.
    ///
    /// This is the case the outcome assertions cannot see. Mutating the
    /// deadline comparison so the loop gives up on its first iteration still
    /// produces `.tokenRefreshFailed` for a token that never becomes valid, so
    /// the sibling test above stays green while the wait has stopped waiting.
    /// Here the token turns valid on the third poll, so a loop that exits early
    /// fails the load and this goes red.
    func testLoad_whenTheInFlightRefreshLandsOnALaterPoll_stillProceeds() async {
        let expiredAccount = Self.refreshableExpiredAccount()
        let probe = MainActorProbeAdapter()
        let polls = PollCounter()
        let loader = AudiobookLoader(
            adapters: [probe],
            currentUserAccount: { expiredAccount },
            refreshToken: { _ in .failure(Self.refreshInProgressError, nil) },
            currentAccountId: { nil },
            isTokenValid: { polls.recordAndIsValid(onPoll: 3) },
            tokenReadyPolicy: .init(timeout: 2.0, pollInterval: 0.01)
        )

        _ = await loader.load(makeBook())

        XCTAssertGreaterThanOrEqual(polls.count, 3,
                                    "the wait must keep polling until the token lands, not give up on "
                                    + "its first look")
        XCTAssertEqual(probe.resolveCallCount, 1,
                       "a refresh that lands on a later poll must still let the load proceed (PP-4542)")
    }

    /// Counts polls and reports the token valid from `onPoll` onwards, so a
    /// test can distinguish a wait that polls from one that gives up.
    private final class PollCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var polls = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return polls }
        func recordAndIsValid(onPoll threshold: Int) -> Bool {
            lock.lock(); defer { lock.unlock() }
            polls += 1
            return polls >= threshold
        }
    }

    /// The library the refresh authenticates as is the one the loader was
    /// asked about (PP-4986): a refresh stamped with the selected library
    /// re-authenticates the wrong account when a non-current library is open.
    func testLoad_passesTheCurrentAccountIdToTheRefresh() async {
        let expiredAccount = Self.refreshableExpiredAccount()
        let seen = AccountIdRecorder()
        let loader = AudiobookLoader(
            adapters: [MainActorProbeAdapter()],
            currentUserAccount: { expiredAccount },
            refreshToken: { accountId in
                seen.value = accountId
                return .success(Data(), nil)
            },
            currentAccountId: { "library-under-test" },
            isTokenValid: { true }
        )

        _ = await loader.load(makeBook())

        XCTAssertEqual(seen.value, "library-under-test",
                       "the refresh must name the library the loader resolved, not nil")
    }

    /// An account with an expired token AND a token URL to refresh against, so
    /// `refreshTokenIfNeeded` passes its credentials guard and reaches the
    /// injected refresh. The sibling fixture without a token URL fails at that
    /// guard instead, which is what
    /// `testLoad_injectedAccountExpiredWithoutTokenURL_failsBeforeAnyAdapter`
    /// pins.
    private static func refreshableExpiredAccount() -> TPPUserAccountMock {
        let account = TPPUserAccountMock()
        account.setAuthToken("stale", barcode: "b", pin: "p",
                             expirationDate: Date(timeIntervalSinceNow: -3600))
        let json = """
        {
          "type": "http://thepalaceproject.org/authtype/basic-token",
          "links": [
            {"rel": "authenticate", "href": "https://library.test/token"}
          ]
        }
        """
        let docAuth = try! JSONDecoder().decode(
            OPDS2AuthenticationDocument.Authentication.self, from: Data(json.utf8))
        account._authDefinition = AccountDetails.Authentication(auth: docAuth)
        return account
    }

    /// The signal `isRefreshInProgressError` matches on. Built here rather than
    /// reaching into production so the test states the shape it depends on.
    private static let refreshInProgressError = NSError(
        domain: "test.refresh", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Token refresh in progress"])

    /// `Thread.isMainThread` is unavailable from an `async` context, so the
    /// off-main premise is read through this synchronous hop.
    private nonisolated static func isOnMainThread() -> Bool {
        Thread.isMainThread
    }

    /// Adapter that records whether the chain was reached, and asserts it is
    /// entered on the main actor.
    ///
    /// The assertion is `MainActor.assertIsolated` rather than a thread read:
    /// `AudiobookVendorAdapter` is `@MainActor`, so this is the runtime
    /// statement of a guarantee the compiler already makes, and it goes red if
    /// that annotation is removed. Before this change the same property
    /// depended on a hop inside a carrier and nothing pinned it here.
    private final class MainActorProbeAdapter: AudiobookVendorAdapter {
        private(set) var resolveCallCount = 0

        func canHandle(_ book: TPPBook) -> Bool { true }

        func resolveManifest(
            for book: TPPBook
        ) async -> Result<(json: [String: Any], decryptor: DRMDecryptor?), AudiobookLoadError> {
            MainActor.assertIsolated("the adapter chain must be entered on the main actor (PP-5299)")
            resolveCallCount += 1
            // Fail the manifest so the test stops before `build`, which reads
            // the shared container.
            return .failure(.manifestParseFailed)
        }
    }

    /// Carries the account id out of the injected refresh closure.
    private final class AccountIdRecorder: @unchecked Sendable {
        var value: String?
    }
}
