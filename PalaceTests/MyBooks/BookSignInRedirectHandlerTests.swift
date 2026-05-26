//
//  BookSignInRedirectHandlerTests.swift
//  PalaceTests
//
//  Coverage for the SAML/cookie auth-redirect state machine in
//  BookSignInRedirectHandler.
//
//  handleProblem branches covered:
//    - .SAMLStarted circuit breaker (sign-in modal without sign-out)
//    - SAML cookies expired (state .SAMLStarted + retry startDownload)
//    - No-credentials sign-in (reauth + retry on hasCredentials)
//
//  Plus cancellation, book-found, and cookie-storage sync.
//
//  handleSAMLStartedState's UIKit web-view presentation is NOT
//  covered here — it's a side-effect with no observable test surface
//  short of integration testing.
//

import XCTest
import PalaceCatalog
@testable import Palace

@MainActor
final class BookSignInRedirectHandlerTests: XCTestCase {

    private var registry: TPPBookRegistryMock!
    private var stateManager: DownloadStateManager!
    private var reauthenticator: TPPReauthenticatorMock!
    private var userAccount: TPPUserAccountMock!
    private var credentialState: CredentialRequestState!
    private var spyDelegate: SpyDelegate!
    private var handler: BookSignInRedirectHandler!
    private var book: TPPBook!

    override func setUpWithError() throws {
        try super.setUpWithError()
        registry = TPPBookRegistryMock()
        stateManager = DownloadStateManager()
        reauthenticator = TPPReauthenticatorMock()
        userAccount = TPPUserAccountMock()
        credentialState = CredentialRequestState()
        spyDelegate = SpyDelegate()

        handler = BookSignInRedirectHandler(
            bookRegistry: registry,
            stateManager: stateManager,
            reauthenticator: reauthenticator,
            userAccountProvider: { [unowned self] in self.userAccount },
            credentialRequestState: credentialState
        )
        handler.delegate = spyDelegate

        book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        registry.addBook(book, location: nil, state: .downloading,
                         fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)
    }

    override func tearDownWithError() throws {
        registry = nil
        stateManager = nil
        reauthenticator = nil
        userAccount = nil
        credentialState = nil
        spyDelegate = nil
        handler = nil
        book = nil
        try super.tearDownWithError()
    }

    private func makeAuth(typeRaw: String) -> AccountDetails.Authentication {
        let json = #"{"type": "\#(typeRaw)"}"#
        let docAuth = try! JSONDecoder().decode(
            OPDS2AuthenticationDocument.Authentication.self,
            from: Data(json.utf8)
        )
        return AccountDetails.Authentication(auth: docAuth)
    }

    private func makeProblemDoc(type: String? = nil, detail: String? = nil) throws -> TPPProblemDocument {
        var dict: [String: Any] = [:]
        if let type { dict["type"] = type }
        if let detail { dict["detail"] = detail }
        if dict.isEmpty { dict["title"] = "x" }
        let data = try JSONSerialization.data(withJSONObject: dict)
        return try XCTUnwrap(TPPProblemDocument.fromProblemResponseData(data))
    }

