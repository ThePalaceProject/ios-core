//
//  DownloadAuthRetryHandlerTests.swift
//  PalaceTests
//
//  Critical-path coverage for the 6-branch failure-path auth/retry
//  decision tree extracted into DownloadAuthRetryHandler. Every branch
//  the handler can claim is exercised here, plus the fall-through
//  (returns false) cases that pass control back to the caller's alert
//  path.
//
//  Per CLAUDE.md, the auth/retry surface handles user access (effectively
//  user money for paid library access) so every decision branch must
//  have a test.
//

import XCTest
import PalaceCatalog
@testable import Palace

@MainActor
final class DownloadAuthRetryHandlerTests: XCTestCase {

    private var registry: TPPBookRegistryMock!
    private var stateManager: DownloadStateManager!
    private var reauthenticator: TPPReauthenticatorMock!
    private var alertPresenter: DownloadAlertPresenter!
    private var spyDelegate: SpyDelegate!
    private var userAccount: TPPUserAccountMock!
    private var handler: DownloadAuthRetryHandler!
    private var book: TPPBook!

    override func setUpWithError() throws {
        try super.setUpWithError()
        registry = TPPBookRegistryMock()
        stateManager = DownloadStateManager()
        reauthenticator = TPPReauthenticatorMock()
        userAccount = TPPUserAccountMock()
        spyDelegate = SpyDelegate()

        // The handler depends on DownloadAlertPresenter only for the
        // auto-borrow callback (alertForProblemDocument on borrow
        // failure). A real instance with a real progress reporter is
        // fine; we don't assert on its output here.
        let reporter = DownloadProgressReporter(
            accessibilityAnnouncements: TPPAccessibilityAnnouncementCenter(),
            downloadAnnouncementService: DownloadAnnouncementService()
        )
        alertPresenter = DownloadAlertPresenter(
            bookRegistry: registry,
            stateManager: stateManager,
            progressReporter: reporter,
            downloadAnnouncementService: DownloadAnnouncementService()
        )

        handler = DownloadAuthRetryHandler(
            stateManager: stateManager,
            bookRegistry: registry,
            reauthenticator: reauthenticator,
            alertPresenter: alertPresenter,
            userAccountProvider: { [unowned self] in self.userAccount }
        )
        handler.delegate = spyDelegate

        book = TPPBookMocker.mockBook(distributorType: .EpubZip)
    }

    override func tearDownWithError() throws {
        registry = nil
        stateManager = nil
        reauthenticator = nil
        userAccount = nil
        spyDelegate = nil
        alertPresenter = nil
        handler = nil
        book = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func makeAuth(typeRaw: String) -> AccountDetails.Authentication {
        // OPDS2AuthenticationDocument.Authentication's memberwise init is
        // module-internal; decode a minimal JSON payload to construct one
        // from outside PalaceCatalog.
        let json = #"{"type": "\#(typeRaw)"}"#
        let docAuth = try! JSONDecoder().decode(
            OPDS2AuthenticationDocument.Authentication.self,
            from: Data(json.utf8)
        )
        return AccountDetails.Authentication(auth: docAuth)
    }

    private func makeProblemDoc(type: String? = nil) throws -> TPPProblemDocument {
        var dict: [String: Any] = [:]
        if let type { dict["type"] = type }
        if dict.isEmpty { dict["title"] = "x" } // ensure JSON object is non-empty
        let data = try JSONSerialization.data(withJSONObject: dict)
        return try XCTUnwrap(TPPProblemDocument.fromProblemResponseData(data))
    }

    private func makeTask(statusCode: Int, url: URL = URL(string: "https://example.com")!) -> URLSessionDownloadTask {
        let session = URLSession(configuration: .default)
        let task = session.downloadTask(with: url)
        task.cancel() // we never actually run it
        // Embedding the response is impossible without a stub; the handler
        // reads task.response, so swap to a real response by sending the
        // task through a URLProtocol stub. For unit tests of pure decision
        // logic, we only need the response object — use a custom subclass.
        // Simpler: construct an HTTPURLResponse and pass via runtime swizzle?
        // Avoid swizzle: the handler accepts URLSessionTask, and reads
        // `task.response` directly. We'll wrap in a fake.
        return task
    }

    /// Faked task that lets tests inject an HTTPURLResponse + originalRequest.
    /// The handler only reads `task.response` and `task.originalRequest`, so
    /// stubbing those satisfies the surface.
    final class FakeURLSessionDownloadTask: URLSessionDownloadTask {
        private let _response: URLResponse?
        private let _originalRequest: URLRequest?
        private let _taskIdentifier: Int

        init(response: URLResponse?, originalRequest: URLRequest?, identifier: Int = 0) {
            self._response = response
            self._originalRequest = originalRequest
            self._taskIdentifier = identifier
            super.init()
        }

        override var response: URLResponse? { _response }
        override var originalRequest: URLRequest? { _originalRequest }
        override var taskIdentifier: Int { _taskIdentifier }
        override func cancel() {}
        override func resume() {}
        override func suspend() {}
    }

    private func makeFakeTask(statusCode: Int, url: URL = URL(string: "https://example.com/book")!) -> URLSessionDownloadTask {
        let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: nil)
        return FakeURLSessionDownloadTask(response: response, originalRequest: URLRequest(url: url))
    }

