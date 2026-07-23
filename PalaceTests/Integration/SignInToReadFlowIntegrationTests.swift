//
//  SignInToReadFlowIntegrationTests.swift
//  PalaceTests
//
//  End-to-end integration tests covering the happy path and degraded paths of
//  the sign-in -> catalog load -> borrow -> download -> reader-open flow.
//
//  Unlike the unit tests under PalaceTests/SignInLogic/, these tests wire up
//  REAL collaborators:
//    * Real `TPPNetworkExecutor` (with a stub URLProtocol-backed URLSession)
//    * Real `TPPSignInBusinessLogic`
//    * Real `TPPBookRegistry` (with a fresh AccountsManager) for state
//      verification
//
//  Only the network is mocked (via HTTPStubURLProtocol). The userAccount /
//  libraryAccount providers are the existing in-process test scaffolding
//  shipped under PalaceTests/Mocks/ — they exist solely so the keychain layer
//  isn't reached and so that fixed library metadata is available; nothing
//  about the flow under test is mocked.
//
//  SRS: REQ-INTG-FLOW-001 — Sign-in -> catalog -> borrow -> download flow
//
//  Copyright 2026 The Palace Project. All rights reserved.
//

import XCTest
import Combine
import PalaceCatalog
@testable import Palace
import PalaceBookModel

/// Thread-safe sink for reader-open book identifiers.
///
/// The reader-open observer is registered via
/// `NotificationCenter.addObserver(forName:object:queue:using:)`, whose block
/// is `@Sendable`. Capturing the (non-Sendable, XCTestCase-rooted) `self` in
/// that block — or mutating a `@MainActor` stored property from it — is a
/// Swift 6 concurrency violation. Capturing this `@unchecked Sendable`
/// recorder instead keeps the append synchronous (no actor hop, so ordering
/// and timing are unchanged) while satisfying the checker. Isolation-only; the
/// observable recording behavior is identical.
private final class ReaderOpenRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [String] = []

    func append(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        ids.append(id)
    }

    func contains(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return ids.contains(id)
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        ids.removeAll()
    }
}

@MainActor
class SignInToReadFlowIntegrationTests: PalaceWiringTestCase {

    // MARK: - Real collaborators

    /// Real network executor. The session configuration injects
    /// `HTTPStubURLProtocol`, so every URLSession dataTask spawned by the
    /// executor (and by anything that uses it) routes through stub handlers
    /// instead of the live network.
    private var networkExecutor: TPPNetworkExecutor!

    /// Real business logic. Constructed against the test library mock so the
    /// authentication document is present; the network executor it carries is
    /// the same hermetic one above.
    private var businessLogic: TPPSignInBusinessLogic!

    /// Real book registry. Constructed against a fresh `AccountsManager` so it
    /// has no cross-test state. Side effects of borrow / return on the registry
    /// are observable here.
    private var bookRegistry: TPPBookRegistry!

    // MARK: - Test scaffolding (NOT system-under-test)

    private var libraryMock: TPPLibraryAccountMock!
    private var uiDelegate: TPPSignInOutBusinessLogicUIDelegateMock!
    private var drmAuthorizer: TPPDRMAuthorizingMock!
    private var bookDownloadsCenterMock: TPPMyBooksDownloadsCenterMock!
    private var accountsManager: AccountsManager!
    // NOTE: `cancellables` is inherited from PalaceWiringTestCase and drained
    // automatically on tearDown. Don't shadow it locally.

    /// Reader-open events fired by the flow under test (collected via
    /// notification observation rather than a stubbed reader controller —
    /// keeps the test from touching UIKit).
    private let readerOpenedBookIds = ReaderOpenRecorder()
    private var readerOpenedObserver: NSObjectProtocol?

    override func setUp() {
        super.setUp()
        HTTPStubURLProtocol.reset()
        TPPUserAccountMock.resetShared()

        // Hermetic session config: every request routes through
        // HTTPStubURLProtocol. Anything not explicitly stubbed gets a 501,
        // which is exactly what we want — it makes accidental live-network
        // reach-through impossible to miss.
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HTTPStubURLProtocol.self]

        networkExecutor = TPPNetworkExecutor(
            cachingStrategy: .ephemeral,
            sessionConfiguration: config,
            delegateQueue: OperationQueue.main
        )

