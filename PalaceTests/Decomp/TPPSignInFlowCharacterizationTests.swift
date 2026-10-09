//
//  TPPSignInFlowCharacterizationTests.swift
//  PalaceTests
//
//  Characterization pack (part 3) for the TPPSignInBusinessLogic
//  decomposition; see docs/architecture/god-class-decomposition-plan.md.
//  Every expectation was READ OFF the current implementation, including
//  behaviour that may be wrong: suspected defects carry a `SUSPECT:` comment
//  and are reported separately rather than fixed here.
//
//  "Targets a hand-written mutant that ..." below means a shape reasoned by
//  hand, not one a tool generated and not part of any score — palace_mutate's
//  operators cannot express them. Exactly one, R3, is measured.
//
//  Hermetic: no URLSession, keychain, `.shared` singleton or UserDefaults.

import XCTest
import PalaceCatalog
import PalaceAuth
@testable import Palace

// MARK: - Local doubles

/// Records `sync()` / `reset(_:)` counts. `TPPBookRegistryMock.sync()` only
/// toggles `isSyncing` true→false synchronously, so after the call returns
/// there is nothing left to observe — it cannot prove whether the
/// current-library gate in `updateUserAccount` fired.
/// `@unchecked Sendable` is honored, not waived: both mutable fields are
/// read and written only under `lock` (same recipe as `TPPBookRegistryMock`).
final class CountingRegistrySpy: TPPBookRegistrySyncing, @unchecked Sendable {
    private let lock = NSLock()
    private var _syncCount = 0
    private var _resetUUIDs: [String] = []

    var isSyncing: Bool { false }
    var syncCount: Int { lock.withLock { _syncCount } }
    var resetUUIDs: [String] { lock.withLock { _resetUUIDs } }

    func sync() { lock.withLock { _syncCount += 1 } }
    func reset(_ libraryAccountUUID: String) { lock.withLock { _resetUUIDs.append(libraryAccountUUID) } }
}

/// Captures the validation-error callback. The shared
/// `TPPSignInOutBusinessLogicUIDelegateMock` no-ops on
/// `didEncounterValidationError`, so it cannot prove WHICH message a failure
/// was classified into — which is the whole point of the token-error tests.
/// `@unchecked Sendable` is honored, not waived: every recorded field is read
/// and written only under `recordLock` (same recipe as the shared
/// `TPPSignInOutBusinessLogicUIDelegateMock`). The UIKit-typed fields are
/// left nil by every test in this file.
final class ErrorRecordingUIDelegate: NSObject, TPPSignInOutBusinessLogicUIDelegate, @unchecked Sendable {
    var context = "ErrorRecordingUIDelegate"
    var username: String? = "patron"
    var pin: String? = "1234"
    var usernameTextField: UITextField?
    var PINTextField: UITextField?
    var forceEditability: Bool = false

    private let recordLock = NSLock()
    private var _validationErrorCount = 0
    private var _lastTitle: String?
    private var _lastMessage: String?
    private var _lastError: Error?
    private var _didReceiveCredentialsCount = 0

    var validationErrorCount: Int { recordLock.withLock { _validationErrorCount } }
    var lastTitle: String? { recordLock.withLock { _lastTitle } }
    var lastMessage: String? { recordLock.withLock { _lastMessage } }
    var lastError: Error? { recordLock.withLock { _lastError } }
    var didReceiveCredentialsCount: Int { recordLock.withLock { _didReceiveCredentialsCount } }

    /// Join seam. `businessLogicDidReceiveCredentials` is the last delegate
    /// callback before DRM/finalize, so a test that awaits it is synchronized
    /// on the credential chain HAVING COMPLETED rather than on a wall clock.
    private var _onDidReceiveCredentials: (@Sendable () -> Void)?
    var onDidReceiveCredentials: (@Sendable () -> Void)? {
        get { recordLock.withLock { _onDidReceiveCredentials } }
        set { recordLock.withLock { _onDidReceiveCredentials = newValue } }
    }

    func businessLogicWillSignIn(_ businessLogic: TPPSignInBusinessLogic) {}
    func businessLogicDidCancelSignIn(_ businessLogic: TPPSignInBusinessLogic) {}
    func businessLogicDidCompleteSignIn(_ businessLogic: TPPSignInBusinessLogic) {}
    func businessLogic(_ logic: TPPSignInBusinessLogic,
                       didEncounterValidationError error: Error?,
                       userFriendlyErrorTitle title: String?,
                       andMessage message: String?) {
        recordLock.withLock {
            _validationErrorCount += 1
            _lastTitle = title
            _lastMessage = message
            _lastError = error
        }
    }
    func businessLogicDidReceiveCredentials(_ businessLogic: TPPSignInBusinessLogic) {
        let hook: (@Sendable () -> Void)? = recordLock.withLock {
            _didReceiveCredentialsCount += 1
            return _onDidReceiveCredentials
        }
        hook?()
    }
    func dismiss(animated flag: Bool, completion: (() -> Void)?) { completion?() }
    func present(_ viewControllerToPresent: UIViewController,
                 animated flag: Bool,
                 completion: (() -> Void)?) { completion?() }
    func businessLogicWillSignOut(_ businessLogic: TPPSignInBusinessLogic) {}
    func businessLogic(_ logic: TPPSignInBusinessLogic,
                       didEncounterSignOutError error: Error?,
                       withHTTPStatusCode httpStatusCode: Int) {}
    func businessLogicDidFinishDeauthorizing(_ logic: TPPSignInBusinessLogic) {}
}

/// Pure in-memory `TokenRefreshing` double — no URLSession, no retries.
/// `@unchecked Sendable`: configured and invoked only on the main actor by
/// the tests in this file; `executeTokenRefresh` calls its completion
/// synchronously, so no value crosses a queue.
final class FlowTokenRefresherMock: TokenRefreshing, @unchecked Sendable {
    enum Reply {
        case success(TokenResponse)
        case failure(Error)
    }
    var result: Reply = .failure(NSError(domain: "FlowTokenRefresherMock", code: -1))
    private(set) var invocationCount = 0
    private(set) var lastAccountId: String?

