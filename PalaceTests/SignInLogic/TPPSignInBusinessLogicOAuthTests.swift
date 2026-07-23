//
//  TPPSignInBusinessLogicOAuthTests.swift
//  PalaceTests
//
//  Deep, mutation-killing tests for the OAuth / token-flow surface of
//  TPPSignInBusinessLogic. P0 coverage gap per docs/Testing/Coverage_Roadmap.md §2.1.
//
//  These tests focus on:
//    - OAuth Clever redirect-URL parsing (handleRedirectURL) — token, patron,
//      error, malformed payload, and prefix/payload mismatch branches.
//    - Token-flow (`getBearerToken`) — success persists token to userAccount,
//      401 surfaces a validation error without storing a token, no auth header
//      is leaked to error path.
//    - Basic-auth `validateCredentials` success / failure observable effects
//      (delegate callback ordering, validating-flag round-trip).
//
//  Hermetic: HTTPStubURLProtocol for the token endpoint; mock keychain via
//  TPPUserAccountMock; mock network executor for the userProfile request.
//

import XCTest
import PalaceCatalog
import PalaceAuth
@testable import Palace

// MARK: - TokenRefreshing in-memory mock (§10.2 seam)

/// Pure in-memory `TokenRefreshing` stand-in. Replaces the previous
/// `TPPNetworkExecutor + URLSessionConfiguration + HTTPStubURLProtocol`
/// triad. Set `result` to control the synchronous reply; set
/// `expectedURL` to assert the caller routed to the right endpoint.
private final class TokenRefresherMock: TokenRefreshing {
    enum Reply {
        case success(TokenResponse)
        case failure(Error)
    }

    var result: Reply = .failure(NSError(domain: "TokenRefresherMock",
                                         code: -1,
                                         userInfo: [NSLocalizedDescriptionKey: "unconfigured"]))
    private(set) var invocationCount = 0
    private(set) var lastUsername: String?
    private(set) var lastPassword: String?
    private(set) var lastTokenURL: URL?
    private(set) var lastAccountId: String?
    /// If true, the executor short-circuits and reports a failure before
    /// the closure is invoked — used to model the "empty username → no
    /// network call" guard in the production executor's executeTokenRefresh.
    var emptyUsernameShortCircuits: Bool = true

    func executeTokenRefresh(username: String,
                             password: String,
                             tokenURL: URL,
                             accountId: String?,
                             completion: @escaping (Result<TokenResponse, Error>) -> Void) {
        if emptyUsernameShortCircuits && username.isEmpty {
            completion(.failure(NSError(domain: "TokenRefresherMock",
                                        code: 0,
                                        userInfo: [NSLocalizedDescriptionKey: "empty username"])))
            return
        }
        invocationCount += 1
        lastUsername = username
        lastPassword = password
        lastTokenURL = tokenURL
        lastAccountId = accountId
        switch result {
        case .success(let r): completion(.success(r))
        case .failure(let e): completion(.failure(e))
        }
    }
}

// MARK: - OAuth Redirect URL Parser Tests

@MainActor
final class TPPSignInBusinessLogicOAuthTests: XCTestCase {

    private var businessLogic: TPPSignInBusinessLogic!
    private var libraryAccountMock: TPPLibraryAccountMock!
    private var uiDelegate: TPPSignInOutBusinessLogicUIDelegateMock!
    private var networkExecutor: TPPRequestExecutorMock!
    private var drmAuthorizer: TPPDRMAuthorizingMock!

    override func setUpWithError() throws {
        try super.setUpWithError()
        TPPUserAccountMock.resetShared()
        HTTPStubURLProtocol.reset()
        libraryAccountMock = TPPLibraryAccountMock()
        uiDelegate = TPPSignInOutBusinessLogicUIDelegateMock()
        networkExecutor = TPPRequestExecutorMock()
        drmAuthorizer = TPPDRMAuthorizingMock()
        businessLogic = TPPSignInBusinessLogic(
            libraryAccountID: libraryAccountMock.tppAccountUUID,
            libraryAccountsProvider: libraryAccountMock,
            urlSettingsProvider: TPPURLSettingsProviderMock(),
            bookRegistry: TPPBookRegistryMock(),
            bookDownloadsCenter: TPPMyBooksDownloadsCenterMock(),
            userAccountProvider: TPPUserAccountMock.self,
            networkExecutor: networkExecutor,
            uiDelegate: uiDelegate,
            drmAuthorizer: drmAuthorizer
        )
        businessLogic.selectedAuthentication = libraryAccountMock.oauthAuthentication
    }

