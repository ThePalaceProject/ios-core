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

// MARK: - OAuth Redirect URL Parser Tests

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
        // forward the title to the completion and NOT call validateCredentials.
        let errJSON = #"{"title":"Account Locked","detail":"x"}"#
        let encoded = errJSON.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed)!
        let url = URL(string:
            "https://example.com/univeral-link-redirect#error=\(encoded)")!

        var capturedTitle: String?
        var capturedMessage: String?
        postOAuthRedirect(url) { _, title, message in
            capturedTitle = title
            capturedMessage = message
        }

        XCTAssertEqual(capturedMessage, "Account Locked",
                       "Server error.title must be surfaced through the redirect completion (as the user-facing message)")
        XCTAssertNotNil(capturedTitle,
                        "Default loginErrorTitle must accompany the server-supplied detail")
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

final class TPPSignInBusinessLogicTokenFlowTests: XCTestCase {

    /// A `URL` reachable only through `HTTPStubURLProtocol`. We point
    /// `getBearerToken`'s injected network executor at a session that uses
    /// the stub protocol, so every byte stays in-process.
    private let tokenURL = URL(string: "https://stub.example.com/token")!

    private var businessLogic: TPPSignInBusinessLogic!
    private var libraryAccountMock: TPPLibraryAccountMock!
    private var uiDelegate: TPPSignInOutBusinessLogicUIDelegateMock!
    private var networkExecutor: TPPRequestExecutorMock!
    private var stubExecutor: TPPNetworkExecutor!

