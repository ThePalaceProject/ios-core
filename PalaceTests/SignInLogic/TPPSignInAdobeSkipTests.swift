//
//  TPPSignInAdobeSkipTests.swift
//  PalaceTests
//
//  Tests for Adobe DRM activation skip logic and state machine transitions
//

import XCTest
@testable import Palace

/// SRS: DRM-001 - Adobe DRM activation skip logic prevents burning device activations
@MainActor
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
        // Every non-stale auth state must refuse the skip. If this regressed
        // (e.g. .loggedIn started skipping), fresh sign-ins would silently
        // reuse stale Adobe credentials and the user would see DRM errors on
        // every book open until the device was re-authorized.
        let userAccountMock = businessLogic.userAccount as! TPPUserAccountMock

        for state in [TPPAccountAuthState.loggedOut, .loggedIn] {
            userAccountMock.setAuthState(state)
            XCTAssertFalse(businessLogic.shouldSkipAdobeActivation(),
                           "Must not skip activation in \(state) state (only credentialsStale may skip)")
        }
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

        // Force ignoreSignedInState via the same reducer action production uses
        // when refreshAuth fires for a SAML browser flow without cached creds.
        businessLogic.dispatch(.refreshAuthStarted(authType: .saml, usingExistingCredentials: false))
        XCTAssertFalse(businessLogic.isSignedIn(),
                       "isSignedIn should return false when ignoreSignedInState is true")
    }

    // MARK: - logIn with different auth types

    func testLogIn_withNoSelectedAuth_doesNotCrash() {
        // logIn must early-return when no auth method is selected — attempting
        // a login without knowing which method to use would send blank creds.
        // Verify both the early-return contract (no validation kicked off) and
        // that no sign-in notification was posted downstream.
        var signInNotificationPosted = false
        let observer = NotificationCenter.default.addObserver(
            forName: .TPPIsSigningIn, object: nil, queue: nil
        ) { _ in signInNotificationPosted = true }
        defer { NotificationCenter.default.removeObserver(observer) }

        businessLogic.selectedAuthentication = nil
        businessLogic.logIn()

        XCTAssertFalse(businessLogic.isValidatingCredentials,
                       "logIn without a selected auth must not enter the validating state")
        XCTAssertFalse(signInNotificationPosted,
                       "logIn without a selected auth must not post TPPIsSigningIn")
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
        XCTAssertTrue(businessLogic.isValidatingCredentials,
                      "logIn() must leave the business logic in validating state after the notification")
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
        // AuthState starts with authToken == nil; userAccount also has no token by default

        let request = businessLogic.makeRequest(for: .signIn, context: "test")

        // Request should still be created (just without Bearer header)
        XCTAssertNotNil(request)
        let authHeader = request?.value(forHTTPHeaderField: "Authorization")
        XCTAssertNil(authHeader, "No auth header when no token available")
    }

    func testMakeRequest_prefersBusinessLogicToken_overUserAccountToken() {
        // Production path during sign-in: OAuth handler dispatches the fresh
        // token via `.bearerTokenReceived` before `updateUserAccount` has
        // written it to the keychain. `makeRequest` must surface this fresh
        // token (in-flight) — falling back to a stale `userAccount.authToken`
        // would attach the previous session's bearer token to the new request.
        businessLogic.selectedAuthentication = libraryAccountMock.oauthAuthentication

        // Seed userAccount directly (no updateUserAccount, which would dispatch
        // .userAccountUpdated and clear the in-flight reducer state).
        businessLogic.userAccount.setAuthToken("old-token", barcode: nil, pin: nil, expirationDate: nil)
        businessLogic.dispatch(.bearerTokenReceived(token: "fresh-token", expiration: nil))

        let request = businessLogic.makeRequest(for: .signIn, context: "test")
        let authHeader = request?.value(forHTTPHeaderField: "Authorization")

        XCTAssertEqual(authHeader, "Bearer fresh-token",
                       "Should prefer in-flight authToken over the previously persisted userAccount token")
    }
}
