//
//  DownloadAuthRetryHandlerAuthCoordinatorTests.swift
//  PalaceTests
//
//  swarm_66819d80 Module C — caller-migration assertions for
//  `DownloadAuthRetryHandler` when wired with an `AuthCoordinator`.
//
//  When the coordinator is injected, the two IdP-dispatch branches
//  inside `handleAuthFailureIfApplicable` (browser-session-expired and
//  no-active-loan-as-session-expiry) must route through
//  `coordinator.refreshCredentialsIfNeeded(reason:)` instead of carrying
//  per-call-site SAML vs OIDC branching. The per-book download state
//  transition (`.SAMLStarted` for SAML; `.downloadNeeded` for others)
//  and the post-success `startDownload` retry stay at this call site.
//

import XCTest
import PalaceCatalog
@testable import Palace
@testable import PalaceAuth

@MainActor
final class DownloadAuthRetryHandlerAuthCoordinatorTests: XCTestCase {

    private var registry: TPPBookRegistryMock!
    private var stateManager: DownloadStateManager!
    private var reauthenticator: TPPReauthenticatorMock!
    private var alertPresenter: DownloadAlertPresenter!
    private var progressReporter: DownloadProgressReporter!
    private var spyDelegate: SpyDelegate!
    private var userAccount: TPPUserAccountMock!
    private var handler: DownloadAuthRetryHandler!
    private var book: TPPBook!

    // Coordinator spies — created in each test via SpyAuthCoordinatorFactory.

    override func setUpWithError() throws {
        try super.setUpWithError()
        registry = TPPBookRegistryMock()
        stateManager = DownloadStateManager()
        reauthenticator = TPPReauthenticatorMock()
        userAccount = TPPUserAccountMock()
        spyDelegate = SpyDelegate()

        progressReporter = DownloadProgressReporter(
            accessibilityAnnouncements: TPPAccessibilityAnnouncementCenter(),
            downloadAnnouncementService: DownloadAnnouncementService()
        )
        alertPresenter = DownloadAlertPresenter(
            bookRegistry: registry,
            stateManager: stateManager,
            progressReporter: progressReporter,
            downloadAnnouncementService: DownloadAnnouncementService()
        )

        book = TPPBookMocker.mockBook(distributorType: .EpubZip)
    }

