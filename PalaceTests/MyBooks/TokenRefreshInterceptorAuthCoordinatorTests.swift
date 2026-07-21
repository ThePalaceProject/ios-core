//
//  TokenRefreshInterceptorAuthCoordinatorTests.swift
//  PalaceTests
//
//  swarm_66819d80 Module C — caller-migration assertions for
//  `TokenRefreshInterceptor` when wired with an `AuthCoordinator`.
//
//  When the coordinator is injected, the SAML + generic browser dispatch
//  branches inside `handleDownloadFailureWithAuthCheck`,
//  the `no-active-loan` PP-3716 branch, and `handleProblem` route through
//  `coordinator.refreshCredentialsIfNeeded(reason:)`. The OIDC silent
//  reauth path STAYS UNCHANGED (Option A from the contract).
//

import XCTest
import Combine
import PalaceCatalog
@testable import Palace
@testable import PalaceAuth

@MainActor
final class TokenRefreshInterceptorAuthCoordinatorTests: XCTestCase {

    private var interceptor: TokenRefreshInterceptor!
    private var mockReauthenticator: TPPReauthenticatorMock!
    private var mockDelegate: MockTokenRefreshDelegate!
    private var mockRegistry: TPPBookRegistryMock!
    private var mockUserAccount: TPPUserAccountMock!

    override func setUp() {
        super.setUp()
        mockReauthenticator = TPPReauthenticatorMock()
        mockRegistry = TPPBookRegistryMock()
        mockUserAccount = TPPUserAccountMock()
        mockDelegate = MockTokenRefreshDelegate(
            bookRegistry: mockRegistry,
            userAccount: mockUserAccount
        )
    }

    override func tearDown() {
        interceptor = nil
        mockReauthenticator = nil
        mockDelegate = nil
        mockRegistry = nil
        mockUserAccount = nil
        TPPUserAccountMock.resetShared()
        super.tearDown()
    }

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

    private final class FakeURLSessionDownloadTask: URLSessionDownloadTask, @unchecked Sendable {
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

    /// Drains the coordinator-routed retry Task by servicing the main-actor
    /// executor rather than sleeping a fixed 10×50ms. The routed path is a
    /// single `Task { @MainActor }` whose interior `await`s (stateManager
    /// remove/registerCompletion, `coordinator.refreshCredentialsIfNeeded` —
    /// the spy modal returns synchronously) each resume on a subsequent
    /// main-actor turn; awaiting a chain of barrier `Task { @MainActor }`
    /// values steps the executor through those resumptions until the terminal
    /// main-actor effects (modal present / markStale / state flip / retry)
    /// have run. Completes the instant the actor is free — never starves on a
    /// wall clock.
    ///
    /// NOTE: TokenRefreshInterceptor has no in-flight-Task retention seam (its
    /// siblings DownloadAuthRetryHandler / BookReturnService do), so this can't
    /// `await` the exact Task handle. The barrier-flush is deterministic for
    /// the ready-actor interior hops here; a retention seam on the interceptor
    /// (behavior-identical, mirroring the siblings) would let this become an
    /// exact `task.value` join — flagged as the complete follow-up fix.
    private func waitForAsyncCleanup() async {
        for _ in 0..<6 {
            await Task { @MainActor in }.value
        }
    }

    // MARK: - SAML 401 routes through coordinator

    func testCoordinator_401_SAML_dispatchesViaCoordinator_andSetsSAMLStarted() async throws {
        let (coordinator, _, modal, userAcctSpy, _) = SpyAuthCoordinatorFactory.make(
            mechanism: .saml,
            stubModalResult: true
        )
        interceptor = TokenRefreshInterceptor(
            reauthenticator: mockReauthenticator,
            authCoordinator: coordinator
        )
        interceptor.delegate = mockDelegate

        mockUserAccount._authDefinition = makeAuth(typeRaw: "http://librarysimplified.org/authtype/SAML-2.0")
        mockUserAccount._credentials = .barcodeAndPin(barcode: "b", pin: "p")
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        mockRegistry.addBook(book, location: nil, state: .downloading,
                             fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)

        let task = makeFakeTask(statusCode: 401)
        let handled = interceptor.handleDownloadFailureWithAuthCheck(
            for: book, task: task, problemDoc: nil, failureError: nil
        )
        XCTAssertTrue(handled, "401 + browser SAML must claim the failure")

        await waitForAsyncCleanup()

        XCTAssertEqual(modal.presentCallCount, 1,
                       "SAML 401 routes through coordinator → modal")
        XCTAssertEqual(userAcctSpy.markCredentialsStaleCallCount, 1,
                       "Coordinator owns markCredentialsStale on the SAML path")
        XCTAssertFalse(mockReauthenticator.authenticateIfNeededCalled,
                       "Legacy reauthenticator path bypassed when coordinator is wired")
        XCTAssertEqual(mockRegistry.state(for: book.identifier), .SAMLStarted,
                       "Per-book SAML state transition still happens at this call site")
        XCTAssertEqual(mockDelegate.startDownloadCalls.count, 1,
                       "Coordinator success → startDownload retry")
    }