    func executeTokenRefresh(username: String,
                             password: String,
                             tokenURL: URL,
                             accountId: String?,
                             completion: @escaping (Result<TokenResponse, Error>) -> Void) {
        invocationCount += 1
        lastAccountId = accountId
        switch result {
        case .success(let r): completion(.success(r))
        case .failure(let e): completion(.failure(e))
        }
    }
}

/// Collects `.TPPIsSigningIn` posts as their `Bool` payloads, in order.
/// Registered against `NotificationCenter.default` because the production
/// code posts there unconditionally; the observer is removed in `stop()`
/// so nothing leaks into a sibling test.
///
/// `queue: nil` (the idiom the rest of the sign-in suite uses) delivers the
/// block synchronously on the posting thread, so a test can post-and-assert
/// in one turn. A non-nil queue enqueues instead, which would make every
/// assertion below depend on a drain the test never performs.
final class SigningInNotificationRecorder {
    private var token: NSObjectProtocol?
    private let lock = NSLock()
    private var _payloads: [Bool] = []
    var payloads: [Bool] { lock.withLock { _payloads } }

    init() {
        token = NotificationCenter.default.addObserver(
            forName: .TPPIsSigningIn, object: nil, queue: nil
        ) { [weak self] note in
            guard let self, let flag = note.object as? Bool else { return }
            self.lock.withLock { self._payloads.append(flag) }
        }
    }

    func stop() {
        if let token { NotificationCenter.default.removeObserver(token) }
        token = nil
    }
}

// MARK: - Shared fixture scaffolding

@MainActor
class SignInFlowFixture: XCTestCase {
    var businessLogic: TPPSignInBusinessLogic!
    var libraryMock: TPPLibraryAccountMock!
    var networkExecutor: TPPRequestExecutorMock!
    var registry: CountingRegistrySpy!
    var uiDelegate: ErrorRecordingUIDelegate!

    override func setUpWithError() throws {
        try super.setUpWithError()
        TPPUserAccountMock.resetShared()
        libraryMock = TPPLibraryAccountMock()
        networkExecutor = TPPRequestExecutorMock()
        registry = CountingRegistrySpy()
        uiDelegate = ErrorRecordingUIDelegate()
        businessLogic = TPPSignInBusinessLogic(
            libraryAccountID: libraryMock.tppAccountUUID,
            libraryAccountsProvider: libraryMock,
            urlSettingsProvider: TPPURLSettingsProviderMock(),
            bookRegistry: registry,
            bookDownloadsCenter: TPPMyBooksDownloadsCenterMock(),
            userAccountProvider: TPPUserAccountMock.self,
            networkExecutor: networkExecutor,
            uiDelegate: uiDelegate,
            drmAuthorizer: TPPDRMAuthorizingMock())
        businessLogic.userAccount.removeAll()
        setLoaded()
    }

    override func tearDownWithError() throws {
        networkExecutor.reset()
        businessLogic?.userAccount.removeAll()
        businessLogic = nil
        libraryMock = nil
        networkExecutor = nil
        registry = nil
        uiDelegate = nil
        #if DEBUG
        AccountStateStore.shared._resetAllForTesting()
        #endif
        try super.tearDownWithError()
    }

    /// Drive the account's readiness state machine to `.detailsLoaded`.
    func setLoaded() {
        if let details = libraryMock.tppAccount.details {
            libraryMock.tppAccount._setState(.detailsLoaded(details))
        }
    }

    func setLoading() {
        libraryMock.tppAccount._setState(.detailsLoading)
    }

    func setFailed() {
        libraryMock.tppAccount._setState(
            .detailsFailed(.authDocumentFetchFailed(underlyingDescription: "characterization")))
    }

    /// Await the moment `executeRequest` records a URL, rather than polling a
    /// wall clock (STARVE-001: polling starves under parallel sim clones).
    func expectRequestFired(_ description: String = "request fired") -> XCTestExpectation {
        let exp = expectation(description: description)
        exp.assertForOverFulfill = false
        networkExecutor.onExecuteRequest = { _ in exp.fulfill() }
        return exp
    }
}

// MARK: - 1. Readiness-race retry (`awaitReadyThenRetryLogIn`)
//
// `logIn()` guards on `selectedAuthentication`; when the account has not
// reached `.detailsLoaded` that getter resolves nil purely because
// `loadedAccountDetails` is nil. Before the retry existed, the tap was a
// silent no-op. These pin the retry, its re-entrancy guard, and both
// give-up paths.

@MainActor
final class SignInReadinessRaceCharacterizationTests: SignInFlowFixture {

    // R1 — a sign-in tap that arrives BEFORE the auth document has loaded
    // fires no network request and does not announce "signing in". Targets a
    // hand-written mutant that drops the `guard let wrapped = selectedAuthentication`
    // and falls through to the auth-type switch on a nil auth.
    func test_logIn_beforeDetailsLoaded_firesNoRequest_andDoesNotAnnounceSigningIn() async {
        let recorder = SigningInNotificationRecorder()
        defer { recorder.stop() }
        setLoading()

        await businessLogic.logIn()
        await Task.yield()

        XCTAssertTrue(networkExecutor.executedRequestURLs.isEmpty,
                      "A tap that races the auth-document load must not issue the /patrons/me request yet")
        XCTAssertFalse(recorder.payloads.contains(true),
                       "TPPIsSigningIn(true) is posted only once an auth method is resolved")
    }

