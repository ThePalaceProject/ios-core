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
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            await Task.yield()
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
}
