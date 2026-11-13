//  SignInTokenContractTests.swift
//
//  Contract snapshots for what TPPSignInBusinessLogic does after a bearer
//  token arrives: an OAuth or SAML redirect, an OIDC callback, or a token
//  exchange. Each pins the reducer actions, patron writes, the profile request,
//  the delegate callbacks and the progress reports, in order. These record the
//  current behavior so a move of the follow-up validation into an AuthReducer
//  effect (PP-5558) shows up as a snapshot diff.

import Combine
import XCTest
import PalaceAuth
import PalaceCatalog
@testable import Palace

@MainActor
final class SignInTokenContractTests: XCTestCase {

    private let tokenURL = URL(string: "https://library.test/token")!

    private var log: CallLog!
    private var libraryAccounts: ProgressRecordingLibraryAccountMock!
    private var uiDelegate: SignInDelegateSpy!
    private var executor: ValidationExecutorSpy!
    private var tokenExchange: TokenExchangeSpy!
    private var businessLogic: RecordingSignInBusinessLogic!

    override func setUp() async throws {
        try await super.setUp()
        TPPUserAccountMock.resetShared()
        log = CallLog()
        libraryAccounts = ProgressRecordingLibraryAccountMock(log: log)
        uiDelegate = SignInDelegateSpy(log: log)
        executor = ValidationExecutorSpy(log: log)
        tokenExchange = TokenExchangeSpy(log: log)
        businessLogic = makeBusinessLogic()
    }

    override func tearDown() async throws {
        businessLogic?.userAccount.removeAll()
        businessLogic = nil
        tokenExchange = nil
        executor = nil
        uiDelegate = nil
        libraryAccounts = nil
        log = nil
        try await super.tearDown()
    }

    // MARK: - Fixtures

    private func makeBusinessLogic() -> RecordingSignInBusinessLogic {
        let logic = RecordingSignInBusinessLogic(
            libraryAccountID: libraryAccounts.tppAccountUUID,
            libraryAccountsProvider: libraryAccounts,
            urlSettingsProvider: TPPURLSettingsProviderMock(),
            bookRegistry: RegistrySyncSpy(log: log),
            bookDownloadsCenter: TPPMyBooksDownloadsCenterMock(),
            userAccountProvider: TPPUserAccountMock.self,
            networkExecutor: executor,
            uiDelegate: uiDelegate,
            drmAuthorizer: TPPDRMAuthorizingMock(),
            appNetwork: tokenExchange)
        logic.callLog = log
        let callLog = log!
        logic.openInBrowser = { url in callLog.record("openInBrowser", args: ["host": url.host ?? "nil"]) }
        return logic
    }

    private static func patronComponent(_ name: String, allowed: CharacterSet) -> String {
        "{\"name\":\"\(name)\"}".addingPercentEncoding(withAllowedCharacters: allowed)!
    }

    /// Universal-link redirect; OAuth carries the payload in the fragment.
    private static func oauthRedirect(token: String, patron: String = "Alice") -> URL {
        URL(string: "https://example.com/univeral-link-redirect#access_token=\(token)"
            + "&patron_info=\(patronComponent(patron, allowed: .urlFragmentAllowed))")!
    }

    /// Universal-link redirect; SAML carries the payload in the query.
    private static func samlRedirect(token: String) -> URL {
        URL(string: "https://example.com/univeral-link-redirect?access_token=\(token)"
            + "&patron_info=\(patronComponent("Sam", allowed: .urlQueryAllowed))")!
    }

    private static func oidcCallback(query: String) -> URL {
        URL(string: "palace-oidc-callback://org.thepalaceproject.oidc/callback?\(query)")!
    }

    private static let oidcSuccessQuery =
        "access_token=oidc-token&patron_info=\(patronComponent("Olive", allowed: .urlQueryAllowed))"

    private static func errorFragment(title: String) -> String {
        "{\"title\":\"\(title)\",\"detail\":\"Try later\"}"
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
    }

    /// The shared auth-document fixture has no token method and its OAuth
    /// method has no `authenticate` link, so both are built here.
    private static func makeAuthentication(type: String, href: String) throws -> AccountDetails.Authentication {
        let json = """
        {"type": "\(type)", "links": [{"rel": "authenticate", "href": "\(href)"}]}
        """
        let docAuth = try JSONDecoder().decode(OPDS2AuthenticationDocument.Authentication.self,
                                               from: Data(json.utf8))
        return AccountDetails.Authentication(auth: docAuth)
    }

    private func makeTokenAuthentication() throws -> AccountDetails.Authentication {
        try Self.makeAuthentication(type: "http://thepalaceproject.org/authtype/basic-token",
                                    href: tokenURL.absoluteString)
    }