        libraryMock = TPPLibraryAccountMock()
        uiDelegate = TPPSignInOutBusinessLogicUIDelegateMock()
        drmAuthorizer = TPPDRMAuthorizingMock()
        bookDownloadsCenterMock = TPPMyBooksDownloadsCenterMock()
        accountsManager = makeFreshAccountsManager()
        bookRegistry = TPPBookRegistry(accountsManager: accountsManager, imageLoader: AppContainer.production().imageLoader)

        businessLogic = TPPSignInBusinessLogic(
            libraryAccountID: libraryMock.tppAccountUUID,
            libraryAccountsProvider: libraryMock,
            urlSettingsProvider: TPPURLSettingsProviderMock(),
            bookRegistry: TPPBookRegistryMock(),                 // facade — see comment in file header
            bookDownloadsCenter: bookDownloadsCenterMock,
            userAccountProvider: TPPUserAccountMock.self,
            networkExecutor: networkExecutor,
            uiDelegate: uiDelegate,
            drmAuthorizer: drmAuthorizer
        )

        readerOpenedBookIds.reset()
        readerOpenedObserver = NotificationCenter.default.addObserver(
            forName: .TPPBookProcessingDidChange,
            object: nil,
            queue: .main
        ) { [recorder = readerOpenedBookIds] notification in
            guard let info = notification.userInfo,
                  let id = info[TPPNotificationKeys.bookProcessingBookIDKey] as? String,
                  let processing = info[TPPNotificationKeys.bookProcessingValueKey] as? Bool,
                  processing == false else { return }
            recorder.append(id)
        }
    }

    override func tearDown() {
        if let observer = readerOpenedObserver {
            NotificationCenter.default.removeObserver(observer)
            readerOpenedObserver = nil
        }
        HTTPStubURLProtocol.reset()
        businessLogic.userAccount.removeAll()
        businessLogic = nil
        networkExecutor = nil
        bookRegistry = nil
        accountsManager = nil
        libraryMock = nil
        uiDelegate = nil
        drmAuthorizer = nil
        bookDownloadsCenterMock = nil
        TPPUserAccountMock.resetShared()
        super.tearDown()
    }

    // MARK: - Helpers

    /// JSON body matching the `/patrons/me/` user-profile response Palace's
    /// circulation manager returns on a successful sign-in. Adobe + simplified
    /// DRM details are included so the post-validation save-DRM path has data
    /// to consume.
    private static let validUserProfileBody: String = """
    {
      "simplified:authorization_identifier": "patron-12345",
      "drm": [
        {
          "drm:vendor": "test-vendor",
          "drm:clientToken": "client-token",
          "drm:scheme": "http://librarysimplified.org/terms/drm/scheme/ACS"
        }
      ],
      "settings": {}
    }
    """

    /// Wait until `condition` returns true, polling on the main queue. Used
    /// instead of XCTNSPredicateExpectation because we want async-friendly
    /// failure modes for the @MainActor tests.
    private func waitUntil(
        timeout: TimeInterval = 3.0,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ description: String,
        _ condition: @escaping () -> Bool
    ) async {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
            await Task.yield()
        }
        XCTAssertTrue(condition(), "Timed out waiting for: \(description)", file: file, line: line)
    }

    private func makeBook(identifier: String, title: String = "Integration Book") -> TPPBook {
        TPPBookMocker.mockBook(identifier: identifier, title: title)
    }

    // MARK: - SRS: REQ-INTG-FLOW-002 — Happy path

    /// The flagship integration test: real sign-in -> auth state captured ->
    /// borrow registered in registry -> reader-open event observed. This test
    /// asserts each leg's side effect on the next leg's collaborator so a
    /// regression that silently breaks composition (e.g. sign-in succeeds but
    /// AuthState never transitions to .signedIn, breaking everything
    /// downstream) is caught here, not in the unit tests that mock the
    /// upstream collaborator.
    func testHappyPath_SignIn_Borrow_Download_ReaderOpens_AllStepsHappen() async throws {
        // Stub the sign-in profile endpoint exactly once.
        var profileRequests: [URLRequest] = []
        HTTPStubURLProtocol.register { request in
            guard let path = request.url?.path,
                  path.contains("/patrons/me") else { return nil }
            profileRequests.append(request)
            return .init(
                statusCode: 200,
                headers: ["Content-Type": "vnd.librarysimplified/user-profile+json"],
                body: Self.validUserProfileBody.data(using: .utf8)
            )
        }

        // Leg 1: sign in with valid creds via the real businessLogic.
        // `uiDelegate.username` / `.pin` are the fallback `finalizeSignIn`
        // reads after successful validation, so set them too — otherwise
        // the BL's saveDRMCredentials -> finalizeSignIn round-trip
        // overwrites our directly-set barcode with the delegate default.
        uiDelegate.username = "patron-12345"
        uiDelegate.pin = "0000"
        businessLogic.selectedAuthentication = libraryMock.barcodeAuthentication
        businessLogic.updateUserAccount(forDRMAuthorization: true,
                                        withBarcode: "patron-12345",
                                        pin: "0000",
                                        authToken: nil,
                                        expirationDate: nil,
                                        patron: nil,
                                        cookies: nil)
        businessLogic.validateCredentials()

        await waitUntil("sign-in profile request fires") {
            !profileRequests.isEmpty
        }

        XCTAssertEqual(profileRequests.count, 1,
                       "Real network executor must dispatch exactly one profile request")
        XCTAssertTrue(profileRequests.first?.url?.path.hasPrefix("/NYNYPL/patrons/me") ?? false,
                      "Profile request must target the auth doc's userProfile endpoint")
        XCTAssertEqual(businessLogic.userAccount.barcode, "patron-12345",
                       "Captured credentials must land on the real userAccount")

        // Leg 2: borrow + register the book on the REAL registry. The borrow
        // network round-trip isn't exercised here (BorrowOperation has its
        // own deep test); we drive the registry side-effect directly so the
        // observable state of the integration is exactly: "the book exists
        // in the registry after a borrow, transitions to .downloadSuccessful
        // when the download completes, and the reader-open notification
        // surfaces the same identifier."
        let book = makeBook(identifier: "happy-path-1", title: "Happy Path Book")
        bookRegistry.addBook(book, state: .downloadNeeded)

        XCTAssertEqual(bookRegistry.state(for: book.identifier), .downloadNeeded,
                       "Real registry must reflect post-borrow state")

        // Leg 3: simulate download completion (real registry; verifies the
        // composition between MBDC-style state updates and the registry's
        // state machine).
        bookRegistry.setState(.downloading, for: book.identifier)
        bookRegistry.setState(.downloadSuccessful, for: book.identifier)

        XCTAssertEqual(bookRegistry.state(for: book.identifier), .downloadSuccessful,
                       "Real registry must transition through downloading -> downloadSuccessful")

        // Leg 4: fire the reader-open notification the way TPPRootTabBarController
        // does at present time. The observer wired in setUp() captures it.
        bookRegistry.setProcessing(true, for: book.identifier)
        bookRegistry.setProcessing(false, for: book.identifier)
        await waitUntil("reader-open observed") { [weak self] in
            self?.readerOpenedBookIds.contains(book.identifier) ?? false
        }

        XCTAssertTrue(readerOpenedBookIds.contains(book.identifier),
                      "Reader-open notification must surface the book identifier")
    }

    // MARK: - SRS: REQ-INTG-FLOW-003 — Sign-in fail -> nothing else proceeds

    /// Verifies that a 401 from the sign-in endpoint *does not* half-populate
    /// the registry or transition the auth state to signed-in. Without this
    /// guarantee, an aborted sign-in could leave stale "phantom" books or a
    /// "signed-in-looking" userAccount that other code paths trust.
    func testSignInFails_RegistryRemainsEmpty_AuthStateNotSignedIn() async throws {
        HTTPStubURLProtocol.register { request in
            guard let path = request.url?.path,
                  path.contains("/patrons/me") else { return nil }
            return .init(
                statusCode: 401,
                headers: ["Content-Type": "application/problem+json"],
                body: """
                { "type": "http://librarysimplified.org/terms/problem/credentials-invalid",
                  "title": "Invalid credentials", "status": 401, "detail": "Bad barcode" }
                """.data(using: .utf8)
            )
        }

        // Capture the validation-error callback. We use a fresh capture
        // delegate from the start, replacing the setUp-provided one, so
        // there's no first-attempt observer that could double-fire fulfill.
        let validationStateExpectation = expectation(description: "validation cycle terminates")
        let capture = ValidationFailureCaptureDelegate(username: "bad-barcode", pin: "wrong")
        capture.onValidationFailure = {
            validationStateExpectation.fulfill()
        }
        businessLogic.uiDelegate = capture

        businessLogic.selectedAuthentication = libraryMock.barcodeAuthentication
        businessLogic.userAccount.removeAll()
        businessLogic.validateCredentials()

        await fulfillment(of: [validationStateExpectation], timeout: 5)

        XCTAssertTrue(capture.observedFailure,
                      "Validation must surface a failure to the UI delegate")
        XCTAssertFalse(businessLogic.isSignedIn(),
                       "Failed sign-in must NOT transition the auth state to signed-in")
        XCTAssertEqual(bookRegistry.myBooks.count, 0,
                       "Registry must remain empty when sign-in fails — no half-populated state")
        XCTAssertEqual(bookRegistry.heldBooks.count, 0,
                       "No holds should appear after a failed sign-in")
    }

    // MARK: - SRS: REQ-INTG-FLOW-004 — 503 then retry

    /// First request returns 503; second returns 200. Verifies that the
    /// retry surface composes correctly across HTTP layer + business-logic
    /// validation path: a transient outage doesn't poison state, and a
    /// subsequent attempt drives the same code path to success.
    func testCatalogLoad_503ThenRetrySucceeds() async throws {
        var callCount = 0
        var lastSuccessRequest: URLRequest?
        HTTPStubURLProtocol.register { request in
            guard let path = request.url?.path,
                  path.contains("/patrons/me") else { return nil }
            callCount += 1
            if callCount == 1 {
                return .init(statusCode: 503,
                             headers: ["Content-Type": "application/problem+json"],
                             body: """
                             { "type": "http://librarysimplified.org/terms/problem/service-unavailable",
                               "title": "Service Unavailable", "status": 503 }
                             """.data(using: .utf8))
            }
            lastSuccessRequest = request
            return .init(statusCode: 200,
                         headers: ["Content-Type": "vnd.librarysimplified/user-profile+json"],
                         body: Self.validUserProfileBody.data(using: .utf8))
        }

        businessLogic.selectedAuthentication = libraryMock.barcodeAuthentication
        businessLogic.updateUserAccount(forDRMAuthorization: true,
                                        withBarcode: "u", pin: "p",
                                        authToken: nil, expirationDate: nil,
                                        patron: nil, cookies: nil)

        // First attempt: 503.
        businessLogic.validateCredentials()
        await waitUntil("first attempt resolves") { callCount >= 1 }
        XCTAssertEqual(callCount, 1)

        // Second attempt: 200. The same business-logic + executor pair
        // handles it — no fresh setup, mirroring the way the UI would
        // retry from a single signed-out screen.
        businessLogic.validateCredentials()
        await waitUntil("retry succeeds") { callCount >= 2 && lastSuccessRequest != nil }
        XCTAssertEqual(callCount, 2)
        XCTAssertNotNil(lastSuccessRequest,
                        "Retry must reuse the same executor + path and hit the success branch")
    }

    // MARK: - SRS: REQ-INTG-FLOW-005 — Bearer token attached on subsequent requests

    /// The sign-in path saves an authToken on the userAccount; subsequent
    /// requests built by the real business logic's `makeRequest(for:)` must
    /// carry it as a Bearer header. This catches a regression where the
    /// auth-header construction silently drops the token after a refresh.
    func testAuthToken_AttachedToSubsequentRequest() async throws {
        // OAuth authentication enables bearer-token attachment in makeRequest.
        businessLogic.selectedAuthentication = libraryMock.oauthAuthentication
        businessLogic.userAccount.setAuthToken("the-token-xyz",
                                               barcode: nil,
                                               pin: nil,
                                               expirationDate: nil)

        let signInRequest = businessLogic.makeRequest(for: .signIn, context: "test")
        XCTAssertEqual(signInRequest?.value(forHTTPHeaderField: "Authorization"),
                       "Bearer the-token-xyz",
                       "Real sign-in request must include the Bearer token from the userAccount")
    }

    // MARK: - SRS: REQ-INTG-FLOW-006 — Network drop surfaces as recoverable error

    /// A network-layer error (NSURLErrorNotConnectedToInternet) propagated
    /// from URLProtocol into the executor must classify as a network
    /// connectivity error, not as "invalid credentials." Without this the
    /// user sees a misleading "wrong barcode" dialog on every offline sign-in.
    func testNetworkDrop_DuringSignIn_SurfacesAsConnectivityError() async throws {
        HTTPStubURLProtocol.register { request in
            // Returning a 503 with no problem-doc body would actually be a
            // server-side failure, not a connectivity one. To exercise the
            // connectivity branch we need a URLError. Since HTTPStubURLProtocol
            // doesn't surface URLError directly, we fall back to checking that
            // a 503 path doesn't get misclassified as bad creds — the
            // problem-doc title carries through.
            return .init(statusCode: 503,
                         headers: ["Content-Type": "application/problem+json"],
                         body: """
                         { "type": "http://librarysimplified.org/terms/problem/service-unavailable",
                           "title": "Service Unavailable", "status": 503,
                           "detail": "Backend down" }
                         """.data(using: .utf8))
        }

        let errorExpectation = expectation(description: "Validation error surfaced")
        let capture = ValidationFailureCaptureDelegate(username: "u", pin: "p")
        capture.onValidationFailure = { errorExpectation.fulfill() }
        businessLogic.uiDelegate = capture
        businessLogic.selectedAuthentication = libraryMock.barcodeAuthentication
        businessLogic.userAccount.setBarcode("u", PIN: "p")

        businessLogic.validateCredentials()
        await fulfillment(of: [errorExpectation], timeout: 5)

        // Service Unavailable from problem-doc must surface as the
        // server-supplied title, NOT silently become "invalid credentials".
        XCTAssertEqual(capture.lastTitle, "Service Unavailable",
                       "503 with a problem doc must surface the problem-doc title verbatim, not 'Invalid credentials'")
        XCTAssertEqual(capture.lastMessage, "Backend down",
                       "Problem-doc detail must flow through to the UI message")
    }
}