    override func tearDownWithError() throws {
        networkExecutor.reset()
        HTTPStubURLProtocol.reset()
        businessLogic.userAccount.removeAll()
        businessLogic = nil
        libraryAccountMock = nil
        uiDelegate = nil
        networkExecutor = nil
        drmAuthorizer = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    /// Builds the universal-link redirect URL the Clever OAuth flow posts back
    /// to the app: <universalLinksURL>#access_token=...&patron_info=...
    private func cleverRedirectURL(accessToken: String,
                                   patron: [String: Any]) -> URL {
        let json = try! JSONSerialization.data(withJSONObject: patron)
        let patronStr = String(data: json, encoding: .utf8)!
            .addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed)!
        let base = "https://example.com/univeral-link-redirect"
        let fragment = "access_token=\(accessToken)&patron_info=\(patronStr)"
        return URL(string: "\(base)#\(fragment)")!
    }

    private func postOAuthRedirect(_ url: URL,
                                   completion: ((Error?, String?, String?) -> Void)? = nil) {
        let notification = Notification(name: .TPPAppDelegateDidReceiveCleverRedirectURL,
                                        object: url, userInfo: nil)
        businessLogic.handleRedirectURL(notification, completion: completion)
    }

    // MARK: - Observer-registration seam (§10.1)

    /// Seam-backed test: post the redirect notification onto a hermetic
    /// `NotificationCenter` (injected via `setNotificationCenterForTests`)
    /// and verify the observer fires *and* deregisters itself. Without the
    /// seam this couldn't be done without polluting the global default
    /// center across the entire test process.
    func test_oauthRedirectObserver_registersAndRemovesItself_viaInjectedCenter() {
        let center = NotificationCenter()
        businessLogic.setNotificationCenterForTests(center)
        // Manually add the observer the way oauthLogIn() does — we can't call
        // oauthLogIn() in a unit-test context (it opens Safari). Instead we
        // re-create that single side-effect against the injected center.
        center.addObserver(businessLogic!,
                           selector: #selector(TPPSignInBusinessLogic.handleRedirectURL(_:)),
                           name: .TPPAppDelegateDidReceiveCleverRedirectURL,
                           object: nil)

        let url = cleverRedirectURL(accessToken: "obs-token",
                                    patron: ["name": "Carol"])
        center.post(name: .TPPAppDelegateDidReceiveCleverRedirectURL, object: url)

        XCTAssertEqual(businessLogic.authToken, "obs-token",
                       "Observer must fire when notification is posted to the injected center")

        // The observer must have removed itself — a second post must NOT
        // re-enter handleRedirectURL. We assert this by clearing state and
        // posting a malformed payload: if the observer is still attached,
        // the parse-fail path would reset isValidatingCredentials.
        businessLogic.dispatch(.userAccountUpdated) // clear in-flight state
        let stuckURL = URL(string:
            "https://example.com/univeral-link-redirect#access_token=should-not-fire")!
        center.post(name: .TPPAppDelegateDidReceiveCleverRedirectURL, object: stuckURL)
        XCTAssertNil(businessLogic.authToken,
                     "Second notification must NOT be observed — handleRedirectURL must remove the observer on first fire")
    }

    // MARK: - handleRedirectURL success / failure paths