    /// Starts an OAuth sign-in whose browser redirects arrive through `redirects`.
    private func startOAuthSignIn() async throws -> PassthroughSubject<URL, Never> {
        let redirects = PassthroughSubject<URL, Never>()
        businessLogic.selectedAuthentication = try Self.makeAuthentication(
            type: "http://librarysimplified.org/authtype/OAuth-with-intermediary",
            href: "https://circulation.example.com/NYNYPL/oauth_authenticate?provider=Clever")
        businessLogic.signInRedirects = { redirects.eraseToAnyPublisher() }
        await businessLogic.logIn()
        return redirects
    }

    /// Records what the sign-in left in the persisted account.
    private func recordStoredAccount() {
        let account = businessLogic.userAccount
        log.record("storedAccount", args: [
            "authToken": account.authToken ?? "nil",
            "patronName": (account.patron?["name"] as? String) ?? "nil",
            "cookieCount": account.cookies?.count ?? 0,
        ])
    }

    private func exchangeToken(_ reply: Result<TokenResponse, Error>) async {
        tokenExchange.reply = reply
        let completed = Signal()
        let callLog = log!
        businessLogic.getBearerToken(username: "barcode", password: "pin",
                                     tokenURL: tokenURL, tokenRefresher: tokenExchange) {
            callLog.record("getBearerTokenCompletion")
            completed.fire()
        }
        await completed.wait()
        await businessLogic._awaitSignInWorkForTesting()
    }

    // MARK: - OAuth redirect

    /// A valid OAuth redirect stores the token and patron, then sends one profile
    /// request with the bearer before the sign-in completes.
    func testOAuthRedirect_WithTokenAndPatron_ValidatesThenCompletesSignIn() async throws {
        let redirects = try await startOAuthSignIn()

        redirects.send(Self.oauthRedirect(token: "oauth-token"))
        await businessLogic._awaitSignInWorkForTesting()
        recordStoredAccount()

        ContractSnapshot.assert(log, named: "oauthRedirect_success")
    }

    /// The subscription takes only the first redirect, so a second link starts no
    /// second validation.
    func testOAuthRedirect_SecondRedirectAfterFirst_IsIgnored() async throws {
        let redirects = try await startOAuthSignIn()

        redirects.send(Self.oauthRedirect(token: "first-token"))
        redirects.send(Self.oauthRedirect(token: "second-token", patron: "Mallory"))
        await businessLogic._awaitSignInWorkForTesting()
        recordStoredAccount()

        ContractSnapshot.assert(log, named: "oauthRedirect_secondRedirectIgnored")
    }

    /// An `error=` redirect makes no profile request.
    func testOAuthRedirect_WithErrorPayload_MakesNoValidationRequest() async throws {
        let redirects = try await startOAuthSignIn()

        redirects.send(URL(string: "https://example.com/univeral-link-redirect#error="
                           + Self.errorFragment(title: "Account Locked"))!)
        await businessLogic._awaitSignInWorkForTesting()
        recordStoredAccount()

        ContractSnapshot.assert(log, named: "oauthRedirect_errorPayload")
    }

    /// A redirect with patron info but no access token makes no profile request.
    func testOAuthRedirect_WithoutAccessToken_MakesNoValidationRequest() async throws {
        let redirects = try await startOAuthSignIn()

        redirects.send(URL(string: "https://example.com/univeral-link-redirect#patron_info="
                           + Self.patronComponent("Bob", allowed: .urlFragmentAllowed))!)
        await businessLogic._awaitSignInWorkForTesting()
        recordStoredAccount()

        ContractSnapshot.assert(log, named: "oauthRedirect_missingToken")
    }

    // MARK: - SAML redirect

    /// A valid SAML redirect keeps the cookies, completes the redirect, then
    /// validates and stores the token, patron and cookies.
    func testSAMLRedirect_WithTokenAndPatron_CompletesRedirectThenValidates() async {
        businessLogic.selectedAuthentication = libraryAccounts.samlAuthentication
        let context = LegacySAMLAuthContext()
        context.businessLogic = businessLogic
        let cookie = HTTPCookie(properties: [.name: "saml", .value: "session",
                                             .domain: "idp.example.com", .path: "/"])!
        let callLog = log!

        context.handleSAMLRedirect(url: Self.samlRedirect(token: "saml-token"), cookies: [cookie]) { error, title, _ in
            callLog.record("redirectCompletion", args: ["error": error == nil ? "nil" : "set",
                                                        "title": title ?? "nil"])
        }
        await businessLogic._awaitSignInWorkForTesting()
        recordStoredAccount()

        ContractSnapshot.assert(log, named: "samlRedirect_success")
    }