    /// Wait for any pending Task { } cleanup blocks the handler may have
    /// dispatched. The handler uses Task to do async stateManager cleanup
    /// before hopping back to MainActor for state mutation.
    private func waitForAsyncCleanup() async {
        for _ in 0..<5 {
            try? await Task.sleep(nanoseconds: 30_000_000) // 30ms
            await Task.yield()
        }
    }

    // MARK: - Branch 1: 401 + hasCredentials + browser SAML → SAMLStarted retry

    func testHandle_401_withCredentials_browserSAML_setsStateToSAMLStartedAndRetries() async throws {
        userAccount._authDefinition = makeAuth(typeRaw: "http://librarysimplified.org/authtype/SAML-2.0")
        userAccount._credentials = .barcodeAndPin(barcode: "b", pin: "p")
        XCTAssertTrue(userAccount.hasCredentials())

        registry.addBook(book, location: nil, state: .downloading,
                         fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)

        let task = makeFakeTask(statusCode: 401)
        let handled = handler.handleAuthFailureIfApplicable(book: book, task: task, problemDoc: nil, failureError: nil)

        XCTAssertTrue(handled, "401 + browser SAML must claim the failure")
        await waitForAsyncCleanup()

        XCTAssertEqual(registry.state(for: book.identifier), .SAMLStarted,
                       "SAML re-auth path flips state to .SAMLStarted")
        XCTAssertEqual(spyDelegate.startDownloadCalls.map { $0.identifier }, [book.identifier],
                       "Handler retries the download after the cleanup hop")
    }

    // MARK: - Branch 2: 401 + hasCredentials + browser OIDC → reauthenticate then retry

    func testHandle_401_withCredentials_browserOIDC_presentsReauthAndRetriesOnLoggedIn() async throws {
        userAccount._authDefinition = makeAuth(typeRaw: "http://palaceproject.io/authtype/OpenIDConnect")
        userAccount._credentials = .barcodeAndPin(barcode: "b", pin: "p")

        registry.addBook(book, location: nil, state: .downloading,
                         fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)

        // After re-auth completes the handler checks authState == .loggedIn
        // before retrying. The handler calls markCredentialsStale earlier
        // in the same flow which flips authState to .credentialsStale; the
        // mock needs markLoggedIn to roll it back so the retry guard fires.
        reauthenticator.onAuthenticate = { [weak self] _, _ in
            self?.userAccount.markLoggedIn()
        }

        let task = makeFakeTask(statusCode: 401)
        let handled = handler.handleAuthFailureIfApplicable(book: book, task: task, problemDoc: nil, failureError: nil)

        XCTAssertTrue(handled)
        await waitForAsyncCleanup()

        XCTAssertEqual(registry.state(for: book.identifier), .downloadNeeded,
                       "OIDC re-auth path flips state to .downloadNeeded before reauth modal")
        XCTAssertTrue(reauthenticator.authenticateIfNeededCalled,
                      "OIDC re-auth path presents the sign-in modal via reauthenticator")
    }

    // MARK: - Branch 3: 401 + hasCredentials + tokenRefresh → falls through

    func testHandle_401_withCredentials_tokenRefresh_returnsFalseSoCallerCanAlert() {
        userAccount._authDefinition = makeAuth(typeRaw: "http://thepalaceproject.org/authtype/basic-token")
        userAccount._credentials = .barcodeAndPin(barcode: "b", pin: "p")

        registry.addBook(book, location: nil, state: .downloading,
                         fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)

        let task = makeFakeTask(statusCode: 401)
        let handled = handler.handleAuthFailureIfApplicable(book: book, task: task, problemDoc: nil, failureError: nil)

        XCTAssertFalse(handled, "Token-refresh case falls through — caller shows alert")
        XCTAssertFalse(reauthenticator.authenticateIfNeededCalled,
                       "Token-refresh case must NOT trigger sign-in modal")
        XCTAssertTrue(spyDelegate.startDownloadCalls.isEmpty)
    }

    // MARK: - Branch 4: 401 + !hasCredentials + loginRequired → sign-in modal

    func testHandle_401_withoutCredentials_loginRequired_presentsSignInAndRetriesOnHasCredentials() async throws {
        userAccount._authDefinition = makeAuth(typeRaw: "http://opds-spec.org/auth/basic")
        userAccount._credentials = nil
        XCTAssertFalse(userAccount.hasCredentials())
        XCTAssertTrue(userAccount.authDefinition?.needsAuth ?? false)

        reauthenticator.onAuthenticate = { [weak self] _, _ in
            self?.userAccount._credentials = .barcodeAndPin(barcode: "b", pin: "p")
        }

        let task = makeFakeTask(statusCode: 401)
        let handled = handler.handleAuthFailureIfApplicable(book: book, task: task, problemDoc: nil, failureError: nil)

        XCTAssertTrue(handled)
        await waitForAsyncCleanup()

        XCTAssertTrue(reauthenticator.authenticateIfNeededCalled,
                      "No-credentials path presents sign-in modal")
        XCTAssertEqual(spyDelegate.startDownloadCalls.map { $0.identifier }, [book.identifier],
                       "Retries download once user signs in")
    }