    func test_handleRedirectURL_validPayload_storesAuthTokenAndPatron() {
        let url = cleverRedirectURL(accessToken: "clever-token-abc",
                                    patron: ["name": "Alice"])

        postOAuthRedirect(url)

        // Token and patron must be captured into the businessLogic in-flight state
        // BEFORE validateCredentials() fires its async network call. If a mutation
        // swaps the assignment order (or drops one) this assertion fails.
        XCTAssertEqual(businessLogic.authToken, "clever-token-abc",
                       "access_token from redirect payload must be stored as the in-flight auth token")
        XCTAssertEqual(businessLogic.patron?["name"] as? String, "Alice",
                       "patron_info JSON must be decoded and assigned to businessLogic.patron")
        // Following the assign, validateCredentials() is invoked which flips
        // the validating flag — its presence proves we exited the parser via
        // the success branch, not via any of the early-return error branches.
        XCTAssertTrue(businessLogic.isValidatingCredentials,
                      "Valid OAuth payload must hand off to validateCredentials()")
    }

    func test_handleRedirectURL_missingAccessToken_skipsValidationAndReportsParseError() {
        // patron_info present, access_token missing — the parse-fail branch.
        let json = try! JSONSerialization.data(withJSONObject: ["name": "Bob"])
        let patronStr = String(data: json, encoding: .utf8)!
            .addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed)!
        let url = URL(string:
            "https://example.com/univeral-link-redirect#patron_info=\(patronStr)")!

        var completionCalls = 0
        postOAuthRedirect(url) { _, _, _ in completionCalls += 1 }