    /// A SAML `error=` redirect hands the title to the redirect completion and
    /// makes no profile request.
    func testSAMLRedirect_WithErrorPayload_CompletesWithErrorAndMakesNoRequest() async {
        businessLogic.selectedAuthentication = libraryAccounts.samlAuthentication
        let context = LegacySAMLAuthContext()
        context.businessLogic = businessLogic
        let callLog = log!
        let url = URL(string: "https://example.com/univeral-link-redirect?error="
                      + Self.errorFragment(title: "Account Locked"))!

        context.handleSAMLRedirect(url: url, cookies: []) { error, title, _ in
            callLog.record("redirectCompletion", args: ["error": error == nil ? "nil" : "set",
                                                        "title": title ?? "nil"])
        }
        await businessLogic._awaitSignInWorkForTesting()
        recordStoredAccount()

        ContractSnapshot.assert(log, named: "samlRedirect_errorPayload")
    }

    // MARK: - OIDC callback

    /// A valid OIDC callback stores the token and patron, then validates.
    func testOIDCCallback_WithTokenAndPatron_ValidatesThenCompletesSignIn() async {
        businessLogic.selectedAuthentication = libraryAccounts.oidcAuthentication

        businessLogic.handleOIDCCallback(Self.oidcCallback(query: Self.oidcSuccessQuery))
        await businessLogic._awaitSignInWorkForTesting()
        recordStoredAccount()

        ContractSnapshot.assert(log, named: "oidcCallback_success")
    }

    /// An RFC 6749 `error=` callback reports the description and makes no request.
    func testOIDCCallback_WithProviderError_ReportsErrorAndMakesNoRequest() async {
        businessLogic.selectedAuthentication = libraryAccounts.oidcAuthentication

        businessLogic.handleOIDCCallback(
            Self.oidcCallback(query: "error=access_denied&error_description=Consent+declined"))
        await businessLogic._awaitSignInWorkForTesting()
        recordStoredAccount()

        ContractSnapshot.assert(log, named: "oidcCallback_providerError")
    }

    /// A callback with patron info but no access token makes no profile request.
    func testOIDCCallback_WithoutAccessToken_MakesNoValidationRequest() async {
        businessLogic.selectedAuthentication = libraryAccounts.oidcAuthentication

        businessLogic.handleOIDCCallback(Self.oidcCallback(
            query: "patron_info=\(Self.patronComponent("Olive", allowed: .urlQueryAllowed))"))
        await businessLogic._awaitSignInWorkForTesting()
        recordStoredAccount()

        ContractSnapshot.assert(log, named: "oidcCallback_missingToken")
    }

    // MARK: - Token exchange

    /// The exchange's completion runs from a `defer`, after validation is
    /// scheduled but before its request is sent.
    func testTokenExchange_Success_CompletesBeforeValidationRequest() async throws {
        businessLogic.selectedAuthentication = try makeTokenAuthentication()

        await exchangeToken(.success(TokenResponse(accessToken: "exchanged-token",
                                                   tokenType: "Bearer", expiresIn: 3600)))
        recordStoredAccount()

        ContractSnapshot.assert(log, named: "tokenExchange_success")
    }

    /// A failed exchange reports the error, then completes, with no request.
    func testTokenExchange_Failure_ReportsErrorAndMakesNoRequest() async throws {
        businessLogic.selectedAuthentication = try makeTokenAuthentication()

        await exchangeToken(.failure(NSError(domain: TokenRequest.httpErrorDomain, code: 401)))
        recordStoredAccount()

        ContractSnapshot.assert(log, named: "tokenExchange_failure")
    }

    /// When the business logic is released before the exchange replies, only
    /// the completion runs: no reducer action, no request.
    func testTokenExchange_BusinessLogicReleasedMidExchange_OnlyCompletes() async throws {
        businessLogic.selectedAuthentication = try makeTokenAuthentication()
        tokenExchange.reply = nil
        let completed = Signal()
        let callLog = log!
        businessLogic.getBearerToken(username: "barcode", password: "pin",
                                     tokenURL: tokenURL, tokenRefresher: tokenExchange) {
            callLog.record("getBearerTokenCompletion")
            completed.fire()
        }
        weak let released = businessLogic
        businessLogic = nil
        XCTAssertNil(released, "precondition: nothing else keeps the business logic alive")

        tokenExchange.deliverHeldReply(.success(TokenResponse(accessToken: "late-token",
                                                              tokenType: "Bearer", expiresIn: 3600)))
        await completed.wait()

        ContractSnapshot.assert(log, named: "tokenExchange_releasedMidExchange")
    }

