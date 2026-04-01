//
//  TokenRefreshInterceptorTests.swift
//  PalaceTests
//
//  Unit tests for TokenRefreshInterceptor: 401 handling, SAML re-auth,
//  sign-in triggers, borrow credential handling, and problem documents.
//

import XCTest
import Combine
@testable import Palace

// MARK: - Mock Delegate

final class MockTokenRefreshDelegate: TokenRefreshInterceptorDelegate {
    let bookRegistry: TPPBookRegistryProvider
    let userAccount: TPPUserAccount
    let stateManager: DownloadStateManager
    let progressReporter: DownloadProgressReporter

    var startDownloadCalls: [(book: TPPBook, request: URLRequest?)] = []
    var startBorrowCalls: [(book: TPPBook, attemptDownload: Bool)] = []
    var failDownloadCalls: [(book: TPPBook, message: String?)] = []
    var alertForProblemCalls: [(problemDoc: TPPProblemDocument?, error: Error?, book: TPPBook)] = []
    var borrowCompletions: [(() -> Void)?] = []

    init(
        bookRegistry: TPPBookRegistryProvider = TPPBookRegistryMock(),
        userAccount: TPPUserAccount = TPPUserAccountMock()
    ) {
        self.bookRegistry = bookRegistry
        self.userAccount = userAccount
        self.stateManager = DownloadStateManager()
        self.progressReporter = DownloadProgressReporter(
            accessibilityAnnouncements: TPPAccessibilityAnnouncementCenter(
                postHandler: { _, _ in },
                isVoiceOverRunning: { false }
            )
        )
    }

    func startDownload(for book: TPPBook, withRequest request: URLRequest?) {
        startDownloadCalls.append((book: book, request: request))
    }

    func startBorrow(for book: TPPBook, attemptDownload: Bool, borrowCompletion: (() -> Void)?) {
        startBorrowCalls.append((book: book, attemptDownload: attemptDownload))
        borrowCompletions.append(borrowCompletion)
    }

    func failDownloadWithAlert(for book: TPPBook, withMessage message: String?) {
        failDownloadCalls.append((book: book, message: message))
    }

    func alertForProblemDocument(_ problemDoc: TPPProblemDocument?, error: Error?, book: TPPBook) {
        alertForProblemCalls.append((problemDoc: problemDoc, error: error, book: book))
    }
}

// MARK: - Authentication Test Helper

/// Creates an AccountDetails.Authentication from JSON for test purposes.
/// The Authentication class only has Codable/NSCoding init, so we must
/// construct test instances via JSON decoding.
private func makeAuthDefinition(
    authType: AccountDetails.AuthType,
    needsAuth: Bool = true
) -> AccountDetails.Authentication? {
    let json: [String: Any] = [
        "authType": authType.rawValue,
        "authPasscodeLength": 99,
        "patronIDKeyboard": 0,  // .standard
        "pinKeyboard": 0,       // .standard
        "supportsBarcodeScanner": false,
        "supportsBarcodeDisplay": false
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: json) else { return nil }
    return try? JSONDecoder().decode(AccountDetails.Authentication.self, from: data)
}

// MARK: - Tests

@MainActor
final class TokenRefreshInterceptorTests: XCTestCase {

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
        interceptor = TokenRefreshInterceptor(reauthenticator: mockReauthenticator)
        interceptor.delegate = mockDelegate
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

    // MARK: - Initialization

    func testInit_defaultState() {
        let fresh = TokenRefreshInterceptor()
        XCTAssertNotNil(fresh.reauthenticator)
    }

    func testInit_withCustomReauthenticator() {
        let custom = TPPReauthenticatorMock()
        let interceptor = TokenRefreshInterceptor(reauthenticator: custom)
        XCTAssertTrue(interceptor.reauthenticator === custom)
    }

    // MARK: - handleDownloadFailureWithAuthCheck

    func testHandleDownloadFailure_noDelegateReturnsFalse() {
        interceptor.delegate = nil
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let task = URLSession.shared.downloadTask(with: URL(string: "https://example.com")!)

        let result = interceptor.handleDownloadFailureWithAuthCheck(
            for: book, task: task, problemDoc: nil, failureError: nil
        )

        XCTAssertFalse(result)
    }

    func testHandleDownloadFailure_noCredentialsLoginRequired_triggersSignIn() {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let task = URLSession.shared.downloadTask(with: URL(string: "https://example.com")!)

        // Setup: no credentials, login required (basic auth needs auth)
        mockUserAccount._credentials = nil
        mockUserAccount._authDefinition = makeAuthDefinition(authType: .basic)

        let result = interceptor.handleDownloadFailureWithAuthCheck(
            for: book, task: task, problemDoc: nil, failureError: nil
        )

        XCTAssertTrue(result, "Should trigger sign-in when no credentials and login required")
        XCTAssertTrue(mockReauthenticator.authenticateIfNeededCalled)
    }