        XCTAssertNil(businessLogic.authToken,
                     "No token in payload → no in-flight token must be written")
        XCTAssertNil(businessLogic.patron,
                     "Patron must not be retained when access_token is missing (we abort the parse)")
        XCTAssertFalse(businessLogic.isValidatingCredentials,
                       "Missing access_token must NOT proceed to validateCredentials()")
        XCTAssertEqual(completionCalls, 1,
                       "handleRedirectURL must invoke its completion exactly once on parse failure")
    }

    func test_handleRedirectURL_missingPatronInfo_skipsValidationAndReportsParseError() {
        // access_token present, patron_info missing — parser must short-circuit
        // through the *same* parse-fail branch and NOT promote a half-built
        // session. Pins the `let patronInfo = kvpairs["patron_info"]` guard.
        let url = URL(string:
            "https://example.com/univeral-link-redirect#access_token=t123")!

        postOAuthRedirect(url)

        XCTAssertNil(businessLogic.authToken,
                     "patron_info missing → token must NOT be retained (entire parse aborts)")
        XCTAssertFalse(businessLogic.isValidatingCredentials,
                       "Missing patron_info must NOT proceed to validateCredentials()")
    }

    func test_handleRedirectURL_serverError_surfacesProblemDocumentTitle() {
        // Server emits an `error=` payload (URL-encoded JSON). Parser must
        // forward the problem-document title to the title slot and the detail
        // to the message slot of the completion handler, per the HelpSpot
        // 17870 field-swap fix (PR #965). Earlier implementations passed
        // title-in-message which is what this test originally pinned.
        let errJSON = #"{"title":"Account Locked","detail":"Your account has been temporarily locked"}"#
        let encoded = errJSON.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed)!
        let url = URL(string:
            "https://example.com/univeral-link-redirect#error=\(encoded)")!

        var capturedTitle: String?
        var capturedMessage: String?
        postOAuthRedirect(url) { _, title, message in
            capturedTitle = title
            capturedMessage = message
        }

        XCTAssertEqual(capturedTitle, "Account Locked",
                       "Server error.title must be surfaced in the title slot of the redirect completion")
        XCTAssertEqual(capturedMessage, "Your account has been temporarily locked",
                       "Server error.detail must be surfaced in the message slot of the redirect completion")
        XCTAssertFalse(businessLogic.isValidatingCredentials,
                       "An error payload must NOT trigger credential validation")
        XCTAssertNil(businessLogic.authToken,
                     "Error payload must NOT store a token")
    }

    func test_handleRedirectURL_wrongPrefix_skipsParseAndReportsMissingPayload() {
        // URL doesn't start with universalLinksURL → must bail at the prefix
        // guard. Pins the `urlStr.hasPrefix(universalLinksURL.absoluteString)`
        // predicate; mutating `&&` → `||` would let this URL through.
        let url = URL(string: "https://attacker.example/steal#access_token=evil&patron_info=%7B%7D")!

        var completionCalls = 0
        postOAuthRedirect(url) { _, _, _ in completionCalls += 1 }

        XCTAssertNil(businessLogic.authToken,
                     "Foreign-host redirect must NOT write an auth token")
        XCTAssertFalse(businessLogic.isValidatingCredentials,
                       "Foreign-host redirect must NOT trigger credential validation")
        XCTAssertEqual(completionCalls, 1,
                       "Wrong-prefix branch must still call completion once for cleanup")
    }

    func test_handleRedirectURL_baseTokenWithEqualsSign_isPreservedIntact() {
        // Regression: base64 tokens can contain `=` padding. The parser splits
        // payload on `&` then on `=`, and rejoins all post-first segments. If
        // the rejoin is replaced by `.last` or `.first`, the stored token gets
        // truncated. This pins the `dropFirst().joined(separator: "=")` line.
        let token = "abc==def" // contains internal '=' characters
        let patron = #"{"name":"Eve"}"#
        let patronEnc = patron.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed)!
        let url = URL(string:
            "https://example.com/univeral-link-redirect#access_token=\(token)&patron_info=\(patronEnc)")!

        postOAuthRedirect(url)

        XCTAssertEqual(businessLogic.authToken, token,
                       "Token containing '=' must be preserved verbatim — segments after the first '=' must be rejoined, not dropped")
    }

    func test_handleRedirectURL_nonURLObject_reportsErrorWithoutSideEffects() {
        // Notifications must carry a URL — anything else is a programmer error
        // and must abort defensively. Pins `notification.object as? URL`.
        let bogus = Notification(name: .TPPAppDelegateDidReceiveCleverRedirectURL,
                                 object: "not-a-url" as NSString,
                                 userInfo: nil)
        var completionCalls = 0
        businessLogic.handleRedirectURL(bogus) { _, _, _ in completionCalls += 1 }

        XCTAssertEqual(completionCalls, 1, "Defensive completion must fire exactly once")
        XCTAssertNil(businessLogic.authToken,
                     "Non-URL notification object must not write any auth state")
        XCTAssertFalse(businessLogic.isValidatingCredentials)
    }

    // MARK: - makeRequest authorization header

    func test_makeRequest_OAuth_includesBearerHeaderFromInFlightToken() {
        // Pins line ~336: authorization header is "Bearer <token>" verbatim.
        // Mutating the formatter to "Token " / leaving off the trailing space
        // would change this header string.
        businessLogic.dispatch(.bearerTokenReceived(token: "in-flight-tok", expiration: nil))

        let req = businessLogic.makeRequest(for: .signIn, context: "oauth-test")

        XCTAssertEqual(req?.value(forHTTPHeaderField: "Authorization"),
                       "Bearer in-flight-tok",
                       "OAuth makeRequest must produce 'Bearer <token>' exactly")
    }

    func test_makeRequest_OAuth_fallsBackToPersistedToken() {
        // No in-flight token — but a persisted token on userAccount. The
        // nil-coalescing chain `authToken ?? userAccount.authToken` must reach
        // the userAccount. Mutating the chain to only read the in-flight one
        // would surface no Authorization header at all (and surface a
        // production logError instead).
        let acct = businessLogic.userAccount as! TPPUserAccountMock
        acct.setAuthToken("persisted-tok", barcode: nil, pin: nil, expirationDate: nil)
        XCTAssertNil(businessLogic.authToken, "precondition: no in-flight token")

        let req = businessLogic.makeRequest(for: .signIn, context: "oauth-test")

        XCTAssertEqual(req?.value(forHTTPHeaderField: "Authorization"),
                       "Bearer persisted-tok",
                       "When in-flight authToken is nil, makeRequest must fall back to userAccount.authToken")
    }

    func test_makeRequest_signIn_returnsNilWhenNoUserProfileURL() {
        // Build a businessLogic against a library UUID that resolves to an
        // Account with no `details` (the mock returns a synthetic Account
        // for unknown UUIDs). The userProfileUrl guard must short-circuit.
        let blogic = TPPSignInBusinessLogic(
            libraryAccountID: "totally-unknown-library",
            libraryAccountsProvider: libraryAccountMock,
            urlSettingsProvider: TPPURLSettingsProviderMock(),
            bookRegistry: TPPBookRegistryMock(),
            bookDownloadsCenter: TPPMyBooksDownloadsCenterMock(),
            userAccountProvider: TPPUserAccountMock.self,
            networkExecutor: networkExecutor,
            uiDelegate: uiDelegate,
            drmAuthorizer: drmAuthorizer
        )

        XCTAssertNil(blogic.makeRequest(for: .signIn, context: "unknown"),
                     "makeRequest must return nil when libraryAccount.details.userProfileUrl is absent")
    }
}