    // MARK: - Overlapping tokens

    /// A second token that arrives while the first validation is in flight
    /// starts a second validation. The first validation then stores the second
    /// token, and the second validation finalizes with no token left in state.
    func testSecondToken_WhileFirstValidationInFlight_StartsSecondValidation() async {
        businessLogic.selectedAuthentication = libraryAccounts.oauthAuthentication
        executor.holdResponses = true

        businessLogic.handleRedirectURL(Self.oauthRedirect(token: "token-A", patron: "Alice"))
        let firstSent = await executor.requestArrived[0].wait()
        XCTAssertTrue(firstSent, "the first token must send a profile request")
        businessLogic.handleRedirectURL(Self.oauthRedirect(token: "token-B", patron: "Bea"))
        let secondSent = await executor.requestArrived[1].wait()
        XCTAssertTrue(secondSent, "the second token must send a profile request")

        executor.releaseResponse[0].fire()
        await uiDelegate.signInCompleted[0].wait()
        executor.releaseResponse[1].fire()
        await businessLogic._awaitSignInWorkForTesting()
        recordStoredAccount()

        ContractSnapshot.assert(log, named: "secondTokenDuringValidation")
    }
}

// MARK: - Spies

/// One-shot wake-up that tolerates `fire()` before `wait()`. The bound only
/// ends a wait for an event that never comes, so a missing call fails the test
/// with a snapshot diff instead of hanging the run.
private final class Signal: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var waiter: CheckedContinuation<Bool, Never>?

    func fire() {
        lock.lock()
        fired = true
        let pending = waiter
        waiter = nil
        lock.unlock()
        pending?.resume(returning: true)
    }

    private func expire() {
        lock.lock()
        let pending = waiter
        waiter = nil
        lock.unlock()
        pending?.resume(returning: false)
    }

    /// Returns false when the bound passed first.
    @discardableResult
    func wait(upTo seconds: Double = 30) async -> Bool {
        await withCheckedContinuation { continuation in
            lock.lock()
            if fired {
                lock.unlock()
                continuation.resume(returning: true)
                return
            }
            waiter = continuation
            lock.unlock()
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                self?.expire()
            }
        }
    }
}

/// Records reducer actions and patron writes of the real business logic.
private final class RecordingSignInBusinessLogic: TPPSignInBusinessLogic {
    var callLog: CallLog?

    override func dispatch(_ action: AuthAction) {
        callLog?.record("dispatch", args: Self.describe(action))
        super.dispatch(action)
    }

    override var patron: [String: Any]? {
        didSet {
            callLog?.record("patronSet", args: ["name": (patron?["name"] as? String) ?? "nil"])
        }
    }

    private static func describe(_ action: AuthAction) -> [String: Any] {
        switch action {
        case let .bearerTokenReceived(token, expiration):
            return ["action": "bearerTokenReceived", "token": token, "hasExpiration": expiration != nil]
        case let .credentialsValidationFailed(title, _):
            return ["action": "credentialsValidationFailed", "title": title ?? "nil"]
        default:
            let name = Mirror(reflecting: action).children.first?.label ?? "\(action)"
            return ["action": name]
        }
    }
}

/// Nonisolated, like the `@objc` protocol it implements, so every method is the
/// protocol witness (including the optional `businessLogicDidReceiveCredentials`).
private final class SignInDelegateSpy: NSObject, TPPSignInOutBusinessLogicUIDelegate, @unchecked Sendable {
    private let log: CallLog
    private let lock = NSLock()
    private var completedCount = 0
    let signInCompleted = (0..<4).map { _ in Signal() }

    init(log: CallLog) {
        self.log = log
        super.init()
    }

    let context = "SignInTokenContractTests"
    var username: String? { nil }
    var pin: String? { nil }
    var usernameTextField: UITextField?
    var PINTextField: UITextField?
    var forceEditability: Bool { false }

    func businessLogicWillSignIn(_ businessLogic: TPPSignInBusinessLogic) {
        log.record("delegate.willSignIn")
    }

    func businessLogicDidCancelSignIn(_ businessLogic: TPPSignInBusinessLogic) {
        log.record("delegate.didCancelSignIn")
    }

    func businessLogicDidReceiveCredentials(_ businessLogic: TPPSignInBusinessLogic) {
        log.record("delegate.didReceiveCredentials")
    }

    func businessLogicDidCompleteSignIn(_ businessLogic: TPPSignInBusinessLogic) {
        log.record("delegate.didCompleteSignIn")
        let index = lock.withLock { () -> Int in
            defer { completedCount += 1 }
            return completedCount
        }
        if index < signInCompleted.count { signInCompleted[index].fire() }
    }