    // MARK: - OAuth-intermediary does NOT enter the browser-reauth branch here

    /// OAuth-intermediary's `reauthStrategy` is `.tokenRefresh`, not
    /// `.browser`, in the main-target `AccountDetails.Authentication`
    /// mapping. That means the `handleDownloadFailureWithAuthCheck`
    /// browser branch (which the coordinator-routing wrap sits inside)
    /// is bypassed for Clever; the `.tokenRefresh` arm falls through to
    /// the no-active-loan check + caller alert. Pinning that the
    /// coordinator is NOT invoked for OAuth-intermediary here is
    /// important — it prevents over-routing.
    func testCoordinator_401_OAuthIntermediary_doesNotInvokeCoordinator_fallsToTokenRefreshPath() async throws {
        let (coordinator, _, modal, _, _) = SpyAuthCoordinatorFactory.make(
            mechanism: .oauthIntermediary,
            stubModalResult: true
        )
        interceptor = TokenRefreshInterceptor(
            reauthenticator: mockReauthenticator,
            authCoordinator: coordinator
        )
        interceptor.delegate = mockDelegate

        mockUserAccount._authDefinition = makeAuth(typeRaw: "http://librarysimplified.org/authtype/OAuth-with-intermediary")
        mockUserAccount._credentials = .barcodeAndPin(barcode: "b", pin: "p")
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        mockRegistry.addBook(book, location: nil, state: .downloading,
                             fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)

        let task = makeFakeTask(statusCode: 401)
        _ = interceptor.handleDownloadFailureWithAuthCheck(
            for: book, task: task, problemDoc: nil, failureError: nil
        )

        await waitForAsyncCleanup()

        XCTAssertEqual(modal.presentCallCount, 0,
                       "OAuth-intermediary lands in the .tokenRefresh arm — the coordinator must not be invoked")
        XCTAssertEqual(mockDelegate.startDownloadCalls.count, 0,
                       "No retry from this layer for .tokenRefresh — caller path takes over")
    }

    // MARK: - OIDC stays on its own silent-reauth path (Option A)

    /// OIDC must NOT route through the coordinator — `triggerOIDCReauth`
    /// drives `ASWebAuthenticationSession` directly which the coordinator
    /// can't replicate. Pinning this preserves the silent-OIDC dance.
    func testCoordinator_401_OIDC_doesNotRouteThroughCoordinator() async throws {
        let (coordinator, _, modal, _, _) = SpyAuthCoordinatorFactory.make(
            mechanism: .oidc,
            stubModalResult: true
        )
        interceptor = TokenRefreshInterceptor(
            reauthenticator: mockReauthenticator,
            authCoordinator: coordinator
        )
        interceptor.delegate = mockDelegate

        mockUserAccount._authDefinition = makeAuth(typeRaw: "http://palaceproject.io/authtype/OpenIDConnect")
        mockUserAccount._credentials = .barcodeAndPin(barcode: "b", pin: "p")
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        mockRegistry.addBook(book, location: nil, state: .downloading,
                             fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)

        let task = makeFakeTask(statusCode: 401)
        let handled = interceptor.handleDownloadFailureWithAuthCheck(
            for: book, task: task, problemDoc: nil, failureError: nil
        )
        XCTAssertTrue(handled,
                      "OIDC 401 still claims the failure — but via triggerOIDCReauth, not the coordinator")

        await waitForAsyncCleanup()

        XCTAssertEqual(modal.presentCallCount, 0,
                       "OIDC must NOT route through the coordinator's modal — it has its own silent-reauth dance")
    }

    // MARK: - no-active-loan (PP-3716) routes through coordinator for SAML

