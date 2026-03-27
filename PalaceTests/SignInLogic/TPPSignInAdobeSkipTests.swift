//
//  TPPSignInAdobeSkipTests.swift
//  PalaceTests
//
//  Tests for Adobe DRM activation skip logic and state machine transitions
//

import XCTest
@testable import Palace

/// SRS: DRM-001 - Adobe DRM activation skip logic prevents burning device activations
final class TPPSignInAdobeSkipTests: XCTestCase {

    private var businessLogic: TPPSignInBusinessLogic!
    private var libraryAccountMock: TPPLibraryAccountMock!
    private var drmAuthorizer: TPPDRMAuthorizingMock!
    private var uiDelegate: TPPSignInOutBusinessLogicUIDelegateMock!
    private var networkExecutor: TPPRequestExecutorMock!
    private var bookRegistry: TPPBookRegistryMock!
    private var downloadCenter: TPPMyBooksDownloadsCenterMock!

    override func setUpWithError() throws {
        try super.setUpWithError()
        libraryAccountMock = TPPLibraryAccountMock()
        drmAuthorizer = TPPDRMAuthorizingMock()
        uiDelegate = TPPSignInOutBusinessLogicUIDelegateMock()
        networkExecutor = TPPRequestExecutorMock()
        bookRegistry = TPPBookRegistryMock()
        downloadCenter = TPPMyBooksDownloadsCenterMock()

        businessLogic = TPPSignInBusinessLogic(
            libraryAccountID: libraryAccountMock.tppAccountUUID,
            libraryAccountsProvider: libraryAccountMock,
            urlSettingsProvider: TPPURLSettingsProviderMock(),
            bookRegistry: bookRegistry,
            bookDownloadsCenter: downloadCenter,
            userAccountProvider: TPPUserAccountMock.self,
            networkExecutor: networkExecutor,
            uiDelegate: uiDelegate,
            drmAuthorizer: drmAuthorizer
        )
    }

    override func tearDownWithError() throws {
        networkExecutor.reset()
        businessLogic.userAccount.removeAll()
        businessLogic = nil
        libraryAccountMock = nil
        drmAuthorizer = nil
        uiDelegate = nil
        networkExecutor = nil
        bookRegistry = nil
        downloadCenter = nil
        try super.tearDownWithError()
    }

    // MARK: - shouldSkipAdobeActivation Tests

    /// SRS: DRM-004 - When auth state is not credentialsStale, never skip activation
    func testShouldSkipAdobeActivation_falseWhenNotStale() {
        // Default state is not credentialsStale
        XCTAssertFalse(businessLogic.shouldSkipAdobeActivation(),
                       "Should not skip activation when auth state is not credentialsStale")
    }

    /// SRS: DRM-004 - Without existing Adobe credentials, cannot skip activation
    func testShouldSkipAdobeActivation_falseWithoutAdobeCredentials() {
        // Even if state were stale, no userID/deviceID means cannot skip
        XCTAssertNil(businessLogic.userAccount.userID)
        XCTAssertNil(businessLogic.userAccount.deviceID)
        XCTAssertFalse(businessLogic.shouldSkipAdobeActivation())
    }

    // MARK: - Credential Capture Tests

    /// Tests that logIn captures barcode and PIN from uiDelegate
    func testLogIn_capturesBarcodeAndPIN() {
        uiDelegate.username = "test-barcode-123"
        uiDelegate.pin = "test-pin-456"
        businessLogic.selectedAuthentication = libraryAccountMock.barcodeAuthentication

        businessLogic.logIn()

        XCTAssertEqual(businessLogic.capturedBarcode, "test-barcode-123",
                       "logIn should capture barcode from uiDelegate")
        XCTAssertEqual(businessLogic.capturedPin, "test-pin-456",
                       "logIn should capture PIN from uiDelegate")
    }

    func testLogIn_capturedBarcode_nilWhenUIDelegateHasNilUsername() {
        uiDelegate.username = nil
        uiDelegate.pin = nil
        businessLogic.selectedAuthentication = libraryAccountMock.barcodeAuthentication

        businessLogic.logIn()

        XCTAssertNil(businessLogic.capturedBarcode)
        XCTAssertNil(businessLogic.capturedPin)
    }

    // MARK: - ensureAuthenticationDocumentIsLoaded Tests

