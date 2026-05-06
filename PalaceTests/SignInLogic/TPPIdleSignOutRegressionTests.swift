//
//  TPPIdleSignOutRegressionTests.swift
//  PalaceTests
//
//  Regression tests for PP-3819: Device gets into weird state after being
//  left idle.
//
//  Root cause: After the app is idle for hours, the auth token expires.
//  When the user then signs out, the server returns 401. The previous code:
//  1. Called removeAll() prematurely, wiping the licensor before DRM
//     deauthorization could use it.
//  2. Called removeAll() a second time in completeLogOutProcess(), causing
//     double notifications and UI state corruption (disappearing tab bar).
//  3. Showed a confusing "Unexpected Credentials" error for the expected 401.
//  4. Had a race condition: the async DRM deauthorization callback could fire
//     after the user had already re-authenticated, wiping their fresh
//     credentials and breaking borrow/read functionality.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

// MARK: - PP-3819 Regression Tests

final class TPPIdleSignOutRegressionTests: XCTestCase {

    private var businessLogic: TPPSignInBusinessLogic!
    private var libraryMock: TPPLibraryAccountMock!
    private var drmAuthorizer: TPPDRMAuthorizingMock!
    private var uiDelegate: TPPSignInOutBusinessLogicUIDelegateMock!
    private var networkExecutor: TPPRequestExecutorMock!
    private var bookRegistry: TPPBookRegistryMock!
    private var downloadCenter: TPPMyBooksDownloadsCenterMock!

    override func setUp() {
        super.setUp()
        TPPUserAccountMock.resetShared()
        libraryMock = TPPLibraryAccountMock()
        drmAuthorizer = TPPDRMAuthorizingMock()
        uiDelegate = TPPSignInOutBusinessLogicUIDelegateMock()
        networkExecutor = TPPRequestExecutorMock()
        bookRegistry = TPPBookRegistryMock()
        downloadCenter = TPPMyBooksDownloadsCenterMock()

        businessLogic = TPPSignInBusinessLogic(
            libraryAccountID: libraryMock.tppAccountUUID,
            libraryAccountsProvider: libraryMock,
            urlSettingsProvider: TPPURLSettingsProviderMock(),
            bookRegistry: bookRegistry,
            bookDownloadsCenter: downloadCenter,
            userAccountProvider: TPPUserAccountMock.self,
            networkExecutor: networkExecutor,
            uiDelegate: uiDelegate,
            drmAuthorizer: drmAuthorizer
        )
    }