    func testHandleDownloadFailure_noActiveLoan_nonSAML_autoBorrows() {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        mockRegistry.addBook(book, state: .downloading)

        let task = URLSession.shared.downloadTask(with: URL(string: "https://example.com")!)

        let problemDoc = TPPProblemDocument.fromDictionary([
            "type": TPPProblemDocument.TypeNoActiveLoan,
            "title": "No Active Loan",
            "status": 404,
            "detail": "No active loan found"
        ])

        // Non-SAML, has credentials
        mockUserAccount._credentials = .barcodeAndPin(barcode: "user", pin: "pin")
        mockUserAccount._authDefinition = makeAuthDefinition(authType: .basic)

        let result = interceptor.handleDownloadFailureWithAuthCheck(
            for: book, task: task, problemDoc: problemDoc, failureError: nil
        )

        XCTAssertTrue(result, "Should auto-borrow on 'no active loan' for non-SAML")
        // Verify registry state was set to unregistered before re-borrow
        XCTAssertEqual(mockRegistry.state(for: book.identifier), .unregistered)
        XCTAssertEqual(mockDelegate.startBorrowCalls.count, 1)
        XCTAssertTrue(mockDelegate.startBorrowCalls.first?.attemptDownload == true)
    }

    func testHandleDownloadFailure_nonAuthRelatedError_returnsFalse() {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let task = URLSession.shared.downloadTask(with: URL(string: "https://example.com")!)

        // Has credentials, anonymous auth (needsAuth is false)
        mockUserAccount._credentials = .barcodeAndPin(barcode: "user", pin: "pin")
        mockUserAccount._authDefinition = makeAuthDefinition(authType: .anonymous, needsAuth: false)

        let result = interceptor.handleDownloadFailureWithAuthCheck(
            for: book, task: task, problemDoc: nil, failureError: nil
        )

        XCTAssertFalse(result, "Non-auth error should return false")
    }

    // MARK: - handleBorrowInvalidCredentials

    func testHandleBorrowInvalidCredentials_firstAttempt_triggersReauth() {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        mockUserAccount._credentials = nil

        let expectation = XCTestExpectation(description: "Reauth triggered")
        mockReauthenticator.onAuthenticate = { _, _ in
            expectation.fulfill()
        }

        interceptor.handleBorrowInvalidCredentials(for: book, error: nil)

        wait(for: [expectation], timeout: 2.0)
        XCTAssertEqual(mockReauthenticator.authenticateCallCount, 1)
    }

    func testHandleBorrowInvalidCredentials_secondAttempt_showsAlert() {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)

        // First call triggers reauth
        let firstExpectation = XCTestExpectation(description: "First reauth")
        mockReauthenticator.onAuthenticate = { _, _ in
            firstExpectation.fulfill()
        }
        interceptor.handleBorrowInvalidCredentials(for: book, error: nil)
        wait(for: [firstExpectation], timeout: 2.0)