    // R2 — the retry itself: once readiness resolves AND an auth method is
    // available, the deferred tap is honored and the credential request
    // fires. This is the 476→479 regression. Targets a hand-written mutant that deletes
    // the `self.logIn(with: tokenURL)` re-entry.
    func test_logIn_beforeDetailsLoaded_retriesAfterReadiness_andFiresRequest() async {
        setLoading()
        let fired = expectRequestFired()
        let accepted = expectation(description: "credential chain completed")
        accepted.assertForOverFulfill = false
        uiDelegate.onDidReceiveCredentials = { accepted.fulfill() }

        await businessLogic.logIn()                       // defers on awaitReady()
        businessLogic.selectedAuthentication = libraryMock.barcodeAuthentication
        setLoaded()                                 // resolves the gate

        await fulfillment(of: [fired, accepted], timeout: 5.0)   // STARVE-001-OK: expectRequestFired + uiDelegate hook; NYPLNetworkExecutorMock fires onExecuteRequest inline and setLoaded() resolves the gate in-test — no real network, no fire-and-forget Task
        XCTAssertEqual(networkExecutor.executedRequestURLs.count, 1,
                       "The deferred tap must produce exactly one credential request once details load")
        XCTAssertEqual(uiDelegate.validationErrorCount, 0,
                       "The deferred sign-in must complete cleanly, not surface a validation error")
        XCTAssertTrue(businessLogic.userAccount.hasBarcodeAndPIN(),
                      "The deferred tap must carry the form's credentials all the way to the account store")
    }

    // R3 — the re-entrancy guard: two taps while details are loading must
    // await ONCE. KILLS — measured, not asserted — a mutant that deletes
    // `guard !isAwaitingReadinessForLogIn` (which would produce two awaiting
    // tasks and therefore two credential requests).
    //
    // That guard was deleted from TPPSignInBusinessLogic.swift and this test
    // failed 5 of 5 iterations, 0 passes, while the other 7 in this class
    // stayed green. Review challenged the `for _ in 0..<5 { await Task.yield() }`
    // barrier below as possibly insufficient for a second awaiter hopping
    // through `TPPMainThreadRun.asyncIfNeeded`; 5/5 RED is the answer.
    func test_logIn_twoTapsBeforeDetailsLoaded_retriesExactlyOnce() async {
        setLoading()
        let fired = expectRequestFired()

        await businessLogic.logIn()
        await businessLogic.logIn()
        businessLogic.selectedAuthentication = libraryMock.barcodeAuthentication
        setLoaded()

        await fulfillment(of: [fired], timeout: 5.0)   // STARVE-001-OK: expectRequestFired; NYPLNetworkExecutorMock invokes onExecuteRequest inline when logIn executes a request — no real network
        // Give any second awaiter a turn to land before counting.
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(networkExecutor.executedRequestURLs.count, 1,
                       "The re-entrancy guard must collapse two racing taps into a single deferred sign-in")
    }

    // R4 — readiness resolving to `.detailsFailed` clears the spinner rather
    // than leaving the UI hanging: TPPIsSigningIn(false) is posted and no
    // request is made. Targets a hand-written mutant that removes the catch-arm post.
    func test_logIn_whenReadinessFails_announcesNotSigningIn_andFiresNoRequest() async {
        let recorder = SigningInNotificationRecorder()
        defer { recorder.stop() }
        setLoading()

        await businessLogic.logIn()
        setFailed()

        await awaitConditionAsync(timeout: 5.0) { recorder.payloads.contains(false) }
        XCTAssertTrue(recorder.payloads.contains(false),
                      "A failed readiness gate must post TPPIsSigningIn(false) so the sign-in UI stops spinning")
        XCTAssertTrue(networkExecutor.executedRequestURLs.isEmpty,
                      "No credential request may be issued when the auth document never loaded")
    }

    // R5 — the give-up path CLEARS the await-once guard, so a later tap can
    // await again. Targets a hand-written mutant that arms `isAwaitingReadinessForLogIn`
    // and never resets it in the catch arm — which would wedge sign-in for
    // the lifetime of the object after one auth-doc failure.
    //
    // The guard is private, so it is observed through its only visible
    // consequence: a SECOND tap that once more arrives before details load
    // must still be honored when readiness finally resolves.
    func test_logIn_afterReadinessFailure_aSubsequentDeferredTapStillSignsIn() async {
        let recorder = SigningInNotificationRecorder()
        defer { recorder.stop() }
        setLoading()
        await businessLogic.logIn()
        setFailed()
        await awaitConditionAsync(timeout: 5.0) { recorder.payloads.contains(false) }

        // Second tap, again while not loaded — this can only be deferred if
        // the guard was released by the first attempt's failure arm.
        setLoading()
        let fired = expectRequestFired("second deferred tap fires")
        await businessLogic.logIn()
        businessLogic.selectedAuthentication = libraryMock.barcodeAuthentication
        setLoaded()

        await fulfillment(of: [fired], timeout: 5.0)   // STARVE-001-OK: expectRequestFired; NYPLNetworkExecutorMock invokes onExecuteRequest inline — no real network
        XCTAssertEqual(networkExecutor.executedRequestURLs.count, 1,
                       "A prior readiness failure must not permanently wedge the deferred sign-in path")
    }

    // R6 — readiness resolves, but `selectedAuthentication` is STILL nil
    // because the NYPL fixture advertises more than one auth method and the
    // getter deliberately returns nil in that case. Current behaviour: give
    // up quietly with TPPIsSigningIn(false), no request, no error surfaced
    // to the delegate.
    //
    // SUSPECT (reported, not fixed here): the patron sees the spinner stop
    // and nothing else — no alert, no prompt to choose an auth method. On a
    // multi-auth library where `selectPreferredAuthIfNeeded()` found neither
    // SAML nor OIDC, a sign-in tap is a silent dead end.
    func test_logIn_whenAuthStillUnresolvedAfterLoad_givesUpQuietly() async {
        let recorder = SigningInNotificationRecorder()
        defer { recorder.stop() }
        setLoading()

        await businessLogic.logIn()                       // no selectedAuthentication set
        setLoaded()

        await awaitConditionAsync(timeout: 5.0) { recorder.payloads.contains(false) }
        XCTAssertTrue(recorder.payloads.contains(false),
                      "The give-up path posts TPPIsSigningIn(false)")
        XCTAssertTrue(networkExecutor.executedRequestURLs.isEmpty,
                      "No request when the multi-auth fixture leaves selectedAuthentication nil")
        XCTAssertEqual(uiDelegate.validationErrorCount, 0,
                       "Current behaviour surfaces NO error to the UI on this path — pinned as-is")
    }