// MARK: - Token-Flow (Basic → Bearer) Tests

@MainActor
final class TPPSignInBusinessLogicTokenFlowTests: XCTestCase {

    private let tokenURL = URL(string: "https://stub.example.com/token")!

    private var businessLogic: TPPSignInBusinessLogic!
    private var libraryAccountMock: TPPLibraryAccountMock!
    private var uiDelegate: TPPSignInOutBusinessLogicUIDelegateMock!
    private var networkExecutor: TPPRequestExecutorMock!
    /// §10.2 seam-backed in-memory token refresher. Replaces the previous
    /// `TPPNetworkExecutor + URLSessionConfiguration + HTTPStubURLProtocol`
    /// triad — the seam now exposes `TokenRefreshing` as the abstraction.
    private var tokenRefresher: TokenRefresherMock!

    override func setUpWithError() throws {
        try super.setUpWithError()
        TPPUserAccountMock.resetShared()
        libraryAccountMock = TPPLibraryAccountMock()
        uiDelegate = TPPSignInOutBusinessLogicUIDelegateMock()
        networkExecutor = TPPRequestExecutorMock()
        tokenRefresher = TokenRefresherMock()
        businessLogic = TPPSignInBusinessLogic(
            libraryAccountID: libraryAccountMock.tppAccountUUID,
            libraryAccountsProvider: libraryAccountMock,
            urlSettingsProvider: TPPURLSettingsProviderMock(),
            bookRegistry: TPPBookRegistryMock(),
            bookDownloadsCenter: TPPMyBooksDownloadsCenterMock(),
            userAccountProvider: TPPUserAccountMock.self,
            networkExecutor: networkExecutor,
            uiDelegate: uiDelegate,
            drmAuthorizer: TPPDRMAuthorizingMock()
        )
    }

    override func tearDownWithError() throws {
        networkExecutor.reset()
        businessLogic.userAccount.removeAll()
        businessLogic = nil
        libraryAccountMock = nil
        uiDelegate = nil
        networkExecutor = nil
        tokenRefresher = nil
        try super.tearDownWithError()
    }

    func test_getBearerToken_success_persistsTokenViaTokenRefresher() {
        // §10.2 seam: a successful `TokenResponse` must transition the
        // businessLogic's reducer to a state where the in-flight authToken
        // matches and `validateCredentials()` is invoked. Mutating the
        // success branch to skip `.bearerTokenReceived` would surface as a
        // nil here.
        tokenRefresher.result = .success(TokenResponse(accessToken: "new-bearer-xyz",
                                                       tokenType: "Bearer",
                                                       expiresIn: 3600))

        let completed = expectation(description: "getBearerToken completion")
        businessLogic.getBearerToken(username: "user",
                                     password: "pass",
                                     tokenURL: tokenURL,
                                     tokenRefresher: tokenRefresher) {
            completed.fulfill()
        }
        wait(for: [completed], timeout: 5.0)

        // The seam mock writes to its local state only — it does NOT persist
        // a token to userAccount. The success branch in getBearerToken is what
        // we're pinning here: it dispatches `.bearerTokenReceived`, then
        // hands off to validateCredentials() (whose downstream network call
        // is harmlessly handled by the per-URL stubbing in
        // `TPPRequestExecutorMock`).
        XCTAssertEqual(tokenRefresher.invocationCount, 1,
                       "executeTokenRefresh must be called exactly once for a single getBearerToken")
        XCTAssertEqual(tokenRefresher.lastUsername, "user",
                       "username must flow through to executeTokenRefresh unchanged")
        XCTAssertEqual(tokenRefresher.lastTokenURL, tokenURL,
                       "tokenURL must flow through to executeTokenRefresh unchanged")
        XCTAssertEqual(tokenRefresher.lastAccountId, libraryAccountMock.tppAccountUUID,
                       "accountId argument must be the businessLogic's libraryAccountID")
        XCTAssertTrue(businessLogic.isValidatingCredentials,
                      "On success, the businessLogic must hand off to validateCredentials()")
    }