    override func tearDownWithError() throws {
        registry = nil
        stateManager = nil
        reauthenticator = nil
        userAccount = nil
        spyDelegate = nil
        alertPresenter = nil
        progressReporter = nil
        handler = nil
        book = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func makeAuth(typeRaw: String) -> AccountDetails.Authentication {
        let json = #"{"type": "\#(typeRaw)"}"#
        // swiftlint:disable:next force_try
        let docAuth = try! JSONDecoder().decode(
            OPDS2AuthenticationDocument.Authentication.self,
            from: Data(json.utf8)
        )
        return AccountDetails.Authentication(auth: docAuth)
    }

    private func makeProblemDoc(type: String? = nil) throws -> TPPProblemDocument {
        var dict: [String: Any] = [:]
        if let type { dict["type"] = type }
        if dict.isEmpty { dict["title"] = "x" }
        let data = try JSONSerialization.data(withJSONObject: dict)
        return try XCTUnwrap(TPPProblemDocument.fromProblemResponseData(data))
    }

    /// Fake task that lets tests inject an HTTPURLResponse + originalRequest.
    private final class FakeURLSessionDownloadTask: URLSessionDownloadTask {
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

    private func waitForAsyncCleanup() async {
        for _ in 0..<8 {
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
            await Task.yield()
        }
    }

    // MARK: - Coordinator-routed: SAML browser session expired (401)

    /// SAML 401 with the coordinator wired must route through the
    /// coordinator (presenting the modal for the SAML mechanism) AND
    /// flip per-book state to `.SAMLStarted` AND start the retry
    /// download on `.success`. The legacy `reauthenticator.authenticateIfNeeded`
    /// path must NOT fire — that branch was the old per-call-site dispatch.
    func testCoordinator_401_SAML_routesToCoordinator_setsSAMLStarted_andRetriesOnSuccess() async throws {
        let (coordinator, reauth, modal, userAcctSpy, _) = SpyAuthCoordinatorFactory.make(
            mechanism: .saml,
            stubModalResult: true   // modal succeeds → coordinator returns .success
        )

        handler = DownloadAuthRetryHandler(
            stateManager: stateManager,
            bookRegistry: registry,
            reauthenticator: reauthenticator,
            alertPresenter: alertPresenter,
            userAccountProvider: { [unowned self] in self.userAccount },
            authCoordinator: coordinator
        )
        handler.delegate = spyDelegate

        userAccount._authDefinition = makeAuth(typeRaw: "http://librarysimplified.org/authtype/SAML-2.0")
        userAccount._credentials = .barcodeAndPin(barcode: "b", pin: "p")
        registry.addBook(book, location: nil, state: .downloading,
                         fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)

        let task = makeFakeTask(statusCode: 401)
        let handled = handler.handleAuthFailureIfApplicable(book: book, task: task, problemDoc: nil, failureError: nil)
        XCTAssertTrue(handled, "401 + browser SAML must claim the failure")

        await waitForAsyncCleanup()

        XCTAssertEqual(modal.presentCallCount, 1,
                       "SAML routes through coordinator → modal (always) per AuthCoordinator route table")
        XCTAssertEqual(userAcctSpy.markCredentialsStaleCallCount, 1,
                       "Coordinator owns markCredentialsStale — fires once on the SAML path")
        XCTAssertEqual(reauth.callCount, 0,
                       "Coordinator's silent reauthenticator must NOT fire for SAML mechanism (always modal)")
        XCTAssertFalse(reauthenticator.authenticateIfNeededCalled,
                       "Legacy reauthenticator path is bypassed when coordinator is wired")
        XCTAssertEqual(registry.state(for: book.identifier), .SAMLStarted,
                       "Per-book SAML state transition stays at this call site even when coordinator owns dispatch")
        XCTAssertEqual(spyDelegate.startDownloadCalls.map { $0.identifier }, [book.identifier],
                       "Coordinator success → startDownload retry")
    }

    // MARK: - Coordinator-routed: non-SAML browser session expired (401 OIDC)

    /// OIDC 401 with the coordinator wired must route through the
    /// coordinator AND flip per-book state to `.downloadNeeded` AND
    /// retry the download on `.success`. No SAML state transition.
    func testCoordinator_401_OIDC_routesToCoordinator_setsDownloadNeeded_andRetriesOnSuccess() async throws {
        let (coordinator, _, modal, _, _) = SpyAuthCoordinatorFactory.make(
            mechanism: .oidc,
            stubModalResult: true
        )

        handler = DownloadAuthRetryHandler(
            stateManager: stateManager,
            bookRegistry: registry,
            reauthenticator: reauthenticator,
            alertPresenter: alertPresenter,
            userAccountProvider: { [unowned self] in self.userAccount },
            authCoordinator: coordinator
        )
        handler.delegate = spyDelegate

        userAccount._authDefinition = makeAuth(typeRaw: "http://palaceproject.io/authtype/OpenIDConnect")
        userAccount._credentials = .barcodeAndPin(barcode: "b", pin: "p")
        registry.addBook(book, location: nil, state: .downloading,
                         fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)

        let task = makeFakeTask(statusCode: 401)
        let handled = handler.handleAuthFailureIfApplicable(book: book, task: task, problemDoc: nil, failureError: nil)
        XCTAssertTrue(handled)

        await waitForAsyncCleanup()

        XCTAssertEqual(modal.presentCallCount, 1,
                       "OIDC routes through coordinator → modal (OIDC always modal per route table)")
        XCTAssertEqual(registry.state(for: book.identifier), .downloadNeeded,
                       "Per-book non-SAML browser path lands in .downloadNeeded — preserved at call site")
        XCTAssertEqual(spyDelegate.startDownloadCalls.count, 1,
                       "Coordinator success → startDownload retry")
        XCTAssertFalse(reauthenticator.authenticateIfNeededCalled,
                       "Legacy reauthenticator path bypassed when coordinator is wired")
    }

    // MARK: - Coordinator-routed: user cancels modal

    /// When the user cancels the modal the coordinator returns
    /// `.failure(.userCancelled)`. The per-book state must STILL flip
    /// (`.SAMLStarted` / `.downloadNeeded`) so the next interaction
    /// sees a clean slate, but the retry `startDownload` must NOT fire.
    func testCoordinator_401_SAML_userCancel_doesNotRetryButFlipsPerBookState() async throws {
        let (coordinator, _, modal, _, _) = SpyAuthCoordinatorFactory.make(
            mechanism: .saml,
            stubModalResult: false  // user cancelled
        )

        handler = DownloadAuthRetryHandler(
            stateManager: stateManager,
            bookRegistry: registry,
            reauthenticator: reauthenticator,
            alertPresenter: alertPresenter,
            userAccountProvider: { [unowned self] in self.userAccount },
            authCoordinator: coordinator
        )
        handler.delegate = spyDelegate

        userAccount._authDefinition = makeAuth(typeRaw: "http://librarysimplified.org/authtype/SAML-2.0")
        userAccount._credentials = .barcodeAndPin(barcode: "b", pin: "p")
        registry.addBook(book, location: nil, state: .downloading,
                         fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)

        let task = makeFakeTask(statusCode: 401)
        _ = handler.handleAuthFailureIfApplicable(book: book, task: task, problemDoc: nil, failureError: nil)
        await waitForAsyncCleanup()

        XCTAssertEqual(modal.presentCallCount, 1)
        XCTAssertEqual(registry.state(for: book.identifier), .SAMLStarted,
                       "SAML per-book state must still flip after cancellation — otherwise the next attempt has stale state")
        XCTAssertTrue(spyDelegate.startDownloadCalls.isEmpty,
                      "Retry MUST NOT fire on coordinator cancellation")
    }

    // MARK: - Coordinator-routed: no-active-loan as session expiry

    /// PP-3716 path: `no-active-loan` problem doc with browser auth +
    /// credentials. Must route through coordinator the same way as the
    /// 401 case. SAML lands in `.SAMLStarted`; other browser flavors
    /// land in `.downloadNeeded`.
    func testCoordinator_noActiveLoan_SAML_routesToCoordinator_setsSAMLStarted() async throws {
        let (coordinator, _, modal, _, _) = SpyAuthCoordinatorFactory.make(
            mechanism: .saml,
            stubModalResult: true
        )

        handler = DownloadAuthRetryHandler(
            stateManager: stateManager,
            bookRegistry: registry,
            reauthenticator: reauthenticator,
            alertPresenter: alertPresenter,
            userAccountProvider: { [unowned self] in self.userAccount },
            authCoordinator: coordinator
        )
        handler.delegate = spyDelegate

        userAccount._authDefinition = makeAuth(typeRaw: "http://librarysimplified.org/authtype/SAML-2.0")
        userAccount._credentials = .barcodeAndPin(barcode: "b", pin: "p")
        registry.addBook(book, location: nil, state: .downloading,
                         fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)

        let problemDoc = try makeProblemDoc(type: TPPProblemDocument.TypeNoActiveLoan)
        // Use a 200 status so the 401-detection branch is bypassed — the
        // no-active-loan PP-3716 branch fires off the problem-doc type alone.
        let task = makeFakeTask(statusCode: 200)
        let handled = handler.handleAuthFailureIfApplicable(book: book, task: task, problemDoc: problemDoc, failureError: nil)
        XCTAssertTrue(handled)

        await waitForAsyncCleanup()

        XCTAssertEqual(modal.presentCallCount, 1,
                       "no-active-loan SAML path routes through coordinator → modal")
        XCTAssertEqual(registry.state(for: book.identifier), .SAMLStarted,
                       "no-active-loan SAML path mirrors 401-SAML per-book state transition")
        XCTAssertEqual(spyDelegate.startDownloadCalls.count, 1,
                       "Coordinator success on PP-3716 path → startDownload retry")
    }

    // MARK: - Foreign-host guard (PR #1018 cross-host regression fix)

    /// Air-tight test for the foreign-host short-circuit. With a current-
    /// account auth surface of `{minotaur.dev.palaceproject.io}` and a
    /// 401 download failure from `gorgon.staging.palaceproject.io/...`,
    /// the handler MUST:
    ///   - Return false (failure not claimed by this layer)
    ///   - NOT mark the current account's credentials stale
    ///   - NOT dispatch the coordinator
    ///   - NOT trigger startDownload retry
    ///
    /// SAML scenario chosen because SAML always routes to modal — most
    /// fragile path per the dispatch matrix. Without the foreign-host
    /// guard, a download retry for a book whose library is no longer
    /// active would mark stale + pop the modal for the current account.
    ///
    /// Wall-failure 2026-06-05-pr1018-icarus-cross-host-logout.md.
    func testForeignHost_401_SAML_doesNotMarkCredentialsStale_doesNotDispatchCoordinator() async throws {
        let (coordinator, _, modal, userAcctSpy, _) = SpyAuthCoordinatorFactory.make(
            mechanism: .saml,
            stubModalResult: true
        )

        handler = DownloadAuthRetryHandler(
            stateManager: stateManager,
            bookRegistry: registry,
            reauthenticator: reauthenticator,
            alertPresenter: alertPresenter,
            userAccountProvider: { [unowned self] in self.userAccount },
            authCoordinator: coordinator,
            currentAccountHostsProvider: { Set(["minotaur.dev.palaceproject.io"]) }
        )
        handler.delegate = spyDelegate

        userAccount._authDefinition = makeAuth(typeRaw: "http://librarysimplified.org/authtype/SAML-2.0")
        userAccount._credentials = .barcodeAndPin(barcode: "b", pin: "p")
        registry.addBook(book, location: nil, state: .downloading,
                         fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)

        // 401 from a host OUTSIDE the current account's auth surface
        let foreignURL = URL(string: "https://gorgon.staging.palaceproject.io/a1qa-test/fulfillment/abc")!
        let task = makeFakeTask(statusCode: 401, url: foreignURL)
        let handled = handler.handleAuthFailureIfApplicable(book: book, task: task, problemDoc: nil, failureError: nil)
        XCTAssertFalse(handled,
                       "Foreign-host 401 must NOT be claimed by the handler — falls through to the caller's normal failure path. Regression: returning true would mean the handler still 'handled' the foreign 401 via the modal path.")

        await waitForAsyncCleanup()

        XCTAssertEqual(modal.presentCallCount, 0,
                       "Foreign-host 401 MUST NOT dispatch the coordinator — the whole point of the guard is to skip the modal for the current account when the 401 belongs to a DIFFERENT account's session.")
        XCTAssertEqual(userAcctSpy.markCredentialsStaleCallCount, 0,
                       "Foreign-host 401 MUST NOT mark the current account's credentials stale.")
        XCTAssertEqual(spyDelegate.startDownloadCalls.count, 0,
                       "No retry: foreign-host 401 is not the current account's session. Regression here would mean we retried a download for a book that's no longer ours.")
        XCTAssertNotEqual(registry.state(for: book.identifier), .SAMLStarted,
                          "Per-book state must NOT flip to .SAMLStarted on a foreign-host 401 — that would force the user into a SAML reauth flow they don't need.")
    }

    /// Belt-and-braces: nil provider preserves legacy dispatch. Without
    /// this test, a refactor that flipped the default from `nil` to
    /// `{ Set<String>() }` would silently change behavior.
    func testForeignHost_401_SAML_withNilProvider_fallsBackToLegacyDispatch() async throws {
        let (coordinator, _, modal, _, _) = SpyAuthCoordinatorFactory.make(
            mechanism: .saml,
            stubModalResult: true
        )

        // currentAccountHostsProvider intentionally OMITTED (defaults to nil)
        handler = DownloadAuthRetryHandler(
            stateManager: stateManager,
            bookRegistry: registry,
            reauthenticator: reauthenticator,
            alertPresenter: alertPresenter,
            userAccountProvider: { [unowned self] in self.userAccount },
            authCoordinator: coordinator
        )
        handler.delegate = spyDelegate

        userAccount._authDefinition = makeAuth(typeRaw: "http://librarysimplified.org/authtype/SAML-2.0")
        userAccount._credentials = .barcodeAndPin(barcode: "b", pin: "p")
        registry.addBook(book, location: nil, state: .downloading,
                         fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)

        // Same foreign URL — but provider is nil so legacy dispatch fires
        let foreignURL = URL(string: "https://gorgon.staging.palaceproject.io/a1qa-test/fulfillment/abc")!
        let task = makeFakeTask(statusCode: 401, url: foreignURL)
        _ = handler.handleAuthFailureIfApplicable(book: book, task: task, problemDoc: nil, failureError: nil)

        await waitForAsyncCleanup()

        XCTAssertEqual(modal.presentCallCount, 1,
                       "Nil provider preserves legacy behavior — SAML 401 still dispatches the coordinator → modal. A regression where nil is treated as empty-set would silently disable the legacy dispatch.")
    }
}

// MARK: - File-private spy delegate
@MainActor
private final class SpyDelegate: DownloadAuthRetryHandlerDelegate {
    private(set) var startDownloadCalls: [(book: TPPBook, identifier: String)] = []
    private(set) var startBorrowCalls: [(book: TPPBook, attemptDownload: Bool)] = []

    nonisolated func startDownload(for book: TPPBook, withRequest request: URLRequest?) {
        Task { @MainActor in
            self.startDownloadCalls.append((book, book.identifier))
        }
    }

    nonisolated func startBorrow(for book: TPPBook, attemptDownload: Bool, borrowCompletion: (() -> Void)?) {
        Task { @MainActor in
            self.startBorrowCalls.append((book, attemptDownload))
        }
    }
}