    func testEnsureAuthDocLoaded_callsCompletionImmediatelyWhenDetailsExist() {
        // libraryAccountMock's tppAccount already has details loaded
        let expectation = expectation(description: "Completion called")

        businessLogic.ensureAuthenticationDocumentIsLoaded { success in
            XCTAssertTrue(success)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
    }

    func testEnsureAuthDocLoaded_setsLoadingFlag() {
        XCTAssertFalse(businessLogic.isAuthenticationDocumentLoading)
        // When details exist, it returns immediately without setting the flag
        businessLogic.ensureAuthenticationDocumentIsLoaded { _ in }
        // Since details exist, it should NOT set loading to true
        XCTAssertFalse(businessLogic.isAuthenticationDocumentLoading)
    }

    // MARK: - refreshAuthIfNeeded Tests

    /// SRS: DRM-001 - Refresh auth returns false when no auth definition exists
    func testRefreshAuthIfNeeded_returnsFalseWithNoAuthDefinition() {
        var completionCalled = false
        let result = businessLogic.refreshAuthIfNeeded(usingExistingCredentials: false) {
            completionCalled = true
        }

        XCTAssertFalse(result, "Should return false when no auth definition")
        XCTAssertTrue(completionCalled, "Completion should be called immediately")
    }

    func testRefreshAuthIfNeeded_setsRefreshAuthCompletion() {
        // Set up auth definition
        businessLogic.selectedAuthentication = libraryAccountMock.barcodeAuthentication
        businessLogic.updateUserAccount(
            forDRMAuthorization: true,
            withBarcode: "barcode",
            pin: "pin",
            authToken: nil,
            expirationDate: nil,
            patron: nil,
            cookies: nil
        )

        var completionCalled = false
        _ = businessLogic.refreshAuthIfNeeded(usingExistingCredentials: true) {
            completionCalled = true
        }

        // The completion should be stored as refreshAuthCompletion
        // (it gets called later after validation completes)
        XCTAssertNotNil(businessLogic.refreshAuthCompletion)
    }

    // MARK: - ignoreSignedInState Tests

    func testIgnoreSignedInState_affectsIsSignedIn() {
        // Sign in
        businessLogic.selectedAuthentication = libraryAccountMock.barcodeAuthentication
        businessLogic.updateUserAccount(
            forDRMAuthorization: true,
            withBarcode: "barcode",
            pin: "pin",
            authToken: nil,
            expirationDate: nil,
            patron: nil,
            cookies: nil
        )
        XCTAssertTrue(businessLogic.isSignedIn())

        // Set ignoreSignedInState
        businessLogic.ignoreSignedInState = true
        XCTAssertFalse(businessLogic.isSignedIn(),
                       "isSignedIn should return false when ignoreSignedInState is true")
    }

    // MARK: - logIn with different auth types

    func testLogIn_withNoSelectedAuth_doesNotCrash() {
        businessLogic.selectedAuthentication = nil
        businessLogic.logIn()
        // Should return early without crash
        XCTAssertFalse(businessLogic.isValidatingCredentials)
    }

    func testLogIn_postsSigningInNotification() {
        let expectation = expectation(
            forNotification: .TPPIsSigningIn,
            object: nil
        ) { notification in
            if let isSigningIn = notification.object as? Bool {
                return isSigningIn == true
            }
            return false
        }

        businessLogic.selectedAuthentication = libraryAccountMock.barcodeAuthentication
        businessLogic.logIn()

        wait(for: [expectation], timeout: 1.0)
    }

    func testLogIn_notifiesUIDelegateWillSignIn() {
        businessLogic.selectedAuthentication = libraryAccountMock.barcodeAuthentication
        businessLogic.logIn()

        // businessLogicWillSignIn is called on main thread async
        let expectation = expectation(description: "UI delegate notified")
        DispatchQueue.main.async {
            XCTAssertTrue(self.uiDelegate.didCallWillSignIn)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    // MARK: - makeRequest Edge Cases

    func testMakeRequest_withOAuthButNoToken_logsError() {
        businessLogic.selectedAuthentication = libraryAccountMock.oauthAuthentication
        businessLogic.authToken = nil
        // userAccount also has no authToken by default

        let request = businessLogic.makeRequest(for: .signIn, context: "test")

        // Request should still be created (just without Bearer header)
        XCTAssertNotNil(request)
        let authHeader = request?.value(forHTTPHeaderField: "Authorization")
        XCTAssertNil(authHeader, "No auth header when no token available")
    }

    func testMakeRequest_prefersBusinessLogicToken_overUserAccountToken() {
        businessLogic.selectedAuthentication = libraryAccountMock.oauthAuthentication
        businessLogic.authToken = "fresh-token"

        // Set up user account with a different token
        businessLogic.updateUserAccount(
            forDRMAuthorization: true,
            withBarcode: nil,
            pin: nil,
            authToken: "old-token",
            expirationDate: nil,
            patron: nil,
            cookies: nil
        )

        let request = businessLogic.makeRequest(for: .signIn, context: "test")
        let authHeader = request?.value(forHTTPHeaderField: "Authorization")

        XCTAssertEqual(authHeader, "Bearer fresh-token",
                       "Should prefer business logic authToken over user account token")
    }
}