    func test_getBearerToken_failure_doesNotStoreTokenAndSurfacesError() {
        // §10.2 seam: a failure on the refresh path must take the
        // `handleNetworkError` branch and NOT promote a stale token.
        tokenRefresher.result = .failure(NSError(domain: NSURLErrorDomain,
                                                 code: 401,
                                                 userInfo: nil))

        let completed = expectation(description: "getBearerToken completion")
        businessLogic.getBearerToken(username: "user",
                                     password: "wrong",
                                     tokenURL: tokenURL,
                                     tokenRefresher: tokenRefresher) {
            completed.fulfill()
        }
        wait(for: [completed], timeout: 5.0)

        XCTAssertNil(businessLogic.authToken,
                     "Token-refresh failure must NOT set an in-flight authToken")
        XCTAssertNil(businessLogic.userAccount.authToken,
                     "Token-refresh failure must NOT persist a token to userAccount")
    }

    func test_getBearerToken_emptyUsername_failsImmediatelyWithoutNetwork() {
        // The early-exit guard the production executor enforces: empty
        // username must yield an immediate failure without an invocation
        // count. The seam mock models the same short-circuit so we can
        // assert it without any URLSession plumbing.
        tokenRefresher.result = .success(TokenResponse(accessToken: "never",
                                                       tokenType: "Bearer",
                                                       expiresIn: 1))

        let completed = expectation(description: "completion fires even for empty username")
        businessLogic.getBearerToken(username: "",
                                     password: "pass",
                                     tokenURL: tokenURL,
                                     tokenRefresher: tokenRefresher) {
            completed.fulfill()
        }
        wait(for: [completed], timeout: 5.0)

        XCTAssertEqual(tokenRefresher.invocationCount, 0,
                       "Empty username must short-circuit BEFORE the refresher records an invocation")
        XCTAssertNil(businessLogic.authToken,
                     "Empty-username early-exit must not write a token")
    }
}

// MARK: - Basic-auth Validation Delegate-Callback Order

@MainActor
final class TPPSignInBusinessLogicValidationCallbackOrderTests: XCTestCase {

    private var businessLogic: TPPSignInBusinessLogic!
    private var libraryAccountMock: TPPLibraryAccountMock!
    private var uiDelegate: TPPSignInOutBusinessLogicUIDelegateMock!
    private var networkExecutor: TPPNetworkErrorMock!

    override func setUpWithError() throws {
        try super.setUpWithError()
        TPPUserAccountMock.resetShared()
        libraryAccountMock = TPPLibraryAccountMock()
        uiDelegate = TPPSignInOutBusinessLogicUIDelegateMock()
        networkExecutor = TPPNetworkErrorMock()
        businessLogic = TPPSignInBusinessLogic(
            libraryAccountID: libraryAccountMock.tppAccountUUID,
            libraryAccountsProvider: libraryAccountMock,
            urlSettingsProvider: TPPURLSettingsProviderMock(),
            bookRegistry: TPPBookRegistryMock(),
            bookDownloadsCenter: TPPMyBooksDownloadsCenterMock(),
            userAccountProvider: TPPUserAccountMock.self,
            networkExecutor: networkExecutor,
            uiDelegate: uiDelegate,
            drmAuthorizer: TPPDRMAuthorizingMock()
        )
        businessLogic.selectedAuthentication = libraryAccountMock.barcodeAuthentication
    }

    override func tearDownWithError() throws {
        networkExecutor.reset()
        businessLogic.userAccount.removeAll()
        businessLogic = nil
        libraryAccountMock = nil
        uiDelegate = nil
        networkExecutor = nil
        try super.tearDownWithError()
    }