    func businessLogic(_ logic: TPPSignInBusinessLogic,
                       didEncounterValidationError error: Error?,
                       userFriendlyErrorTitle title: String?,
                       andMessage message: String?) {
        log.record("delegate.didEncounterValidationError",
                   args: ["title": title ?? "nil", "message": message ?? "nil"])
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

/// Answers the profile request with a valid profile document. With
/// `holdResponses`, each answer waits for its `releaseResponse` signal.
private final class ValidationExecutorSpy: TPPRequestExecuting, @unchecked Sendable {
    private let log: CallLog
    private let lock = NSLock()
    private var requestCount = 0
    private var _holdResponses = false
    var holdResponses: Bool {
        get { lock.withLock { _holdResponses } }
        set { lock.withLock { _holdResponses = newValue } }
    }
    let requestArrived = (0..<4).map { _ in Signal() }
    let releaseResponse = (0..<4).map { _ in Signal() }

    init(log: CallLog) { self.log = log }

    func execute(_ req: URLRequest, enableTokenRefresh: Bool, accountId: String?) async -> NYPLResult<Data> {
        let authorization = req.value(forHTTPHeaderField: "Authorization")
        let bearer = authorization.flatMap { $0.hasPrefix("Bearer ") ? String($0.dropFirst(7)) : nil }
        log.record("validationRequest", args: [
            "path": req.url?.path ?? "nil",
            "hasBearer": bearer != nil,
            "bearer": bearer ?? "nil",
            "accountId": accountId ?? "nil",
            "enableTokenRefresh": enableTokenRefresh,
        ])
        let (index, hold) = lock.withLock { () -> (Int, Bool) in
            defer { requestCount += 1 }
            return (requestCount, _holdResponses)
        }
        if index < requestArrived.count { requestArrived[index].fire() }
        if hold, index < releaseResponse.count { await releaseResponse[index].wait() }

        let url = req.url ?? URL(string: "https://example.com")!
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "1.1", headerFields: nil)
        return .success(Data(TPPFake.validUserProfileJson.utf8), response)
    }
}

/// Token exchange that replies on a background queue, as `TPPNetworkExecutor`
/// does. With `reply == nil` the reply is held until `deliverHeldReply`.
private final class TokenExchangeSpy: SignInAppNetworking, @unchecked Sendable {
    private struct Delivery: @unchecked Sendable {
        let completion: (Result<TokenResponse, Error>) -> Void
        let result: Result<TokenResponse, Error>
    }

    private let log: CallLog
    private let lock = NSLock()
    private var _reply: Result<TokenResponse, Error>?
    private var held: ((Result<TokenResponse, Error>) -> Void)?
    var reply: Result<TokenResponse, Error>? {
        get { lock.withLock { _reply } }
        set { lock.withLock { _reply = newValue } }
    }

    init(log: CallLog) { self.log = log }

    func executeTokenRefresh(username: String,
                             password: String,
                             tokenURL: URL,
                             accountId: String?,
                             completion: @escaping (Result<TokenResponse, Error>) -> Void) {
        log.record("executeTokenRefresh", args: ["username": username,
                                                 "tokenURL": tokenURL.absoluteString,
                                                 "accountId": accountId ?? "nil"])
        if let reply {
            deliver(Delivery(completion: completion, result: reply))
        } else {
            lock.withLock { held = completion }
        }
    }

    func deliverHeldReply(_ result: Result<TokenResponse, Error>) {
        guard let completion = lock.withLock({ held }) else { return }
        deliver(Delivery(completion: completion, result: result))
    }

    private func deliver(_ delivery: Delivery) {
        DispatchQueue.global().async { delivery.completion(delivery.result) }
    }

    func clearCache() {}
}

private final class RegistrySyncSpy: TPPBookRegistrySyncing {
    private let log: CallLog
    init(log: CallLog) { self.log = log }
    var isSyncing: Bool { false }
    func reset(_ libraryAccountUUID: String) { log.record("registry.reset") }
    func sync() { log.record("registry.sync") }
    func reportSyncEnded() { log.record("registry.reportSyncEnded") }
}

private final class ProgressRecordingLibraryAccountMock: TPPLibraryAccountMock, @unchecked Sendable {
    private let log: CallLog

    init(log: CallLog) {
        self.log = log
        super.init()
    }

    override func reportSignInProgress(_ progress: SignInProgress) {
        log.record("reportSignInProgress", args: ["progress": progress == .started ? "started" : "finished"])
        super.reportSignInProgress(progress)
    }
}