    // R7 — when there is no library account at all, `logIn()` returns before
    // even arming the readiness guard. Targets a hand-written mutant that drops
    // `guard let account = libraryAccount`.
    func test_logIn_withNoLibraryAccount_isATotalNoOp() async {
        let orphan = TPPSignInBusinessLogic(
            libraryAccountID: "",                   // TPPLibraryAccountMock maps "" → nil
            libraryAccountsProvider: libraryMock,
            urlSettingsProvider: TPPURLSettingsProviderMock(),
            bookRegistry: registry,
            bookDownloadsCenter: TPPMyBooksDownloadsCenterMock(),
            userAccountProvider: TPPUserAccountMock.self,
            networkExecutor: networkExecutor,
            uiDelegate: uiDelegate,
            drmAuthorizer: TPPDRMAuthorizingMock())
        let recorder = SigningInNotificationRecorder()
        defer { recorder.stop() }

        await orphan.logIn()
        for _ in 0..<5 { await Task.yield() }

        XCTAssertNil(orphan.libraryAccount, "fixture precondition: the empty UUID resolves to no account")
        XCTAssertTrue(networkExecutor.executedRequestURLs.isEmpty,
                      "No account means no request")
        XCTAssertTrue(recorder.payloads.isEmpty,
                      "No account means the sign-in state is never announced in either direction")
    }

    // R8 — the fast path does NOT route through the once-only readiness
    // gate: with details already loaded and an auth method selected, two
    // consecutive taps produce TWO requests. This is the control for R3 —
    // it proves the single-request result there comes from the re-entrancy
    // guard on the deferred path and not from some global de-duplication.
    func test_logIn_whenDetailsAlreadyLoaded_isNotRateLimitedByTheReadinessGate() async {
        let fired = expectation(description: "two requests fired")
        fired.expectedFulfillmentCount = 2
        networkExecutor.onExecuteRequest = { _ in fired.fulfill() }
        businessLogic.selectedAuthentication = libraryMock.barcodeAuthentication

        await businessLogic.logIn()
        await businessLogic.logIn()

        await fulfillment(of: [fired], timeout: 5.0)   // STARVE-001-OK: onExecuteRequest is set directly on NYPLNetworkExecutorMock and fires inline per request — no real network
        XCTAssertEqual(networkExecutor.executedRequestURLs.count, 2,
                       "The already-loaded fast path issues one request per tap")
    }
}

// MARK: - 2. Token-request error branches
//
// `getBearerToken`'s failure arm routes through `handleNetworkError`, which
// classifies the error and pushes (title, message) to BOTH the reducer state
// and the UI delegate. Nothing previously asserted which classification a
// given token failure produces.

@MainActor
final class SignInTokenErrorCharacterizationTests: SignInFlowFixture {

    var refresher: FlowTokenRefresherMock!
    private let tokenURL = URL(string: "https://circulation.librarysimplified.org/NYNYPL/token")!

    override func setUpWithError() throws {
        try super.setUpWithError()
        refresher = FlowTokenRefresherMock()
        businessLogic.selectedAuthentication = libraryMock.barcodeAuthentication
    }

    override func tearDownWithError() throws {
        refresher = nil
        try super.tearDownWithError()
    }

    @discardableResult
    private func refreshFailing(with error: NSError,
                                on logic: TPPSignInBusinessLogic? = nil) async -> Bool {
        // `businessLogic` is IUO on the fixture; annotate so `??` yields a
        // non-optional rather than re-wrapping it.
        let target: TPPSignInBusinessLogic = logic ?? businessLogic
        refresher.result = .failure(error)
        let done = expectation(description: "getBearerToken completion")
        target.getBearerToken(username: "patron",
                              password: "1234",
                              tokenURL: tokenURL,
                              tokenRefresher: refresher) { done.fulfill() }
        await fulfillment(of: [done], timeout: 5.0)   // STARVE-001-OK: FlowTokenRefresherMock.executeTokenRefresh calls completion(...) INLINE from a pre-set .result — no queue hop, no I/O
        return true
    }

    /// A business logic for a library that is NOT the mock's current one.
    ///
    /// `TPPLibraryAccountMock.tppAccountUUID` and `.currentAccountId` both
    /// return `tppAccount.uuid` (the class lives in
    /// `PalaceTests/Mocks/NYPLLibraryAccountsProviderMock.swift:80,:84` — file
    /// name and class name differ after the NYPL→TPP rename), so any assertion comparing
    /// `libraryAccountID` against `currentAccountId` on the shared fixture
    /// compares a value to itself and cannot fail. Routing tests must build
    /// their own instance, as S2 does.
    private func businessLogicForOtherLibrary(
        _ uuid: String = "some-other-library-uuid"
    ) -> TPPSignInBusinessLogic {
        TPPSignInBusinessLogic(
            libraryAccountID: uuid,
            libraryAccountsProvider: libraryMock,
            urlSettingsProvider: TPPURLSettingsProviderMock(),
            bookRegistry: registry,
            bookDownloadsCenter: TPPMyBooksDownloadsCenterMock(),
            userAccountProvider: TPPUserAccountMock.self,
            networkExecutor: networkExecutor,
            uiDelegate: uiDelegate,
            drmAuthorizer: TPPDRMAuthorizingMock())
    }

    private func httpError(_ code: Int) -> NSError {
        NSError(domain: TokenRequest.httpErrorDomain, code: code)
    }

    // T1 — a 503 after TokenRequest exhausted its retries is a transient
    // server failure, NOT bad credentials (HelpSpot 18046). Pinned through
    // the token path, end to end to the UI delegate.
    func test_getBearerToken_transient503_surfacesTryAgain_notInvalidCredentials() async {
        await refreshFailing(with: httpError(503))

        XCTAssertEqual(uiDelegate.lastTitle, Strings.Error.networkUnavailableErrorTitle)
        XCTAssertEqual(uiDelegate.lastMessage, Strings.Error.networkUnavailableErrorMessage)
        XCTAssertNotEqual(uiDelegate.lastTitle, Strings.Error.invalidCredentialsErrorTitle,
                          "A 503 from the token endpoint must not be reported as a wrong password")
    }

