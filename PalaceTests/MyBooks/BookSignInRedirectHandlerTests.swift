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

    /// Thin wrapper around the shared `awaitConditionAsync` helper.
    /// `file`/`line` forwarded so timeout XCTFail blames the call site.
    /// Retained only for the SAML-cookies-expired branch, whose retry runs on
    /// a background `Task { }` (actor hops + `MainActor.run`) with no handle to
    /// join — the loud-on-timeout poll is the honest fallback there. All
    /// all-`@MainActor` branches use `flushMainActorTasks()` instead.
    private func waitForAsync(
        timeout: TimeInterval = 10.0,
        file: StaticString = #file,
        line: UInt = #line,
        _ predicate: @escaping () -> Bool
    ) async {
        await awaitConditionAsync(timeout: timeout, file: file, line: line, predicate)
    }

    /// Deterministic join for the branches whose entire flow runs in
    /// `Task { @MainActor }` bodies on THIS actor (SAMLStarted circuit breaker,
    /// no-credentials sign-in, has-credentials no-op). Awaiting barrier
    /// `Task { @MainActor }` values services those earlier-submitted tasks in
    /// order; the reauth mock invokes its completion synchronously, so the
    /// whole entry→reauth-completion→retry chain drains. Completes the instant
    /// the actor is free — never starves on a wall clock. Three hops cover the
    /// deepest chain. Does NOT join the 2s cooldown timer (fire-and-forget).
    @MainActor
    private func flushMainActorTasks() async {
        await Task { @MainActor in }.value
        await Task { @MainActor in }.value
        await Task { @MainActor in }.value
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
        // Circuit-breaker flow is all `Task { @MainActor }` — flush drains it
        // (the entry Task calls authenticateIfNeeded, whose mock fires its
        // completion synchronously) rather than polling a wall-clock deadline.
        await flushMainActorTasks()

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
        // UNJOINABLE without a prod seam: the SAML-cookies-expired branch runs
        // its retry on a background `Task { }` (actor removes + registerCompletion,
        // then `MainActor.run { startDownload }`) with no retained handle to
        // await — a main-actor barrier can't join a background Task's actor
        // work. The shared loud-on-timeout helper converges the instant the
        // retry lands and fails loudly with guidance at the ceiling, replacing
        // the silent-swallow risk; it is NOT a fixed sleep.
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
        // No-credentials flow is all `Task { @MainActor }`: the entry Task calls
        // authenticateIfNeeded, whose mock fires the completion synchronously,
        // enqueuing the `Task { @MainActor }` retry that calls startDownload.
        // Flush drains the whole chain deterministically — no wall-clock poll.
        await flushMainActorTasks()

        XCTAssertEqual(registry.state(for: book.identifier), .downloadNeeded,
                       "No-credentials path flips state to .downloadNeeded before sign-in modal")
        XCTAssertTrue(reauthenticator.authenticateIfNeededCalled)
        XCTAssertEqual(spyDelegate.startDownloadCalls.map { $0.identifier }, [book.identifier])
    }

    func testHandleProblem_hasCredentialsAndNotSaml_logsButDoesNotAuthenticate() async {
        userAccount._authDefinition = makeAuth(typeRaw: "http://opds-spec.org/auth/basic")
        userAccount._credentials = .barcodeAndPin(barcode: "b", pin: "p")

        handler.handleProblem(for: book, problemDocument: nil)

        // Absence assertion (no auth, no retry). The has-credentials non-SAML
        // branch sets `.downloadNeeded` synchronously and spawns NO Task, so
        // there is nothing to wait for — a single main-actor flush is a
        // deterministic barrier for any stray hop rather than a fixed sleep.
        await flushMainActorTasks()

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