    override func tearDown() {
        networkExecutor.reset()
        businessLogic.userAccount.removeAll()
        businessLogic = nil
        libraryMock = nil
        drmAuthorizer = nil
        uiDelegate = nil
        networkExecutor = nil
        bookRegistry = nil
        downloadCenter = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func signInUser(barcode: String = "01230000000128",
                            pin: String = "testpin") {
        businessLogic.selectedAuthentication = libraryMock.barcodeAuthentication
        businessLogic.updateUserAccount(
            forDRMAuthorization: true,
            withBarcode: barcode,
            pin: pin,
            authToken: nil,
            expirationDate: nil,
            patron: ["name": "Test Patron"],
            cookies: nil
        )
        // Simulate DRM licensor saved during sign-in
        businessLogic.userAccount.setLicensor([
            "vendor": "test-vendor",
            "clientToken": "test-user|test-password"
        ])
    }

    private func signInUserWithToken(token: String = "oauth-token") {
        businessLogic.selectedAuthentication = libraryMock.oauthAuthentication
        businessLogic.updateUserAccount(
            forDRMAuthorization: true,
            withBarcode: nil,
            pin: nil,
            authToken: token,
            expirationDate: Date().addingTimeInterval(3600),
            patron: ["name": "OAuth Patron"],
            cookies: nil
        )
    }

    // MARK: - Test: 401 on sign-out does NOT show "Unexpected Credentials" error

    /// PP-3819: When the sign-out request returns 401 (token expired during
    /// idle), we should proceed with local cleanup silently instead of showing
    /// the confusing "Unexpected Credentials" error dialog.
    func testSignOut401_doesNotShowUnexpectedCredentialsError() {
        signInUser()
        XCTAssertTrue(businessLogic.userAccount.hasCredentials())

        networkExecutor.forceFailureStatusCode = 401

        let exp = expectation(description: "Sign-out completes")
        uiDelegate.didFinishDeauthorizingHandler = { exp.fulfill() }

        businessLogic.performLogOut()
        wait(for: [exp], timeout: 5.0)

        XCTAssertFalse(uiDelegate.didCallSignOutError,
                       "401 on sign-out should NOT trigger error callback — it's expected after idle")
        XCTAssertNil(uiDelegate.lastSignOutErrorHTTPStatusCode,
                     "No error status code should be reported for expected 401")
    }

    /// Non-401 errors (e.g. 500) should still show an error to the user.
    func testSignOut500_showsErrorToUser() {
        signInUser()
        networkExecutor.forceFailureStatusCode = 500

        let exp = expectation(description: "Sign-out completes")
        uiDelegate.didFinishDeauthorizingHandler = { exp.fulfill() }

        businessLogic.performLogOut()
        wait(for: [exp], timeout: 5.0)

        XCTAssertTrue(uiDelegate.didCallSignOutError,
                      "Non-401 errors should still show error to user")
        XCTAssertEqual(uiDelegate.lastSignOutErrorHTTPStatusCode, 500)
    }

    // MARK: - Test: 401 sign-out still clears credentials

    /// Even though we don't show an error, the user's credentials must be
    /// fully cleared after a 401 sign-out.
    func testSignOut401_clearsCredentials() {
        signInUser()
        XCTAssertTrue(businessLogic.userAccount.hasCredentials(),
                      "Precondition: user should be signed in")

        networkExecutor.forceFailureStatusCode = 401

        let exp = expectation(description: "Sign-out completes")
        uiDelegate.didFinishDeauthorizingHandler = { exp.fulfill() }

        businessLogic.performLogOut()
        wait(for: [exp], timeout: 5.0)

        XCTAssertFalse(businessLogic.userAccount.hasCredentials(),
                       "Credentials should be cleared after 401 sign-out")
        XCTAssertTrue(uiDelegate.didCallDidFinishDeauthorizing,
                      "businessLogicDidFinishDeauthorizing should be called")
    }

    // MARK: - Test: No premature removeAll (single cleanup)

    /// PP-3819: The previous code called removeAll() in the failure handler
    /// and then again in completeLogOutProcess(). This caused double
    /// notifications that corrupted UI state (disappearing tab bar).
    /// With the fix, removeAll() is only called once in completeLogOutProcess().
    func testSignOut401_deauthorizesDeviceWithLicensor() {
        signInUser()
        XCTAssertNotNil(businessLogic.userAccount.licensor,
                        "Precondition: licensor should be set")

        networkExecutor.forceFailureStatusCode = 401

        let exp = expectation(description: "Sign-out completes")
        uiDelegate.didFinishDeauthorizingHandler = { exp.fulfill() }

        businessLogic.performLogOut()
        wait(for: [exp], timeout: 5.0)

        XCTAssertTrue(drmAuthorizer.deauthorizeWasCalled,
                      "DRM device deauthorization should be attempted")
        XCTAssertEqual(drmAuthorizer.deauthorizeCallCount, 1,
                       "Deauthorize should be called exactly once")
    }

    // MARK: - Test: Race condition — sign-in during pending DRM deauthorization

    /// PP-3819 CRITICAL: If the user signs back in while the DRM deauthorization
    /// callback is still pending, the stale callback must NOT wipe the new
    /// credentials. This was the primary cause of the "weird state" where
    /// borrow/read stopped working after idle + sign-out + sign-in.
    func testRaceCondition_signInDuringPendingDeauth_preservesNewCredentials() {
        signInUser(barcode: "original-barcode", pin: "original-pin")
        drmAuthorizer.shouldDeferDeauthorize = true
        networkExecutor.forceFailureStatusCode = 401

        // Step 1: Start sign-out — DRM deauth is now pending (deferred)
        businessLogic.performLogOut()

        // Drain the main queue so the network mock processes
        let networkProcessed = expectation(description: "Network response processed")
        DispatchQueue.main.async { networkProcessed.fulfill() }
        wait(for: [networkProcessed], timeout: 2.0)

        XCTAssertTrue(drmAuthorizer.deauthorizeWasCalled,
                      "DRM deauth should have been initiated")
        XCTAssertNotNil(drmAuthorizer.deferredDeauthCompletion,
                        "DRM deauth completion should be deferred")

        // Step 2: User signs back in (via a new business logic instance,
        // simulating the borrow flow's sign-in modal)
        let signInBL = TPPSignInBusinessLogic(
            libraryAccountID: libraryMock.tppAccountUUID,
            libraryAccountsProvider: libraryMock,
            urlSettingsProvider: TPPURLSettingsProviderMock(),
            bookRegistry: bookRegistry,
            bookDownloadsCenter: downloadCenter,
            userAccountProvider: TPPUserAccountMock.self,
            networkExecutor: TPPRequestExecutorMock(),
            uiDelegate: TPPSignInOutBusinessLogicUIDelegateMock(),
            drmAuthorizer: drmAuthorizer
        )
        signInBL.selectedAuthentication = libraryMock.barcodeAuthentication
        signInBL.updateUserAccount(
            forDRMAuthorization: true,
            withBarcode: "new-barcode",
            pin: "new-pin",
            authToken: nil,
            expirationDate: nil,
            patron: ["name": "Re-authenticated Patron"],
            cookies: nil
        )
        signInBL.userAccount.setLicensor([
            "vendor": "new-vendor",
            "clientToken": "new-user|new-password"
        ])
        // Cancel pending sign-out (as finalizeSignIn does in production)
        signInBL.cancelPendingSignOut()

        XCTAssertTrue(signInBL.userAccount.hasCredentials(),
                      "Precondition: new credentials should be saved")

        // Step 3: Now fire the stale DRM deauthorization callback
        let deauthComplete = expectation(description: "Stale deauth processed")
        uiDelegate.didFinishDeauthorizingHandler = { deauthComplete.fulfill() }
        drmAuthorizer.completeDeferredDeauthorize()

        // Drain main queue for the async businessLogicDidFinishDeauthorizing dispatch
        wait(for: [deauthComplete], timeout: 5.0)

        // Step 4: Verify new credentials were NOT wiped
        XCTAssertTrue(businessLogic.userAccount.hasCredentials(),
                      "New credentials must NOT be wiped by stale sign-out")
        XCTAssertEqual(businessLogic.userAccount.barcode, "new-barcode",
                       "New barcode must be preserved")
    }

    // MARK: - Test: Normal sign-out still works

    /// Verify that the guard doesn't prevent normal (non-race) sign-out from
    /// cleaning up credentials.
    func testNormalSignOut_stillClearsCredentials() {
        signInUser()
        XCTAssertTrue(businessLogic.userAccount.hasCredentials())

        let exp = expectation(description: "Sign-out completes")
        uiDelegate.didFinishDeauthorizingHandler = { exp.fulfill() }

        businessLogic.performLogOut()
        wait(for: [exp], timeout: 5.0)

        XCTAssertFalse(businessLogic.userAccount.hasCredentials(),
                       "Normal sign-out should clear credentials")
        XCTAssertTrue(uiDelegate.didCallDidFinishDeauthorizing)
    }

    /// OAuth sign-out after idle (401) also works correctly.
    func testOAuthSignOut401_clearsTokenCredentials() {
        signInUserWithToken(token: "my-oauth-token")
        XCTAssertNotNil(businessLogic.userAccount.authToken)

        networkExecutor.forceFailureStatusCode = 401

        let exp = expectation(description: "OAuth sign-out completes")
        uiDelegate.didFinishDeauthorizingHandler = { exp.fulfill() }

        businessLogic.performLogOut()
        wait(for: [exp], timeout: 5.0)

        XCTAssertFalse(businessLogic.userAccount.hasCredentials(),
                       "OAuth credentials should be cleared")
        XCTAssertNil(businessLogic.userAccount.authToken,
                     "Auth token should be nil after sign-out")
        XCTAssertFalse(uiDelegate.didCallSignOutError,
                       "401 should not trigger error for OAuth either")
    }

    // MARK: - Test: Sign-out → sign-in → borrow cycle

    /// Simulates the full PP-3819 scenario: sign-in → idle → sign-out (401)
    /// → sign-in → verify licensor is available for borrow.
    func testSignOutSignInCycle_licensorPreservedForBorrow() {
        // Initial sign-in with licensor
        signInUser()
        XCTAssertNotNil(businessLogic.userAccount.licensor)

        // Sign out (401 — token expired during idle)
        networkExecutor.forceFailureStatusCode = 401
        let signOutExp = expectation(description: "Sign-out completes")
        uiDelegate.didFinishDeauthorizingHandler = { signOutExp.fulfill() }
        businessLogic.performLogOut()
        wait(for: [signOutExp], timeout: 5.0)

        XCTAssertFalse(businessLogic.userAccount.hasCredentials())

        // Sign back in (user re-authenticates from borrow prompt)
        signInUser(barcode: "re-auth-barcode", pin: "re-auth-pin")

        XCTAssertTrue(businessLogic.userAccount.hasCredentials(),
                      "User should be signed in after re-authentication")
        XCTAssertNotNil(businessLogic.userAccount.licensor,
                        "Licensor should be available for Adobe DRM activation at borrow time")
        XCTAssertEqual(
            businessLogic.userAccount.licensor?["vendor"] as? String,
            "test-vendor",
            "Licensor vendor should match what was saved during sign-in"
        )
    }

    // MARK: - Test: cancelPendingSignOut prevents stale cleanup

    /// Directly tests that cancelPendingSignOut() prevents completeLogOutProcess
    /// from wiping credentials.
    func testCancelPendingSignOut_preventsCredentialCleanup() {
        signInUser()

        // Simulate: sign-out starts, then sign-in cancels it
        drmAuthorizer.shouldDeferDeauthorize = true
        networkExecutor.forceFailureStatusCode = 401

        businessLogic.performLogOut()

        let networkDrained = expectation(description: "Network drained")
        DispatchQueue.main.async { networkDrained.fulfill() }
        wait(for: [networkDrained], timeout: 2.0)

        // Cancel the sign-out (as if user signed back in)
        businessLogic.cancelPendingSignOut()

        // Fire the stale DRM callback
        let deauthDone = expectation(description: "Deauth callback processed")
        uiDelegate.didFinishDeauthorizingHandler = { deauthDone.fulfill() }
        drmAuthorizer.completeDeferredDeauthorize()
        wait(for: [deauthDone], timeout: 5.0)

        // Credentials should still be intact
        XCTAssertTrue(businessLogic.userAccount.hasCredentials(),
                      "cancelPendingSignOut should prevent credential cleanup")
    }

    // MARK: - Test: Multiple rapid sign-out/sign-in cycles

    /// Ensures the guard handles rapid sign-out → sign-in → sign-out correctly.
    func testRapidSignOutSignInCycles_doNotCorruptState() {
        signInUser(barcode: "cycle-1", pin: "pin-1")

        // Cycle 1: Sign out successfully
        let exp1 = expectation(description: "First sign-out")
        uiDelegate.didFinishDeauthorizingHandler = { exp1.fulfill() }
        businessLogic.performLogOut()
        wait(for: [exp1], timeout: 5.0)
        XCTAssertFalse(businessLogic.userAccount.hasCredentials())

        // Cycle 2: Sign in again
        signInUser(barcode: "cycle-2", pin: "pin-2")
        XCTAssertTrue(businessLogic.userAccount.hasCredentials())
        XCTAssertEqual(businessLogic.userAccount.barcode, "cycle-2")

        // Cycle 3: Sign out again with 401
        networkExecutor.forceFailureStatusCode = 401
        let exp2 = expectation(description: "Second sign-out")
        uiDelegate.didFinishDeauthorizingHandler = { exp2.fulfill() }
        businessLogic.performLogOut()
        wait(for: [exp2], timeout: 5.0)
        XCTAssertFalse(businessLogic.userAccount.hasCredentials())

        // Cycle 4: Sign in one more time
        signInUser(barcode: "cycle-3", pin: "pin-3")
        XCTAssertTrue(businessLogic.userAccount.hasCredentials())
        XCTAssertEqual(businessLogic.userAccount.barcode, "cycle-3",
                       "Final credentials should reflect the last sign-in")
    }

    // MARK: - Test: Sign-out with no DRM authorizer

    /// When drmAuthorizer is nil (non-DRM library), sign-out should still
    /// complete normally via completeLogOutProcess().
    func testSignOut_withNoDRMAuthorizer_completes() {
        let noDrmBL = TPPSignInBusinessLogic(
            libraryAccountID: libraryMock.tppAccountUUID,
            libraryAccountsProvider: libraryMock,
            urlSettingsProvider: TPPURLSettingsProviderMock(),
            bookRegistry: bookRegistry,
            bookDownloadsCenter: downloadCenter,
            userAccountProvider: TPPUserAccountMock.self,
            networkExecutor: networkExecutor,
            uiDelegate: uiDelegate,
            drmAuthorizer: nil
        )
        noDrmBL.selectedAuthentication = libraryMock.barcodeAuthentication
        noDrmBL.updateUserAccount(
            forDRMAuthorization: true,
            withBarcode: "no-drm-barcode",
            pin: "pin",
            authToken: nil,
            expirationDate: nil,
            patron: nil,
            cookies: nil
        )

        XCTAssertTrue(noDrmBL.userAccount.hasCredentials())

        let exp = expectation(description: "No-DRM sign-out completes")
        uiDelegate.didFinishDeauthorizingHandler = { exp.fulfill() }

        noDrmBL.performLogOut()
        wait(for: [exp], timeout: 5.0)

        XCTAssertFalse(noDrmBL.userAccount.hasCredentials(),
                       "Credentials should be cleared even without DRM authorizer")
        noDrmBL.userAccount.removeAll()
    }

    // MARK: - Test: businessLogicDidFinishDeauthorizing always called

    /// Regardless of error type or race condition, the UI delegate must always
    /// receive businessLogicDidFinishDeauthorizing so it can reset loading state.
    func testSignOut_alwaysCallsDidFinishDeauthorizing() {
        signInUser()
        networkExecutor.forceFailureStatusCode = 401

        let exp = expectation(description: "Deauthorizing finished")
        uiDelegate.didFinishDeauthorizingHandler = { exp.fulfill() }

        businessLogic.performLogOut()
        wait(for: [exp], timeout: 5.0)

        XCTAssertTrue(uiDelegate.didCallDidFinishDeauthorizing,
                      "businessLogicDidFinishDeauthorizing must always be called")
    }

    /// Even when the stale guard fires, businessLogicDidFinishDeauthorizing
    /// should be called so the UI can reset.
    func testStaleSignOut_stillCallsDidFinishDeauthorizing() {
        signInUser()
        drmAuthorizer.shouldDeferDeauthorize = true
        networkExecutor.forceFailureStatusCode = 401

        businessLogic.performLogOut()

        let networkDrained = expectation(description: "Network drained")
        DispatchQueue.main.async { networkDrained.fulfill() }
        wait(for: [networkDrained], timeout: 2.0)

        businessLogic.cancelPendingSignOut()

        let exp = expectation(description: "Stale deauth finished")
        uiDelegate.didFinishDeauthorizingHandler = { exp.fulfill() }
        drmAuthorizer.completeDeferredDeauthorize()
        wait(for: [exp], timeout: 5.0)

        XCTAssertTrue(uiDelegate.didCallDidFinishDeauthorizing,
                      "businessLogicDidFinishDeauthorizing must be called even for stale sign-outs")
    }
}