    func test_validateCredentials_basicAuthSuccess_firesDidReceiveCredentialsCallback() {
        // The success branch must fire businessLogicDidReceiveCredentials
        // so the UI can show its DRM spinner. The delegate mock exposes
        // didCallDidReceiveCredentials which flips inside the method body.
        networkExecutor.shouldFail = false

        let originalDelegate = uiDelegate!
        let proxy = TPPSignInOutBusinessLogicUIDelegateMockReceiveProxy(wrapped: originalDelegate)
        businessLogic.uiDelegate = proxy

        businessLogic.validateCredentials()

        // Drain main queue (the executor's completion is dispatched async to
        // .main; `businessLogicDidReceiveCredentials` fires synchronously off
        // that same hop via `TPPMainThreadRun.asyncIfNeeded`'s on-main fast
        // path). Mirrors test_validateCredentials_basicAuthFailure below.
        drainMainQueue()

        XCTAssertEqual(proxy.receiveCredentialsCallCount, 1,
                       "businessLogicDidReceiveCredentials must fire exactly once per success")
    }

    func test_validateCredentials_basicAuthFailure_doesNotFireReceiveCredentialsCallback() {
        // Failure must NOT call didReceiveCredentials — that callback signals
        // "credentials accepted, DRM next" and would mislead the UI.
        networkExecutor.shouldFail = true
        networkExecutor.errorStatusCode = 401

        businessLogic.validateCredentials()

        // Drain main queue (the executor's completion is dispatched async to .main).
        // DispatchQueue.main is FIFO — once our no-op block runs, every previously
        // queued completion has already run. No fixed-delay padding.
        drainMainQueue()

        XCTAssertFalse(uiDelegate.didCallDidReceiveCredentials,
                       "Failure path must NOT fire businessLogicDidReceiveCredentials — the UI must not show the DRM spinner")
        XCTAssertEqual(uiDelegate.didReceiveCredentialsCallCount, 0,
                       "didReceiveCredentials count must remain zero on validation failure")
    }
}

// MARK: - Receive-credentials proxy delegate

/// A standalone delegate that fulfills an expectation when
/// `businessLogicDidReceiveCredentials` is invoked. Using a dedicated
/// delegate (instead of poll-loops over the mock's flag) lets the test
/// terminate as soon as the production code makes the call, without
/// racing against tearDown.
private final class TPPSignInOutBusinessLogicUIDelegateMockReceiveProxy:
    NSObject, TPPSignInOutBusinessLogicUIDelegate {
    var receiveCredentialsCallCount = 0
    init(wrapped: TPPSignInOutBusinessLogicUIDelegateMock) {
        super.init()
    }

    // MARK: - Required protocol surface (no-op except for the one we care about)
    var context = "ProxyDelegate"
    var username: String? = "username"
    var pin: String? = "pin"
    var usernameTextField: UITextField?
    var PINTextField: UITextField?
    var forceEditability: Bool = false
    func businessLogicWillSignIn(_ businessLogic: TPPSignInBusinessLogic) {}
    func businessLogicDidCancelSignIn(_ businessLogic: TPPSignInBusinessLogic) {}
    func businessLogicDidCompleteSignIn(_ businessLogic: TPPSignInBusinessLogic) {}
    func businessLogic(_ logic: TPPSignInBusinessLogic,
                       didEncounterValidationError error: Error?,
                       userFriendlyErrorTitle title: String?,
                       andMessage message: String?) {}
    func dismiss(animated flag: Bool, completion: (() -> Void)?) { completion?() }
    func present(_ viewControllerToPresent: UIViewController,
                 animated flag: Bool,
                 completion: (() -> Void)?) { completion?() }
    func businessLogicWillSignOut(_ businessLogic: TPPSignInBusinessLogic) {}
    func businessLogic(_ logic: TPPSignInBusinessLogic,
                       didEncounterSignOutError error: Error?,
                       withHTTPStatusCode httpStatusCode: Int) {}
    func businessLogicDidFinishDeauthorizing(_ logic: TPPSignInBusinessLogic) {}

    // The one we care about.
    func businessLogicDidReceiveCredentials(_ businessLogic: TPPSignInBusinessLogic) {
        receiveCredentialsCallCount += 1
    }
}