    private func waitForAsync(timeout: TimeInterval = 1.0, _ predicate: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
            await Task.yield()
        }
    }

    // MARK: - handleLoginCancellation

    func testHandleLoginCancellation_setsDownloadNeededAndCancelsViaDelegate() {
        handler.handleLoginCancellation(for: book)

        XCTAssertEqual(registry.state(for: book.identifier), .downloadNeeded)
        XCTAssertEqual(spyDelegate.cancelDownloadCalls, [book.identifier])
    }

    // MARK: - handleBookFound

    func testHandleBookFound_setsCookiesAndRetriesDownloadIfRequestPresent() {
        let cookie = HTTPCookie(properties: [
            .name: "k", .value: "v", .domain: "example.com", .path: "/"
        ])!
        let request = URLRequest(url: URL(string: "https://example.com/book")!)

        handler.handleBookFound(for: book, withRequest: request, cookies: [cookie])

        XCTAssertEqual(spyDelegate.startDownloadCalls.map { $0.identifier }, [book.identifier])
    }

    func testHandleBookFound_nilRequest_skipsRetry() {
        let cookie = HTTPCookie(properties: [
            .name: "k", .value: "v", .domain: "example.com", .path: "/"
        ])!
        handler.handleBookFound(for: book, withRequest: nil, cookies: [cookie])

        XCTAssertTrue(spyDelegate.startDownloadCalls.isEmpty)
    }

    // MARK: - handleProblem branch 1: .SAMLStarted circuit breaker

    func testHandleProblem_alreadySAMLStarted_setsFailedAndPresentsReauthModal() async {
        userAccount._authDefinition = makeAuth(typeRaw: "http://librarysimplified.org/authtype/SAML-2.0")
        userAccount._credentials = .barcodeAndPin(barcode: "b", pin: "p")
        registry.setState(.SAMLStarted, for: book.identifier)

        // After re-auth completes, switch the mock to .loggedIn so retry fires
        reauthenticator.onAuthenticate = { [weak self] _, _ in
            self?.userAccount.markLoggedIn()
        }

        handler.handleProblem(for: book, problemDocument: nil)
        await waitForAsync { [self] in self.reauthenticator.authenticateIfNeededCalled }

        XCTAssertEqual(registry.state(for: book.identifier), .downloadFailed,
                       "Circuit breaker flips state to .downloadFailed before sign-in modal")
        XCTAssertTrue(reauthenticator.authenticateIfNeededCalled,
                      "Circuit breaker presents the reauthenticate modal")
    }

    // MARK: - handleProblem branch 2: SAML cookies expired

    func testHandleProblem_samlCookiesExpired_setsSAMLStartedAndRetries() async {
        userAccount._authDefinition = makeAuth(typeRaw: "http://librarysimplified.org/authtype/SAML-2.0")
        userAccount._credentials = .barcodeAndPin(barcode: "b", pin: "p")
        // State is currently .downloading (from setUp) — NOT .SAMLStarted

        handler.handleProblem(for: book, problemDocument: nil)
        await waitForAsync { [self] in
            self.spyDelegate.startDownloadCalls.count > 0
        }

        XCTAssertEqual(registry.state(for: book.identifier), .SAMLStarted,
                       "SAML cookies-expired path flips state to .SAMLStarted before retry")
        XCTAssertEqual(spyDelegate.startDownloadCalls.map { $0.identifier }, [book.identifier])
        XCTAssertFalse(reauthenticator.authenticateIfNeededCalled,
                       "SAML cookies-expired bypasses reauthenticate; the SAML web-view drives the retry")
    }

    // MARK: - handleProblem branch 3: no credentials → sign-in modal

    func testHandleProblem_noCredentialsLoginRequired_presentsReauthAndRetriesOnHasCredentials() async {
        userAccount._authDefinition = makeAuth(typeRaw: "http://opds-spec.org/auth/basic")
        userAccount._credentials = nil
        XCTAssertFalse(userAccount.hasCredentials())
        XCTAssertTrue(userAccount.authDefinition?.needsAuth ?? false)

        reauthenticator.onAuthenticate = { [weak self] _, _ in
            self?.userAccount._credentials = .barcodeAndPin(barcode: "b", pin: "p")
        }

        handler.handleProblem(for: book, problemDocument: nil)
        await waitForAsync { [self] in self.spyDelegate.startDownloadCalls.count > 0 }

        XCTAssertEqual(registry.state(for: book.identifier), .downloadNeeded,
                       "No-credentials path flips state to .downloadNeeded before sign-in modal")
        XCTAssertTrue(reauthenticator.authenticateIfNeededCalled)
        XCTAssertEqual(spyDelegate.startDownloadCalls.map { $0.identifier }, [book.identifier])
    }

    func testHandleProblem_hasCredentialsAndNotSaml_logsButDoesNotAuthenticate() async {
        userAccount._authDefinition = makeAuth(typeRaw: "http://opds-spec.org/auth/basic")
        userAccount._credentials = .barcodeAndPin(barcode: "b", pin: "p")

        handler.handleProblem(for: book, problemDocument: nil)

        // Allow Task hops a chance to run.
        for _ in 0..<3 {
            try? await Task.sleep(nanoseconds: 20_000_000)
            await Task.yield()
        }

        XCTAssertEqual(registry.state(for: book.identifier), .downloadNeeded,
                       "Has-credentials non-SAML path still flips state to .downloadNeeded")
        XCTAssertFalse(reauthenticator.authenticateIfNeededCalled,
                       "Has-credentials path skips reauth — just logs for debugging")
        XCTAssertTrue(spyDelegate.startDownloadCalls.isEmpty)
    }

    // MARK: - clearAndSetCookies

    func testClearAndSetCookies_replacesSessionCookiesWithUserAccountCookies() {
        // Seed the fake storage with a "stale" cookie
        let stale = HTTPCookie(properties: [
            .name: "stale", .value: "v", .domain: "example.com", .path: "/"
        ])!
        spyDelegate.fakeCookieStorage.setCookie(stale)
        XCTAssertEqual(spyDelegate.fakeCookieStorage.cookies?.count, 1)

        // userAccount has its own cookie set
        let fresh = HTTPCookie(properties: [
            .name: "fresh", .value: "v", .domain: "example.com", .path: "/"
        ])!
        userAccount.setCookies([fresh])

        handler.clearAndSetCookies()

        let result = spyDelegate.fakeCookieStorage.cookies ?? []
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.name, "fresh",
                       "clearAndSetCookies replaces the session's cookies with the user account's cookies")
    }
}

// MARK: - Spy

private final class SpyDelegate: BookSignInRedirectHandlerDelegate {
    let fakeCookieStorage = HTTPCookieStorage.shared
    var cookieStorage: HTTPCookieStorage? { fakeCookieStorage }

    private(set) var cancelDownloadCalls: [String] = []
    private(set) var startDownloadCalls: [(book: TPPBook, identifier: String)] = []

    init() {
        // Wipe the shared storage before each test so prior tests don't
        // leak cookies. NSHTTPCookieStorage.shared is a singleton; the
        // test relies on this clear at init time.
        fakeCookieStorage.cookies?.forEach { fakeCookieStorage.deleteCookie($0) }
    }

    func cancelDownload(for identifier: String) {
        cancelDownloadCalls.append(identifier)
    }

    func startDownload(for book: TPPBook, withRequest request: URLRequest?) {
        startDownloadCalls.append((book, book.identifier))
    }
}