    // T2 — 429 (rate limited) takes the same transient arm.
    func test_getBearerToken_rateLimited429_surfacesTryAgain() async {
        await refreshFailing(with: httpError(429))
        XCTAssertEqual(uiDelegate.lastTitle, Strings.Error.networkUnavailableErrorTitle)
    }

    // T3 — 408 (request timeout) takes the same transient arm.
    func test_getBearerToken_requestTimeout408_surfacesTryAgain() async {
        await refreshFailing(with: httpError(408))
        XCTAssertEqual(uiDelegate.lastTitle, Strings.Error.networkUnavailableErrorTitle)
    }

    // T4 — the boundary that proves T1–T3 are not over-matching: a genuine
    // 401 from the token endpoint IS a credential rejection.
    func test_getBearerToken_unauthorized401_surfacesInvalidCredentials() async {
        await refreshFailing(with: httpError(401))

        XCTAssertEqual(uiDelegate.lastTitle, Strings.Error.invalidCredentialsErrorTitle)
        XCTAssertEqual(uiDelegate.lastMessage, Strings.Error.invalidCredentialsErrorMessage)
    }

    // T5 — a URLSession connectivity failure on the token exchange reports
    // "network unavailable", not bad credentials.
    func test_getBearerToken_offline_surfacesNetworkUnavailable() async {
        await refreshFailing(with: NSError(domain: NSURLErrorDomain,
                                           code: NSURLErrorNotConnectedToInternet))
        XCTAssertEqual(uiDelegate.lastTitle, Strings.Error.networkUnavailableErrorTitle)
    }

    // T6 — the failure arm also lands in the reducer, so a re-render reads
    // the same message the delegate got. Targets a hand-written mutant that drops the
    // `dispatch(.credentialsValidationFailed(...))` in handleNetworkError.
    func test_getBearerToken_failure_recordsErrorInAuthState_andEndsValidation() async {
        await refreshFailing(with: httpError(503))

        XCTAssertEqual(businessLogic.authState.lastErrorTitle, Strings.Error.networkUnavailableErrorTitle,
                       "handleNetworkError must record the classified title in AuthState")
        XCTAssertEqual(businessLogic.authState.lastErrorMessage, Strings.Error.networkUnavailableErrorMessage)
        XCTAssertFalse(businessLogic.isValidatingCredentials,
                       "A token failure must leave the validating flag DOWN, not spinning")
    }

    // T7 — a token failure must not promote a token or reach /patrons/me.
    // Targets a hand-written mutant that calls validateCredentials() on the failure arm.
    func test_getBearerToken_failure_storesNoToken_andNeverCallsProfileEndpoint() async {
        await refreshFailing(with: httpError(500))

        XCTAssertNil(businessLogic.authToken, "No in-flight token after a failed exchange")
        XCTAssertNil(businessLogic.userAccount.authToken, "No persisted token after a failed exchange")
        XCTAssertTrue(networkExecutor.executedRequestURLs.isEmpty,
                      "The credential-validation request must not run when the token exchange failed")
        XCTAssertEqual(uiDelegate.didReceiveCredentialsCount, 0)
    }

    // T8 — the caller's completion runs on BOTH arms (the `defer` in the
    // main-actor hop). A mutant that moves `completion?()` into the success
    // case only would hang every caller that awaits it on failure — which is
    // how `refreshAuthIfNeeded` unblocks its own callers.
    func test_getBearerToken_invokesCompletionOnFailure() async {
        refresher.result = .failure(httpError(503))
        let done = expectation(description: "completion on failure arm")
        businessLogic.getBearerToken(username: "patron", password: "1234",
                                     tokenURL: tokenURL, tokenRefresher: refresher) {
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 5.0)   // STARVE-001-OK: FlowTokenRefresherMock calls completion(...) inline from a pre-set .failure — no queue hop, no I/O
        XCTAssertEqual(uiDelegate.validationErrorCount, 1,
                       "Exactly one validation error is surfaced per failed exchange")
    }

    // T9 — the success chain: the received token is carried into the
    // /patrons/me request as a Bearer header. Targets a hand-written mutant that stores the
    // token but skips validateCredentials(), and one that drops the
    // expiration from `.bearerTokenReceived`.
    func test_getBearerToken_success_chainsIntoProfileRequestWithBearerHeader() async {
        businessLogic.selectedAuthentication = libraryMock.oauthAuthentication
        let capturedAuthorization = LockIsolated<String?>(nil)
        let fired = expectation(description: "profile request fired")
        fired.assertForOverFulfill = false
        networkExecutor.onExecuteRequest = { req in
            capturedAuthorization.value = req.value(forHTTPHeaderField: "Authorization")
            fired.fulfill()
        }
        let accepted = expectation(description: "credential chain completed")
        accepted.assertForOverFulfill = false
        uiDelegate.onDidReceiveCredentials = { accepted.fulfill() }
        refresher.result = .success(TokenResponse(accessToken: "tok-chain-1",
                                                  tokenType: "Bearer",
                                                  expiresIn: 3600))

        businessLogic.getBearerToken(username: "patron", password: "1234",
                                     tokenURL: tokenURL, tokenRefresher: refresher)

        await fulfillment(of: [fired, accepted], timeout: 5.0)   // STARVE-001-OK: FlowTokenRefresherMock completes inline from a pre-set .success and the uiDelegate hook fires on the same call stack — no I/O
        XCTAssertEqual(capturedAuthorization.value, "Bearer tok-chain-1",
                       "The freshly exchanged token must authorize the credential-validation request")
        XCTAssertEqual(businessLogic.userAccount.authToken, "tok-chain-1",
                       "The exchanged token must reach the canonical credential store")
        // Characterized, not asserted as ideal: once the chain finishes and
        // TPPUserAccount holds the token, the reducer's in-flight mirrors are
        // wiped (`.userAccountUpdated`) — so `authToken`/`authTokenExpiration`
        // read nil AFTER a successful sign-in, not the value just exchanged.
        XCTAssertNil(businessLogic.authToken,
                     "The in-flight mirror is cleared once the canonical store has the token")
        XCTAssertNil(businessLogic.authTokenExpiration,
                     "…and the expiration mirror goes with it")
    }