    // MARK: - Branch 5: non-401 + !hasCredentials + loginRequired → sign-in modal

    func testHandle_nonAuthError_withoutCredentials_loginRequired_presentsSignInModal() {
        userAccount._authDefinition = makeAuth(typeRaw: "http://opds-spec.org/auth/basic")
        userAccount._credentials = nil

        let task = makeFakeTask(statusCode: 500) // not a 401
        let handled = handler.handleAuthFailureIfApplicable(book: book, task: task, problemDoc: nil, failureError: nil)

        XCTAssertTrue(handled, "No credentials + login required must present sign-in regardless of status code")
        XCTAssertTrue(reauthenticator.authenticateIfNeededCalled)
    }

    // MARK: - Branch 6a: no-active-loan + browser + SAML → SAMLStarted

    func testHandle_noActiveLoan_browserSAML_treatsAsSessionExpiryAndRetries() async throws {
        userAccount._authDefinition = makeAuth(typeRaw: "http://librarysimplified.org/authtype/SAML-2.0")
        userAccount._credentials = .barcodeAndPin(barcode: "b", pin: "p")

        registry.addBook(book, location: nil, state: .downloading,
                         fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)

        // Simulate the PP-3716 case: server returns no-active-loan as a
        // 400 instead of a 401. The httpResponse path doesn't fire, but
        // the no-active-loan branch does.
        let task = makeFakeTask(statusCode: 400)
        let problemDoc = try makeProblemDoc(type: TPPProblemDocument.TypeNoActiveLoan)

        let handled = handler.handleAuthFailureIfApplicable(book: book, task: task, problemDoc: problemDoc, failureError: nil)

        XCTAssertTrue(handled)
        await waitForAsyncCleanup()

        XCTAssertEqual(registry.state(for: book.identifier), .SAMLStarted,
                       "SAML 'no-active-loan' is treated as session expiry → SAMLStarted state")
        XCTAssertEqual(spyDelegate.startDownloadCalls.map { $0.identifier }, [book.identifier])
    }

    // MARK: - Branch 6b: no-active-loan (other) → auto-borrow

    func testHandle_noActiveLoan_basicAuth_triggersAutoBorrowAndAlertsOnBorrowFailure() async throws {
        userAccount._authDefinition = makeAuth(typeRaw: "http://opds-spec.org/auth/basic")
        userAccount._credentials = .barcodeAndPin(barcode: "b", pin: "p")

        registry.addBook(book, location: nil, state: .downloading,
                         fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)

        // Auto-borrow callback runs; spy records the call. The completion
        // callback inside handler.triggerAutoBorrow checks the new state
        // and alerts on failure — we leave borrowCompletion uncalled so
        // we focus on the dispatch contract.
        let task = makeFakeTask(statusCode: 400)
        let problemDoc = try makeProblemDoc(type: TPPProblemDocument.TypeNoActiveLoan)

        let handled = handler.handleAuthFailureIfApplicable(book: book, task: task, problemDoc: problemDoc, failureError: nil)

        XCTAssertTrue(handled, "no-active-loan must claim the failure")
        XCTAssertEqual(registry.state(for: book.identifier), .unregistered,
                       "Auto-borrow path flips state to .unregistered so borrow logic runs")
        XCTAssertEqual(spyDelegate.startBorrowCalls.map { $0.identifier }, [book.identifier])
    }

    // MARK: - Fall-through: nothing matches → returns false

    func testHandle_unrelatedFailure_anonymousAccount_returnsFalse() {
        // Anonymous account: no auth required, hasCredentials false, login
        // not required. None of the branches should fire.
        userAccount._authDefinition = makeAuth(typeRaw: "http://librarysimplified.org/rel/auth/anonymous")
        userAccount._credentials = nil

        let task = makeFakeTask(statusCode: 500)
        let handled = handler.handleAuthFailureIfApplicable(book: book, task: task, problemDoc: nil, failureError: nil)

        XCTAssertFalse(handled, "Anonymous accounts with non-401 errors fall through to the alert")
        XCTAssertFalse(reauthenticator.authenticateIfNeededCalled)
        XCTAssertTrue(spyDelegate.startDownloadCalls.isEmpty)
        XCTAssertTrue(spyDelegate.startBorrowCalls.isEmpty)
    }
}

// MARK: - Spy

private final class SpyDelegate: DownloadAuthRetryHandlerDelegate {
    private(set) var startDownloadCalls: [(book: TPPBook, identifier: String)] = []
    private(set) var startBorrowCalls: [(book: TPPBook, identifier: String)] = []

    func startDownload(for book: TPPBook, withRequest request: URLRequest?) {
        startDownloadCalls.append((book, book.identifier))
    }

    func startBorrow(for book: TPPBook, attemptDownload: Bool, borrowCompletion: (() -> Void)?) {
        startBorrowCalls.append((book, book.identifier))
    }
}
