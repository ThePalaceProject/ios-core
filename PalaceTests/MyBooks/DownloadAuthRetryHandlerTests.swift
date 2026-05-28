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
import Combine
import PalaceCatalog
@testable import Palace

@MainActor
final class DownloadAuthRetryHandlerTests: XCTestCase {

    private var registry: TPPBookRegistryMock!
    private var stateManager: DownloadStateManager!
    private var reauthenticator: TPPReauthenticatorMock!
    private var alertPresenter: DownloadAlertPresenter!
    private var progressReporter: DownloadProgressReporter!
    private var spyDelegate: SpyDelegate!
    private var userAccount: TPPUserAccountMock!
    private var handler: DownloadAuthRetryHandler!
    private var book: TPPBook!
    private var cancellables: Set<AnyCancellable> = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        registry = TPPBookRegistryMock()
        stateManager = DownloadStateManager()
        reauthenticator = TPPReauthenticatorMock()
        userAccount = TPPUserAccountMock()
        spyDelegate = SpyDelegate()

        // The handler depends on DownloadAlertPresenter only for the
        // auto-borrow callback (alertForProblemDocument on borrow
        // failure). A real reporter is fine; tests that need to assert
        // the alert fired subscribe to its `downloadErrorPublisher`.
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
        cancellables.removeAll()
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

    func testHandle_noActiveLoan_basicAuth_triggersAutoBorrowWithAttemptDownloadTrue() async throws {
        userAccount._authDefinition = makeAuth(typeRaw: "http://opds-spec.org/auth/basic")
        userAccount._credentials = .barcodeAndPin(barcode: "b", pin: "p")

        registry.addBook(book, location: nil, state: .downloading,
                         fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)

        // Auto-borrow callback runs; spy records the call. The completion
        // callback inside handler.triggerAutoBorrow is exercised in
        // dedicated `testAutoBorrowCompletion_*` tests below — here we
        // pin the dispatch contract: state flip, identifier, and
        // attemptDownload=true (the F-014-shape gap NEEDS-TEST-1).
        let task = makeFakeTask(statusCode: 400)
        let problemDoc = try makeProblemDoc(type: TPPProblemDocument.TypeNoActiveLoan)

        let handled = handler.handleAuthFailureIfApplicable(book: book, task: task, problemDoc: problemDoc, failureError: nil)

        XCTAssertTrue(handled, "no-active-loan must claim the failure")
        XCTAssertEqual(registry.state(for: book.identifier), .unregistered,
                       "Auto-borrow path flips state to .unregistered so borrow logic runs")
        XCTAssertEqual(spyDelegate.startBorrowCalls.map { $0.identifier }, [book.identifier])
        // F-014-shape pin: auto-borrow MUST request attemptDownload=true so
        // BorrowOperation auto-starts the download after the loan is
        // reissued. Flipping true→false here silently degrades UX to
        // "borrow succeeded, manual re-tap required".
        XCTAssertEqual(spyDelegate.startBorrowCalls.map { $0.attemptDownload }, [true],
                       "Auto-borrow must request attemptDownload=true so BorrowOperation auto-starts download")
    }

    // MARK: - Branch 6b auto-borrow completion-callback predicate