    // T10 — the token exchange is scoped to THIS business logic's library, not
    // the currently-selected one (PP-4986: Settings signs in/out for any
    // library). `TPPSignInBusinessLogic.swift:587` passes
    // `accountId: libraryAccountID`; the mutant this pins swaps it to
    // `currentAccountId`.
    //
    // It must run against a NON-current library. On the shared fixture the
    // mock returns `tppAccount.uuid` from both `tppAccountUUID` and
    // `currentAccountId`, so the earlier form of this test asserted
    // `lastAccountId == businessLogic.libraryAccountID` where both sides were
    // the same value and the mutant survived. The PP-4986 seam is one the
    // sign-in extraction will move, so an unpinned cell here is expensive.
    func test_getBearerToken_routesAccountIdToItsOwnLibrary() async {
        let other = businessLogicForOtherLibrary()
        await refreshFailing(with: httpError(401), on: other)

        XCTAssertEqual(refresher.lastAccountId, "some-other-library-uuid",
                       "accountId must be the library this businessLogic signs in to")
        XCTAssertNotEqual(refresher.lastAccountId, libraryMock.currentAccountId,
                          "the discriminating half: with `currentAccountId` substituted at "
                          + "TPPSignInBusinessLogic.swift:587 this is what changes")
    }

    // T11 — boundary of the transient range itself. `(500...599).contains`
    // is a classic off-by-one mutation target; 499 and 600 must NOT match.
    func test_isTransientServerError_rangeBoundaries() {
        XCTAssertFalse(TPPSignInBusinessLogic.isTransientServerError(httpError(499)),
                       "499 is below the 5xx transient range")
        XCTAssertTrue(TPPSignInBusinessLogic.isTransientServerError(httpError(500)),
                      "500 is the inclusive lower bound")
        XCTAssertTrue(TPPSignInBusinessLogic.isTransientServerError(httpError(599)),
                      "599 is the inclusive upper bound")
        XCTAssertFalse(TPPSignInBusinessLogic.isTransientServerError(httpError(600)),
                       "600 is above the 5xx transient range")
    }

    // T12 — the DOMAIN half of the same guard. Without this, flipping
    // `guard error.domain == TokenRequest.httpErrorDomain else { return false }`
    // to `return true` classifies every non-token error as transient and
    // survives T1–T11: those all pass token-domain errors, and T5's
    // connectivity error is caught one branch earlier by
    // `isNetworkConnectivityError`, so it reports the same message either way.
    // A third domain is what separates them.
    func test_isTransientServerError_requiresTheTokenEndpointDomain() {
        let foreign = NSError(domain: "TPPErrorDomain", code: 503)
        XCTAssertFalse(TPPSignInBusinessLogic.isTransientServerError(foreign),
                       "A 5xx code under another domain is not a token-exchange failure")

        // …and the consequence a patron sees: a 403 that is neither a token
        // error nor a connectivity error stays "Invalid Credentials" rather
        // than being softened into "try again".
        let (title, message) = TPPSignInBusinessLogic.userFacingSignInError(
            for: NSError(domain: "TPPErrorDomain", code: 403), problemDocument: nil)
        XCTAssertEqual(title, Strings.Error.invalidCredentialsErrorTitle)
        XCTAssertEqual(message, Strings.Error.invalidCredentialsErrorMessage)
    }
}

// MARK: - 3. `updateUserAccount` side-effect gates
//
// Persistence itself is pinned by the CredentialStore cluster in part 1.
// These pin the two things that happen AROUND the write.

@MainActor
final class SignInCredentialSideEffectCharacterizationTests: SignInFlowFixture {

    private func persistBasic(barcode: String = "bc", pin: String = "pin") {
        businessLogic.selectedAuthentication = libraryMock.barcodeAuthentication
        businessLogic.updateUserAccount(forDRMAuthorization: true,
                                        withBarcode: barcode, pin: pin,
                                        authToken: nil, expirationDate: nil,
                                        patron: nil, cookies: nil)
    }

    // S1 — signing in to the CURRENT library triggers a registry sync, so
    // the patron's loans appear without a manual pull-to-refresh.
    func test_updateUserAccount_forCurrentLibrary_syncsTheBookRegistry() {
        XCTAssertEqual(businessLogic.libraryAccountID, libraryMock.currentAccountId,
                       "fixture precondition: this business logic IS the current library")

        persistBasic()

        XCTAssertEqual(registry.syncCount, 1,
                       "Signing in to the current library must sync the registry exactly once")
    }

    // S2 — the gate's other side: signing in to a NON-current library (the
    // Settings flow) must not kick a sync that would fetch the wrong
    // library's loans. Targets a hand-written mutant that deletes the
    // `libraryAccountID == currentAccountId` condition.
    func test_updateUserAccount_forOtherLibrary_doesNotSyncTheBookRegistry() {
        let other = TPPSignInBusinessLogic(
            libraryAccountID: "some-other-library-uuid",
            libraryAccountsProvider: libraryMock,
            urlSettingsProvider: TPPURLSettingsProviderMock(),
            bookRegistry: registry,
            bookDownloadsCenter: TPPMyBooksDownloadsCenterMock(),
            userAccountProvider: TPPUserAccountMock.self,
            networkExecutor: networkExecutor,
            uiDelegate: uiDelegate,
            drmAuthorizer: TPPDRMAuthorizingMock())
        other.selectedAuthentication = libraryMock.barcodeAuthentication

        other.updateUserAccount(forDRMAuthorization: true,
                                withBarcode: "bc", pin: "pin",
                                authToken: nil, expirationDate: nil,
                                patron: nil, cookies: nil)

        XCTAssertNotEqual(other.libraryAccountID, libraryMock.currentAccountId,
                          "fixture precondition: this business logic is NOT the current library")
        XCTAssertEqual(registry.syncCount, 0,
                       "A sign-in for a non-current library must not sync the current library's registry")
    }

    // S3 — the "signing in" announcement is closed out after persistence, so
    // observers of TPPIsSigningIn (spinner, tab badges) settle.
    func test_updateUserAccount_announcesSigningInFinished() {
        let recorder = SigningInNotificationRecorder()
        defer { recorder.stop() }

        persistBasic()

        XCTAssertEqual(recorder.payloads.last, false,
                       "The last TPPIsSigningIn post after a successful persist must be false")
    }