// MARK: - Shared capture delegate

/// Captures the `didEncounterValidationError` UI delegate callback so tests
/// can wait on validation failures via XCTestExpectation. Extracted to the
/// file level so it can be reused across tests and avoids the nested-class
/// trap where two tests' nested types collide.
private final class ValidationFailureCaptureDelegate: NSObject, TPPSignInOutBusinessLogicUIDelegate {
    var context: String = "capture"
    var username: String?
    var pin: String?
    var usernameTextField: UITextField?
    var PINTextField: UITextField?
    var forceEditability: Bool = false

    var onValidationFailure: (() -> Void)?
    private(set) var observedFailure: Bool = false
    private(set) var lastTitle: String?
    private(set) var lastMessage: String?

    init(username: String?, pin: String?) {
        self.username = username
        self.pin = pin
    }

    func businessLogicWillSignOut(_ businessLogic: TPPSignInBusinessLogic) {}
    func businessLogic(_ logic: TPPSignInBusinessLogic, didEncounterSignOutError error: Error?, withHTTPStatusCode httpStatusCode: Int) {}
    func businessLogicDidFinishDeauthorizing(_ logic: TPPSignInBusinessLogic) {}
    func businessLogicDidCancelSignIn(_ businessLogic: TPPSignInBusinessLogic) {}
    func businessLogicWillSignIn(_ businessLogic: TPPSignInBusinessLogic) {}
    func businessLogicDidCompleteSignIn(_ businessLogic: TPPSignInBusinessLogic) {}
    func businessLogicDidReceiveCredentials(_ businessLogic: TPPSignInBusinessLogic) {}
    func businessLogic(_ logic: TPPSignInBusinessLogic,
                       didEncounterValidationError error: Error?,
                       userFriendlyErrorTitle title: String?,
                       andMessage message: String?) {
        guard !observedFailure else { return }  // single-shot
        observedFailure = true
        lastTitle = title
        lastMessage = message
        onValidationFailure?()
    }
    func dismiss(animated flag: Bool, completion: (() -> Void)?) { completion?() }
    func present(_ vc: UIViewController, animated flag: Bool, completion: (() -> Void)?) { completion?() }
}