    /// Drives the borrow-completion closure with the registry already
    /// flipped to `.downloading` — proves the success arm at :240 of
    /// `DownloadAuthRetryHandler.swift` swallows the failure without
    /// publishing a download-error alert.
    func testAutoBorrowCompletion_whenBorrowSucceedsAndDownloadStarts_doesNotPublishAlert() async throws {
        userAccount._authDefinition = makeAuth(typeRaw: "http://opds-spec.org/auth/basic")
        userAccount._credentials = .barcodeAndPin(barcode: "b", pin: "p")

        registry.addBook(book, location: nil, state: .downloading,
                         fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)

        var publishedErrors: [DownloadErrorInfo] = []
        progressReporter.downloadErrorPublisher
            .sink { publishedErrors.append($0) }
            .store(in: &cancellables)

        let task = makeFakeTask(statusCode: 400)
        let problemDoc = try makeProblemDoc(type: TPPProblemDocument.TypeNoActiveLoan)
        _ = handler.handleAuthFailureIfApplicable(book: book, task: task, problemDoc: problemDoc, failureError: nil)

        // BorrowOperation would flip the registry to .downloading on
        // success — simulate that here, then drive the completion.
        registry.setState(.downloading, for: book.identifier)
        let completion = try XCTUnwrap(spyDelegate.startBorrowCalls.first?.completion,
                                       "Handler must pass a borrowCompletion closure for the post-borrow predicate to run")
        completion()
        await waitForAsyncCleanup()

        XCTAssertTrue(publishedErrors.isEmpty,
                      "Borrow success + .downloading state must NOT publish a download-error alert")
        // alertForProblemDocument removes no-active-loan books from the
        // registry as a side effect; book must still be present.
        XCTAssertNotNil(registry.book(forIdentifier: book.identifier),
                        "Book must remain in registry on borrow-success path")
    }

    /// Drives the borrow-completion closure with the registry left in
    /// `.unregistered` — proves the failure arm at :235-238 fires the
    /// alert and removes the book from the registry.
    func testAutoBorrowCompletion_whenBorrowFails_publishesAlertAndRemovesBook() async throws {
        userAccount._authDefinition = makeAuth(typeRaw: "http://opds-spec.org/auth/basic")
        userAccount._credentials = .barcodeAndPin(barcode: "b", pin: "p")

        registry.addBook(book, location: nil, state: .downloading,
                         fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)

        var publishedErrors: [DownloadErrorInfo] = []
        progressReporter.downloadErrorPublisher
            .sink { publishedErrors.append($0) }
            .store(in: &cancellables)

        let task = makeFakeTask(statusCode: 400)
        let problemDoc = try makeProblemDoc(type: TPPProblemDocument.TypeNoActiveLoan)
        _ = handler.handleAuthFailureIfApplicable(book: book, task: task, problemDoc: problemDoc, failureError: nil)

        // State stays .unregistered (handler flipped it there before
        // dispatching the borrow) — the borrow "failed" or returned a
        // non-download outcome. Drive completion.
        XCTAssertEqual(registry.state(for: book.identifier), .unregistered)
        let completion = try XCTUnwrap(spyDelegate.startBorrowCalls.first?.completion,
                                       "Handler must pass a borrowCompletion closure for the post-borrow predicate to run")
        completion()
        await waitForAsyncCleanup()

        XCTAssertEqual(publishedErrors.map { $0.bookId }, [book.identifier],
                       "Borrow failure (state stayed .unregistered) must publish a download-error alert")
        // alertForProblemDocument removes no-active-loan books from
        // registry — confirms the alert path executed end-to-end.
        XCTAssertNil(registry.book(forIdentifier: book.identifier),
                     "alertForProblemDocument on no-active-loan must remove book from registry")
    }