    // S4 — after the canonical store (TPPUserAccount) has the credentials,
    // the in-flight reducer mirrors are dropped so a stale token cannot be
    // reused by `makeRequest`. Targets a hand-written mutant that removes
    // `dispatch(.userAccountUpdated)`.
    func test_updateUserAccount_clearsInFlightTokenMirror() {
        businessLogic.selectedAuthentication = libraryMock.oauthAuthentication
        businessLogic.dispatch(.bearerTokenReceived(token: "in-flight", expiration: Date()))
        XCTAssertEqual(businessLogic.authToken, "in-flight", "precondition: mirror is populated")

        businessLogic.updateUserAccount(forDRMAuthorization: true,
                                        withBarcode: "bc", pin: "pin",
                                        authToken: "persisted", expirationDate: nil,
                                        patron: nil, cookies: nil)

        XCTAssertNil(businessLogic.authToken,
                     "The in-flight token mirror must be cleared once TPPUserAccount holds the credentials")
        XCTAssertNil(businessLogic.authTokenExpiration)
        XCTAssertEqual(businessLogic.userAccount.authToken, "persisted",
                       "The canonical store keeps the token that was actually persisted")
    }

    // S5 — the captured barcode/PIN carried from the sign-in form are
    // dropped too, so they do not outlive the flow in memory.
    func test_updateUserAccount_clearsCapturedCredentials() {
        businessLogic.dispatch(.credentialCaptureStarted(barcode: "typed-bc", pin: "typed-pin"))
        XCTAssertEqual(businessLogic.capturedBarcode, "typed-bc", "precondition: capture populated")

        persistBasic()

        XCTAssertNil(businessLogic.capturedBarcode,
                     "Captured barcode must not survive a completed sign-in")
        XCTAssertNil(businessLogic.capturedPin,
                     "Captured PIN must not survive a completed sign-in")
    }

    // S6 — a re-auth that set `ignoreSignedInState` has it cleared by the
    // successful persist, so the app stops pretending the user is signed out.
    func test_updateUserAccount_clearsIgnoreSignedInState() {
        businessLogic.dispatch(.refreshAuthStarted(authType: .saml, usingExistingCredentials: false))
        XCTAssertTrue(businessLogic.ignoreSignedInState, "precondition: browser re-auth sets the override")

        persistBasic()

        XCTAssertFalse(businessLogic.ignoreSignedInState,
                       "A completed sign-in must lift the signed-out override")
        XCTAssertTrue(businessLogic.isSignedIn(),
                      "…and the user reads as signed in again")
    }
}

// MARK: - 4. Signed-in / selected-auth resolution ladders

@MainActor
final class SignInStatePrecedenceCharacterizationTests: SignInFlowFixture {

    private func persistBasic() {
        businessLogic.selectedAuthentication = libraryMock.barcodeAuthentication
        businessLogic.updateUserAccount(forDRMAuthorization: true,
                                        withBarcode: "bc", pin: "pin",
                                        authToken: nil, expirationDate: nil,
                                        patron: nil, cookies: nil)
    }

    // P1 — the positive control for P2/P3: credentials and no override means
    // signed in.
    func test_isSignedIn_trueWithCredentialsAndNoOverride() {
        persistBasic()
        XCTAssertFalse(businessLogic.ignoreSignedInState,
                       "precondition: this control is only meaningful with the override clear")
        XCTAssertTrue(businessLogic.userAccount.hasCredentials(),
                      "precondition: credentials are actually held")
        XCTAssertTrue(businessLogic.isSignedIn(),
                      "credentials held and no override means signed in — the positive control P2/P3 are measured against")
    }

    // P2 — `.credentialsStale` wins over held credentials. This is the SAML
    // IdP-session-expiry case: the keychain still has a token, but the
    // session is dead and the patron must re-authenticate.
    func test_isSignedIn_falseWhenCredentialsAreStale_despiteHeldCredentials() {
        persistBasic()
        businessLogic.userAccount.markCredentialsStale()

        XCTAssertTrue(businessLogic.userAccount.hasCredentials(),
                      "precondition: the credentials are still on file")
        XCTAssertEqual(businessLogic.userAccount.authState, .credentialsStale)
        XCTAssertFalse(businessLogic.isSignedIn(),
                       "A stale session must read as signed out even though credentials exist")
    }

    // P3 — the second override, checked after staleness. Targets a hand-written mutant that
    // deletes the `if ignoreSignedInState { return false }` arm.
    func test_isSignedIn_falseWhenIgnoreSignedInStateIsSet_despiteHeldCredentials() {
        persistBasic()
        businessLogic.dispatch(.refreshAuthStarted(authType: .oidc, usingExistingCredentials: false))

        XCTAssertTrue(businessLogic.userAccount.hasCredentials(),
                      "precondition: the credentials are still on file")
        XCTAssertNotEqual(businessLogic.userAccount.authState, .credentialsStale,
                          "precondition: this is the OTHER override, not staleness")
        XCTAssertFalse(businessLogic.isSignedIn())
    }

    // P4 — a basic/token refresh does NOT set the override, because those
    // refresh inline without a browser redirect. The paired negative that
    // keeps P3 from passing for the wrong reason.
    func test_refreshAuthStarted_basicDoesNotSetSignedOutOverride() {
        persistBasic()
        businessLogic.dispatch(.refreshAuthStarted(authType: .basic, usingExistingCredentials: false))

        XCTAssertFalse(businessLogic.ignoreSignedInState,
                       "Inline (non-browser) re-auth keeps the signed-in appearance")
        XCTAssertTrue(businessLogic.isSignedIn())
    }