    func testCoordinator_noActiveLoan_SAML_dispatchesViaCoordinator_andSetsSAMLStarted() async throws {
        let (coordinator, _, modal, _, _) = SpyAuthCoordinatorFactory.make(
            mechanism: .saml,
            stubModalResult: true
        )
        interceptor = TokenRefreshInterceptor(
            reauthenticator: mockReauthenticator,
            authCoordinator: coordinator
        )
        interceptor.delegate = mockDelegate

        mockUserAccount._authDefinition = makeAuth(typeRaw: "http://librarysimplified.org/authtype/SAML-2.0")
        mockUserAccount._credentials = .barcodeAndPin(barcode: "b", pin: "p")
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        mockRegistry.addBook(book, location: nil, state: .downloading,
                             fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)

        let problemDoc = try makeProblemDoc(type: TPPProblemDocument.TypeNoActiveLoan)
        let task = makeFakeTask(statusCode: 200) // not a 401 — relies on problem-doc type
        let handled = interceptor.handleDownloadFailureWithAuthCheck(
            for: book, task: task, problemDoc: problemDoc, failureError: nil
        )
        XCTAssertTrue(handled, "no-active-loan SAML with credentials must claim the failure (PP-3716)")

        await waitForAsyncCleanup()

        XCTAssertEqual(modal.presentCallCount, 1,
                       "no-active-loan SAML path also routes through coordinator")
        XCTAssertEqual(mockRegistry.state(for: book.identifier), .SAMLStarted,
                       "no-active-loan SAML path keeps per-book .SAMLStarted")
    }

    // MARK: - User-cancellation propagates correctly

    func testCoordinator_401_SAML_userCancel_doesNotRetry_butStillFlipsPerBookState() async throws {
        let (coordinator, _, modal, _, _) = SpyAuthCoordinatorFactory.make(
            mechanism: .saml,
            stubModalResult: false   // user cancelled
        )
        interceptor = TokenRefreshInterceptor(
            reauthenticator: mockReauthenticator,
            authCoordinator: coordinator
        )
        interceptor.delegate = mockDelegate

        mockUserAccount._authDefinition = makeAuth(typeRaw: "http://librarysimplified.org/authtype/SAML-2.0")
        mockUserAccount._credentials = .barcodeAndPin(barcode: "b", pin: "p")
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        mockRegistry.addBook(book, location: nil, state: .downloading,
                             fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)

        let task = makeFakeTask(statusCode: 401)
        _ = interceptor.handleDownloadFailureWithAuthCheck(for: book, task: task, problemDoc: nil, failureError: nil)
        await waitForAsyncCleanup()

        XCTAssertEqual(modal.presentCallCount, 1)
        XCTAssertEqual(mockRegistry.state(for: book.identifier), .SAMLStarted,
                       "SAML state still flips after cancel — next attempt starts clean")
        XCTAssertTrue(mockDelegate.startDownloadCalls.isEmpty,
                      "Retry MUST NOT fire on coordinator cancellation")
    }

    // MARK: - handleProblem also routes through coordinator for SAML cookie expiry

    func testCoordinator_handleProblem_browserSAML_dispatchesViaCoordinator() async throws {
        let (coordinator, _, modal, _, _) = SpyAuthCoordinatorFactory.make(
            mechanism: .saml,
            stubModalResult: true
        )
        interceptor = TokenRefreshInterceptor(
            reauthenticator: mockReauthenticator,
            authCoordinator: coordinator
        )
        interceptor.delegate = mockDelegate

        mockUserAccount._authDefinition = makeAuth(typeRaw: "http://librarysimplified.org/authtype/SAML-2.0")
        mockUserAccount._credentials = .barcodeAndPin(barcode: "b", pin: "p")
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        // Pre-state: NOT .SAMLStarted so the handleProblem circuit-breaker
        // doesn't fire — we want the browser-expired branch to execute.
        mockRegistry.addBook(book, location: nil, state: .downloading,
                             fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)

        interceptor.handleProblem(for: book, problemDocument: nil)

        await waitForAsyncCleanup()

        XCTAssertEqual(modal.presentCallCount, 1,
                       "handleProblem browser-SAML path routes through coordinator")
        XCTAssertEqual(mockRegistry.state(for: book.identifier), .SAMLStarted,
                       "Per-book .SAMLStarted state still flips at this call site")
    }

    // MARK: - Foreign-host guard (PR #1018 cross-host regression fix)