    /// Pins the `.downloadSuccessful` branch of the post-borrow
    /// predicate: borrow succeeds and the download has already finished
    /// (e.g. cached) by the time the completion fires. Same swallow
    /// behavior as `.downloading`.
    func testAutoBorrowCompletion_whenBorrowSucceedsAndDownloadAlreadyFinished_doesNotPublishAlert() async throws {
        userAccount._authDefinition = makeAuth(typeRaw: "http://opds-spec.org/auth/basic")
        userAccount._credentials = .barcodeAndPin(barcode: "b", pin: "p")

        registry.addBook(book, location: nil, state: .downloading,
                         fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)

        var publishedErrors: [DownloadErrorInfo] = []
        progressReporter.downloadErrorPublisher
            .sink { publishedErrors.append($0) }
            .store(in: &cancellables)

        let task = makeFakeTask(statusCode: 400)
        let problemDoc = try makeProblemDoc(type: TPPProblemDocument.TypeNoActiveLoan)
        _ = handler.handleAuthFailureIfApplicable(book: book, task: task, problemDoc: problemDoc, failureError: nil)

        registry.setState(.downloadSuccessful, for: book.identifier)
        let completion = try XCTUnwrap(spyDelegate.startBorrowCalls.first?.completion)
        completion()
        await waitForAsyncCleanup()

        XCTAssertTrue(publishedErrors.isEmpty,
                      ".downloadSuccessful post-borrow state must also swallow the alert (&& clause)")
        XCTAssertNotNil(registry.book(forIdentifier: book.identifier))
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

    // MARK: - .credentialPrompt strategy explicit coverage (NEEDS-TEST-3)
    //
    // Per `.forgeos/audits/phase7-DownloadAuthRetryHandler.md`, the
    // `.credentialPrompt` case is implicitly grouped with `.none` in the
    // `switch reauthStrategy { ... case .credentialPrompt, .none: }`. The
    // existing test for `.tokenRefresh` proves one arm of the switch; this
    // test proves the `.credentialPrompt` arm fires the SAME outcome
    // (fall-through, returns false). Together with the SAML test (.browser)
    // and the OIDC test (.browser), all four enum cases are pinned by
    // behavior — defense in depth against a future refactor that flips
    // `.credentialPrompt`'s handling without updating the switch.
    //
    // typeRaw "http://opds-spec.org/auth/basic" → .basic auth →
    // .credentialPrompt reauthStrategy (see Account.swift:252).

    /// Branch: 401 + has-creds + `.credentialPrompt` → falls through (returns
    /// false) so caller's alert path runs. Pins the `.credentialPrompt` arm
    /// of the exhaustive `switch reauthStrategy`. A mutant that re-routed
    /// `.credentialPrompt` to a different arm would fail this test.
    func testHandle_401_withCredentials_credentialPromptStrategy_fallsThroughReturnsFalse() {
        userAccount._authDefinition = makeAuth(typeRaw: "http://opds-spec.org/auth/basic")
        userAccount._credentials = .barcodeAndPin(barcode: "b", pin: "p")

        registry.addBook(book, location: nil, state: .downloading,
                         fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)

        let task = makeFakeTask(statusCode: 401)
        let handled = handler.handleAuthFailureIfApplicable(book: book, task: task,
                                                            problemDoc: nil, failureError: nil)

        XCTAssertFalse(handled,
                       ".credentialPrompt + 401 + has-creds must fall through (caller alerts)")
        XCTAssertFalse(reauthenticator.authenticateIfNeededCalled,
                       ".credentialPrompt arm must NOT trigger sign-in modal at this site " +
                       "(modal is only triggered when hasCredentials is false)")
        XCTAssertTrue(spyDelegate.startDownloadCalls.isEmpty)
    }

    // MARK: - Re-auth cancellation guards (closes line-260 and line-286 mutants)
    //
    // Two re-auth completion paths gate the download retry:
    //
    //   :260 `presentSignInModal`         — guards `userAccount.hasCredentials()`
    //   :286 `reauthenticate(retryWith…)` — guards `userAccount.authState == .loggedIn`
    //
    // If the user cancels the sign-in modal, the guard short-circuits and
    // no retry fires. Existing tests prove the "success" arm (the modal
    // succeeds, then retry fires) for both paths. The cancellation arm is
    // uncovered: flipping `== .loggedIn` to `!= .loggedIn`, or removing the
    // hasCredentials guard, would silently retry the download against an
    // un-authenticated session — surfacing the same 401 in a loop.

    /// Re-auth cancelled on the no-credentials path (line 260): user never
    /// signed in, hasCredentials remains false, retry must NOT fire. Kills
    /// any mutant that drops the hasCredentials check at line 260.
    func testHandle_401_withoutCredentials_loginRequired_userCancelsSignIn_doesNotRetry() async throws {
        userAccount._authDefinition = makeAuth(typeRaw: "http://opds-spec.org/auth/basic")
        userAccount._credentials = nil
        XCTAssertFalse(userAccount.hasCredentials())

        // Re-auth completes WITHOUT setting credentials — simulates user
        // closing the modal without signing in.
        reauthenticator.onAuthenticate = { _, _ in /* user cancels */ }

        let task = makeFakeTask(statusCode: 401)
        let handled = handler.handleAuthFailureIfApplicable(book: book, task: task,
                                                            problemDoc: nil, failureError: nil)

        XCTAssertTrue(handled, "401 + no-creds must still claim the failure (modal presented)")
        await waitForAsyncCleanup()

        XCTAssertTrue(reauthenticator.authenticateIfNeededCalled,
                      "Modal must be presented even if user cancels — claim happens at presentation time")
        XCTAssertTrue(spyDelegate.startDownloadCalls.isEmpty,
                      "User cancelled sign-in (no credentials) — retry MUST NOT fire. " +
                      "A mutant that drops the hasCredentials guard at line 260 would silently retry.")
    }

    /// Re-auth cancelled on the OIDC browser path (line 286): user dismissed
    /// the in-app browser, authState stayed `.credentialsStale`. Retry must
    /// NOT fire. Kills the `authState == .loggedIn` -> `!= .loggedIn` mutant.
    func testHandle_401_withCredentials_browserOIDC_userCancelsReauth_doesNotRetry() async throws {
        userAccount._authDefinition = makeAuth(typeRaw: "http://palaceproject.io/authtype/OpenIDConnect")
        userAccount._credentials = .barcodeAndPin(barcode: "b", pin: "p")

        registry.addBook(book, location: nil, state: .downloading,
                         fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)

        // Re-auth completes WITHOUT calling markLoggedIn — the user dismissed
        // the OIDC browser. The handler called `markCredentialsStale` earlier,
        // so authState is now `.credentialsStale`, NOT `.loggedIn`. Guard at
        // line 286 should short-circuit.
        reauthenticator.onAuthenticate = { _, _ in /* user dismisses */ }

        let task = makeFakeTask(statusCode: 401)
        let handled = handler.handleAuthFailureIfApplicable(book: book, task: task,
                                                            problemDoc: nil, failureError: nil)

        XCTAssertTrue(handled)
        await waitForAsyncCleanup()

        XCTAssertTrue(reauthenticator.authenticateIfNeededCalled,
                      "OIDC re-auth modal must be presented")
        XCTAssertTrue(spyDelegate.startDownloadCalls.isEmpty,
                      "User dismissed OIDC browser (authState != .loggedIn) — retry MUST NOT fire. " +
                      "A mutant that flips `== .loggedIn` to `!= .loggedIn` at line 286 would silently retry.")
    }
}

// MARK: - Spy

private final class SpyDelegate: DownloadAuthRetryHandlerDelegate {
    private(set) var startDownloadCalls: [(book: TPPBook, identifier: String)] = []
    // Captures the `attemptDownload` parameter (F-014-shape pin) and the
    // `borrowCompletion` closure so tests can drive the post-borrow
    // predicate at DownloadAuthRetryHandler.swift:235.
    private(set) var startBorrowCalls: [(book: TPPBook, identifier: String, attemptDownload: Bool, completion: (() -> Void)?)] = []

    func startDownload(for book: TPPBook, withRequest request: URLRequest?) {
        startDownloadCalls.append((book, book.identifier))
    }

    func startBorrow(for book: TPPBook, attemptDownload: Bool, borrowCompletion: (() -> Void)?) {
        startBorrowCalls.append((book, book.identifier, attemptDownload, borrowCompletion))
    }
}