    // P5 — rung 1 of the selectedAuthentication ladder: an explicit
    // assignment wins over whatever the persisted account says.
    func test_selectedAuthentication_explicitAssignmentBeatsPersistedDefinition() {
        persistBasic()   // persists the BASIC auth definition on the account
        XCTAssertEqual(businessLogic.userAccount.authDefinition?.authType, .basic,
                       "precondition: the persisted definition is basic")

        businessLogic.selectedAuthentication = libraryMock.oidcAuthentication
        // lint-ignore: FLUFF-001 — `selectedAuthentication` is a COMPUTED
        // 4-rung getter (TPPSignInBusinessLogic.swift:435-446): explicit
        // selection, then `userAccount.authDefinition`, then a sole-auth
        // read, then nil. The assignment sets rung 1 and the assertion
        // reads the ladder's OUTPUT, so this exercises precedence, not
        // Swift property storage. Deleting a rung reddens it — EXCEPT the
        // sole-auth rung: the 2026-09-29 mutation run left `:443`
        // (`auths.count > 1` → `>=`) alive because none of these cells
        // exercises `count == 1`. That case is pinned in
        // `TPPPreferredAuthSelectionTests`, not here.

        XCTAssertEqual(businessLogic.selectedAuthentication?.authType, .oidc,
                       "An explicit selection must win over the persisted auth definition")
    }

    // P6 — rung 2: with nothing explicitly selected, the persisted definition
    // answers. Targets a hand-written mutant that deletes the
    // `guard userAccount.authDefinition == nil` rung.
    func test_selectedAuthentication_fallsBackToPersistedDefinition() {
        persistBasic()
        businessLogic.selectedAuthentication = nil
        // lint-ignore: FLUFF-001 — `selectedAuthentication` is a COMPUTED
        // 4-rung getter (TPPSignInBusinessLogic.swift:435-446): explicit
        // selection, then `userAccount.authDefinition`, then a sole-auth
        // read, then nil. The assignment sets rung 1 and the assertion
        // reads the ladder's OUTPUT, so this exercises precedence, not
        // Swift property storage. Deleting a rung reddens it — EXCEPT the
        // sole-auth rung: the 2026-09-29 mutation run left `:443`
        // (`auths.count > 1` → `>=`) alive because none of these cells
        // exercises `count == 1`. That case is pinned in
        // `TPPPreferredAuthSelectionTests`, not here.

        XCTAssertEqual(businessLogic.selectedAuthentication?.authType, .basic,
                       "With no explicit selection, the persisted auth definition answers")
        XCTAssertEqual(businessLogic.userAccount.authDefinition?.authType, .basic,
                       "and it answers FROM rung 2 — the persisted definition — not from a sole-auth read")
    }

    // P7 — rung 3: a multi-auth library with nothing selected and nothing
    // persisted resolves to nil — the state that makes `logIn()` defer.
    func test_selectedAuthentication_nilOnMultiAuthLibraryWithNothingChosen() {
        XCTAssertGreaterThan(libraryMock.tppAccount.details?.auths.count ?? 0, 1,
                             "fixture precondition: NYPL advertises more than one auth method")
        XCTAssertNil(businessLogic.selectedAuthentication,
                     "A multi-auth library with no choice made resolves to nil, not to auths.first")
    }

    // P8 — rung 4 (the loadState gate): the same library, same auths, but
    // not yet `.detailsLoaded`, also resolves nil — and reverting the state
    // flips it back, proving the read is state-driven rather than latched.
    func test_selectedAuthentication_nilWhileDetailsAreLoading_evenAfterAPriorRead() {
        businessLogic.selectedAuthentication = libraryMock.samlAuthentication
        // lint-ignore: FLUFF-001 — `selectedAuthentication` is a COMPUTED
        // 4-rung getter (TPPSignInBusinessLogic.swift:435-446): explicit
        // selection, then `userAccount.authDefinition`, then a sole-auth
        // read, then nil. The assignment sets rung 1 and the assertion
        // reads the ladder's OUTPUT, so this exercises precedence, not
        // Swift property storage. Deleting a rung reddens it — EXCEPT the
        // sole-auth rung: the 2026-09-29 mutation run left `:443`
        // (`auths.count > 1` → `>=`) alive because none of these cells
        // exercises `count == 1`. That case is pinned in
        // `TPPPreferredAuthSelectionTests`, not here.
        XCTAssertNotNil(businessLogic.selectedAuthentication)

        businessLogic.selectedAuthentication = nil
        setLoading()

        XCTAssertNil(businessLogic.selectedAuthentication,
                     "Pre-load states do not advertise auth methods")
        XCTAssertNil(businessLogic.loadedAccountDetails,
                     "…because loadedAccountDetails is nil outside .detailsLoaded")
    }

    // P9 — `ensureAuthenticationDocumentIsLoaded` short-circuits when the
    // document is already in hand: it reports success without ever marking
    // the document as loading. Targets a hand-written mutant that removes the early return
    // (which would re-fetch on every borrow).
    func test_ensureAuthenticationDocumentIsLoaded_alreadyLoaded_succeedsWithoutMarkingLoading() {
        var reported: Bool?
        businessLogic.ensureAuthenticationDocumentIsLoaded { reported = $0 }

        XCTAssertEqual(reported, true, "An already-loaded auth document reports success synchronously")
        XCTAssertFalse(businessLogic.isAuthenticationDocumentLoading,
                       "The short-circuit must not leave the loading flag raised")
    }

    // P10 — no library account means the load reports FAILURE rather than
    // hanging, so borrow takes its retry/error path (HelpSpot #18414 shape).
    func test_ensureAuthenticationDocumentIsLoaded_noLibraryAccount_reportsFailure() {
        let orphan = TPPSignInBusinessLogic(
            libraryAccountID: "",
            libraryAccountsProvider: libraryMock,
            urlSettingsProvider: TPPURLSettingsProviderMock(),
            bookRegistry: registry,
            bookDownloadsCenter: TPPMyBooksDownloadsCenterMock(),
            userAccountProvider: TPPUserAccountMock.self,
            networkExecutor: networkExecutor,
            uiDelegate: uiDelegate,
            drmAuthorizer: TPPDRMAuthorizingMock())

        var reported: Bool?
        orphan.ensureAuthenticationDocumentIsLoaded { reported = $0 }

        XCTAssertEqual(reported, false,
                       "No account means the auth-document gate fails fast rather than hanging")
        XCTAssertFalse(orphan.isAuthenticationDocumentLoading)
    }
}