        // Second call should show alert instead of reauth
        let secondExpectation = XCTestExpectation(description: "Second attempt")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.interceptor.handleBorrowInvalidCredentials(for: book, error: nil)
            secondExpectation.fulfill()
        }
        wait(for: [secondExpectation], timeout: 2.0)

        // Should only have reauthenticated once
        XCTAssertEqual(mockReauthenticator.authenticateCallCount, 1)
    }

    func testHandleBorrowInvalidCredentials_successfulReauth_startsDownload() {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)

        // Setup: reauthenticator grants credentials on the mock user account
        mockReauthenticator.onAuthenticate = { [weak self] user, _ in
            guard let mock = self?.mockUserAccount else { return }
            mock.setAuthToken("newtoken", barcode: "user", pin: "pin", expirationDate: nil)
        }

        let expectation = XCTestExpectation(description: "Download started after reauth")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if !self.mockDelegate.startDownloadCalls.isEmpty {
                expectation.fulfill()
            }
        }

        interceptor.handleBorrowInvalidCredentials(for: book, error: nil)
        wait(for: [expectation], timeout: 3.0)

        XCTAssertEqual(mockDelegate.startDownloadCalls.count, 1)
        XCTAssertEqual(mockDelegate.startDownloadCalls.first?.book.identifier, book.identifier)
    }

    // MARK: - handleProblem

    func testHandleProblem_noCredentials_triggersReauth() {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        mockRegistry.addBook(book, state: .downloading)

        mockUserAccount._credentials = nil
        mockUserAccount._authDefinition = makeAuthDefinition(authType: .basic)

        let expectation = XCTestExpectation(description: "Reauth triggered")
        mockReauthenticator.onAuthenticate = { _, _ in
            expectation.fulfill()
        }

        interceptor.handleProblem(for: book, problemDocument: nil)

        wait(for: [expectation], timeout: 2.0)
        XCTAssertTrue(mockReauthenticator.authenticateIfNeededCalled)
        XCTAssertEqual(mockRegistry.state(for: book.identifier), .downloadNeeded)
    }

    func testHandleProblem_SAMLStartedState_circuitBreaker() {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        mockRegistry.addBook(book, state: .SAMLStarted)

        mockUserAccount._credentials = .barcodeAndPin(barcode: "user", pin: "pin")

        let expectation = XCTestExpectation(description: "Circuit breaker triggers reauth")
        mockReauthenticator.onAuthenticate = { _, _ in
            expectation.fulfill()
        }

        interceptor.handleProblem(for: book, problemDocument: nil)

        wait(for: [expectation], timeout: 3.0)
        XCTAssertTrue(mockReauthenticator.authenticateIfNeededCalled)
    }

    func testHandleProblem_SAMLWithCredentials_retriesWithSAML() {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        mockRegistry.addBook(book, state: .downloading)

        mockUserAccount._credentials = .barcodeAndPin(barcode: "user", pin: "pin")
        mockUserAccount._authDefinition = makeAuthDefinition(authType: .saml)

        interceptor.handleProblem(for: book, problemDocument: nil)

        let expectation = XCTestExpectation(description: "SAML retry")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if !self.mockDelegate.startDownloadCalls.isEmpty {
                expectation.fulfill()
            }
        }
        wait(for: [expectation], timeout: 2.0)

        XCTAssertEqual(mockDelegate.startDownloadCalls.count, 1)
        XCTAssertEqual(mockRegistry.state(for: book.identifier), .SAMLStarted)
    }

    func testHandleProblem_authenticatedUser_noReauth() {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        mockRegistry.addBook(book, state: .downloading)

        // Has credentials, non-SAML, not in SAMLStarted state
        mockUserAccount._credentials = .barcodeAndPin(barcode: "user", pin: "pin")
        mockUserAccount._authDefinition = makeAuthDefinition(authType: .basic)

        interceptor.handleProblem(for: book, problemDocument: nil)

        let expectation = XCTestExpectation(description: "Wait")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        // Should NOT trigger reauth for authenticated basic user
        XCTAssertFalse(mockReauthenticator.authenticateIfNeededCalled)
        XCTAssertEqual(mockRegistry.state(for: book.identifier), .downloadNeeded)
    }

    // MARK: - Delegate Nil Safety

    func testHandleProblem_nilDelegate_doesNotCrash() {
        interceptor.delegate = nil
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        interceptor.handleProblem(for: book, problemDocument: nil)
    }

    func testHandleBorrowInvalidCredentials_nilDelegate_doesNotCrash() {
        interceptor.delegate = nil
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        interceptor.handleBorrowInvalidCredentials(for: book, error: nil)
    }

    // MARK: - handleDownloadFailure with noActiveLoan + SAML

    func testHandleDownloadFailure_noActiveLoan_SAML_treatAsSessionExpiry() {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        mockRegistry.addBook(book, state: .downloading)

        let task = URLSession.shared.downloadTask(with: URL(string: "https://example.com")!)

        let problemDoc = TPPProblemDocument.fromDictionary([
            "type": TPPProblemDocument.TypeNoActiveLoan,
            "title": "No Active Loan",
            "status": 404
        ])

        // SAML with credentials - should treat as session expiry
        mockUserAccount._credentials = .barcodeAndPin(barcode: "user", pin: "pin")
        mockUserAccount._authDefinition = makeAuthDefinition(authType: .saml)

        let result = interceptor.handleDownloadFailureWithAuthCheck(
            for: book, task: task, problemDoc: problemDoc, failureError: nil
        )

        XCTAssertTrue(result, "SAML + no-active-loan should be treated as session expiry")
    }

    // MARK: - handleDownloadFailure with no problem doc and no auth issue

    func testHandleDownloadFailure_hasCredentials_noLoginRequired_returnsFalse() {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let task = URLSession.shared.downloadTask(with: URL(string: "https://example.com")!)

        mockUserAccount._credentials = .barcodeAndPin(barcode: "user", pin: "pin")
        // No auth definition at all
        mockUserAccount._authDefinition = nil

        let result = interceptor.handleDownloadFailureWithAuthCheck(
            for: book, task: task, problemDoc: nil, failureError: nil
        )

        XCTAssertFalse(result)
        XCTAssertFalse(mockReauthenticator.authenticateIfNeededCalled)
    }
}