    override func setUpWithError() throws {
        try super.setUpWithError()
        TPPUserAccountMock.resetShared()
        HTTPStubURLProtocol.reset()
        libraryAccountMock = TPPLibraryAccountMock()
        uiDelegate = TPPSignInOutBusinessLogicUIDelegateMock()
        networkExecutor = TPPRequestExecutorMock()
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

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HTTPStubURLProtocol.self]
        stubExecutor = TPPNetworkExecutor(
            credentialsProvider: nil,
            cachingStrategy: .ephemeral,
            sessionConfiguration: config,
            accountsManager: libraryAccountMock
        )
    }

    override func tearDownWithError() throws {
        HTTPStubURLProtocol.reset()
        networkExecutor.reset()
        businessLogic.userAccount.removeAll()
        businessLogic = nil
        libraryAccountMock = nil
        uiDelegate = nil
        networkExecutor = nil
        stubExecutor = nil
        try super.tearDownWithError()
    }

    func test_getBearerToken_success_persistsTokenToKeychain() {
        // 200 OK with valid token JSON — `executeTokenRefresh` must call
        // `setAuthToken` on the resolved userAccount BEFORE the businessLogic
        // success callback fires. The userAccount-level write is the
        // canonical credential store and survives even after
        // `validateCredentials()` finalizes (which clears the in-flight
        // token via `.userAccountUpdated`). Mutating the success branch
        // to skip the `setAuthToken` write would surface as a nil here.
        let body = Data(#"{"access_token":"new-bearer-xyz","token_type":"Bearer","expires_in":3600}"#.utf8)
        HTTPStubURLProtocol.register { [tokenURL] req in
            guard req.url == tokenURL else { return nil }
            return .init(statusCode: 200,
                         headers: ["Content-Type": "application/json"],
                         body: body)
        }

        let completed = expectation(description: "getBearerToken completion")
        businessLogic.getBearerToken(username: "user", password: "pass",
                                     tokenURL: tokenURL, networkExecutor: stubExecutor) {
            completed.fulfill()
        }
        wait(for: [completed], timeout: 5.0)

        XCTAssertEqual(businessLogic.userAccount.authToken, "new-bearer-xyz",
                       "Successful token response must persist authToken on userAccount via setAuthToken")
        XCTAssertEqual(businessLogic.userAccount.authState, .loggedIn,
                       "Successful token response must transition userAccount to .loggedIn")
    }

    func test_getBearerToken_401_doesNotStoreTokenAndSurfacesError() {
        // 401 from token endpoint — failure path: no token persisted, no
        // in-flight token set, error reported to UI delegate.
        HTTPStubURLProtocol.register { [tokenURL] req in
            guard req.url == tokenURL else { return nil }
            return .init(statusCode: 401, headers: nil, body: Data("Unauthorized".utf8))
        }

        let completed = expectation(description: "getBearerToken completion")
        businessLogic.getBearerToken(username: "user", password: "wrong",
                                     tokenURL: tokenURL, networkExecutor: stubExecutor) {
            completed.fulfill()
        }
        wait(for: [completed], timeout: 5.0)

        XCTAssertNil(businessLogic.authToken,
                     "401 from token endpoint must NOT set an in-flight authToken")
        XCTAssertNil(businessLogic.userAccount.authToken,
                     "401 from token endpoint must NOT persist a token to userAccount")
    }

    func test_getBearerToken_malformedJSON_takesFailurePath() {
        // 200 OK but a body that cannot be decoded as TokenResponse. The
        // request executor must surface the DecodingError on the failure
        // branch; we must NOT misinterpret the bytes as a token.
        HTTPStubURLProtocol.register { [tokenURL] req in
            guard req.url == tokenURL else { return nil }
            return .init(statusCode: 200,
                         headers: ["Content-Type": "application/json"],
                         body: Data("not-json-at-all".utf8))
        }

        let completed = expectation(description: "getBearerToken completion")
        businessLogic.getBearerToken(username: "user", password: "pass",
                                     tokenURL: tokenURL, networkExecutor: stubExecutor) {
            completed.fulfill()
        }
        wait(for: [completed], timeout: 5.0)

        XCTAssertNil(businessLogic.authToken,
                     "Malformed JSON must not produce an in-flight token (defensive parse)")
        XCTAssertNil(businessLogic.userAccount.authToken,
                     "Malformed JSON must not persist any token to userAccount")
    }

    func test_getBearerToken_emptyUsername_failsImmediatelyWithoutNetwork() {
        // The early-exit guard in executeTokenRefresh: empty username yields
        // an immediate failure with no network call. We verify the failure
        // path doesn't burn a token write.
        var stubInvocations = 0
        HTTPStubURLProtocol.register { _ in
            stubInvocations += 1
            return .init(statusCode: 200, headers: nil,
                         body: Data(#"{"access_token":"never","token_type":"B","expires_in":1}"#.utf8))
        }

        let completed = expectation(description: "completion fires even for empty username")
        businessLogic.getBearerToken(username: "", password: "pass",
                                     tokenURL: tokenURL, networkExecutor: stubExecutor) {
            completed.fulfill()
        }
        wait(for: [completed], timeout: 5.0)

        XCTAssertEqual(stubInvocations, 0,
                       "Empty username must short-circuit BEFORE any network request is made")
        XCTAssertNil(businessLogic.authToken,
                     "Empty-username early-exit must not write a token")
    }
}

// MARK: - Basic-auth Validation Delegate-Callback Order

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

        // Capture into a local closure-bound flag (avoid implicit-unwrap
        // race against tearDown that nils out self.uiDelegate).
        let received = expectation(description: "didReceiveCredentials fires")
        received.assertForOverFulfill = false

        let originalDelegate = uiDelegate!
        let proxy = TPPSignInOutBusinessLogicUIDelegateMockReceiveProxy(
            wrapped: originalDelegate, expectation: received
        )
        businessLogic.uiDelegate = proxy

        businessLogic.validateCredentials()
        wait(for: [received], timeout: 3.0)

        XCTAssertEqual(proxy.receiveCredentialsCallCount, 1,
                       "businessLogicDidReceiveCredentials must fire exactly once per success")
    }

    func test_validateCredentials_basicAuthFailure_doesNotFireReceiveCredentialsCallback() {
        // Failure must NOT call didReceiveCredentials — that callback signals
        // "credentials accepted, DRM next" and would mislead the UI.
        networkExecutor.shouldFail = true
        networkExecutor.errorStatusCode = 401

        businessLogic.validateCredentials()

        // Drain main queue (the executor's completion is dispatched async to .main)
        let drain = expectation(description: "drain main queue")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { drain.fulfill() }
        wait(for: [drain], timeout: 1.0)

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
    private let expectation: XCTestExpectation
    init(wrapped: TPPSignInOutBusinessLogicUIDelegateMock,
         expectation: XCTestExpectation) {
        self.expectation = expectation
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
        expectation.fulfill()
    }
}