    /// Air-tight test for the foreign-host short-circuit. With a current-
    /// account auth surface of `{minotaur.dev.palaceproject.io}` and a
    /// 401 download failure from `gorgon.staging.palaceproject.io/...`,
    /// the interceptor MUST:
    ///   - Return false (failure not claimed by this layer)
    ///   - NOT mark the current account's credentials stale
    ///   - NOT dispatch the coordinator
    ///
    /// This is the SAML scenario (most fragile per the dispatch matrix —
    /// SAML always routes to modal). Without the foreign-host guard, the
    /// existing SAML-on-401 path would mark stale + dispatch the
    /// coordinator → modal pops for the wrong account on every
    /// foreign-library download retry.
    ///
    /// Wall-failure 2026-06-05-pr1018-icarus-cross-host-logout.md.
    func testForeignHost_401_SAML_doesNotMarkCredentialsStale_doesNotDispatchCoordinator() async throws {
        let (coordinator, _, modal, userAcctSpy, _) = SpyAuthCoordinatorFactory.make(
            mechanism: .saml,
            stubModalResult: true
        )
        interceptor = TokenRefreshInterceptor(
            reauthenticator: mockReauthenticator,
            authCoordinator: coordinator,
            currentAccountHostsProvider: { Set(["minotaur.dev.palaceproject.io"]) }
        )
        interceptor.delegate = mockDelegate

        mockUserAccount._authDefinition = makeAuth(typeRaw: "http://librarysimplified.org/authtype/SAML-2.0")
        mockUserAccount._credentials = .barcodeAndPin(barcode: "b", pin: "p")
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        mockRegistry.addBook(book, location: nil, state: .downloading,
                             fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)

        // 401 from a host OUTSIDE the current account's auth surface
        let foreignURL = URL(string: "https://gorgon.staging.palaceproject.io/a1qa-test/loans/123")!
        let task = makeFakeTask(statusCode: 401, url: foreignURL)
        let handled = interceptor.handleDownloadFailureWithAuthCheck(
            for: book, task: task, problemDoc: nil, failureError: nil
        )
        XCTAssertFalse(handled,
                       "Foreign-host 401 must NOT be claimed by the interceptor — falls through to the caller's normal alert path (no auth action taken). Regression: returning true here would mean the interceptor still 'handled' it via the modal path.")

        await waitForAsyncCleanup()

        XCTAssertEqual(modal.presentCallCount, 0,
                       "Foreign-host 401 MUST NOT dispatch the coordinator — the whole point of the guard is to skip the modal for the current account when the 401 belongs to a DIFFERENT account's session.")
        XCTAssertEqual(userAcctSpy.markCredentialsStaleCallCount, 0,
                       "Foreign-host 401 MUST NOT mark the current account's credentials stale — that's the latent bug that pre-PR #1018 was passive (no modal) and post-#1018 became active (modal every minute).")
        XCTAssertEqual(mockDelegate.startDownloadCalls.count, 0,
                       "No retry: foreign-host 401 is bubbled up to the caller. Regression here would mean we retried a download for a book that's no longer ours.")
    }

    /// Belt-and-braces: a nil provider preserves legacy behavior. Without
    /// this test, a refactor that flipped the default from `nil` to
    /// `{ Set<String>() }` would silently change behavior.
    func testForeignHost_401_SAML_withNilProvider_fallsBackToLegacyDispatch() async throws {
        let (coordinator, _, modal, _, _) = SpyAuthCoordinatorFactory.make(
            mechanism: .saml,
            stubModalResult: true
        )
        // currentAccountHostsProvider intentionally OMITTED (defaults to nil)
        interceptor = TokenRefreshInterceptor(
            reauthenticator: mockReauthenticator,
            authCoordinator: coordinator
        )
        interceptor.delegate = mockDelegate

        mockUserAccount._authDefinition = makeAuth(typeRaw: "http://librarysimplified.org/authtype/SAML-2.0")
        mockUserAccount._credentials = .barcodeAndPin(barcode: "b", pin: "p")
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        mockRegistry.addBook(book, location: nil, state: .downloading,
                             fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)

        // Same foreign URL — but provider is nil so legacy dispatch fires
        let foreignURL = URL(string: "https://gorgon.staging.palaceproject.io/a1qa-test/loans/123")!
        let task = makeFakeTask(statusCode: 401, url: foreignURL)
        _ = interceptor.handleDownloadFailureWithAuthCheck(
            for: book, task: task, problemDoc: nil, failureError: nil
        )

        await waitForAsyncCleanup()

        XCTAssertEqual(modal.presentCallCount, 1,
                       "Nil provider preserves legacy behavior — SAML 401 still dispatches the coordinator → modal. A regression where nil is treated as empty-set would silently disable the legacy dispatch.")
    }
}
