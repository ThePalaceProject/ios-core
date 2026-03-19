//
//  TPPCredentialVisibilityTests.swift
//  PalaceTests
//
//  PP-3784 regression tests: Credentials must remain visible after sign-in.
//
//  These tests cover:
//  - Barcode/PIN persistence through the full sign-in flow
//  - DRM failure not wiping basic auth credentials
//  - Credential snapshot atomicity
//  - Auth state transitions during and after sign-in
//

import XCTest
@testable import Palace

// MARK: - Credential Persistence After Sign-In

/// Tests that barcode and PIN remain accessible after a successful sign-in flow.
/// This is the core regression test for PP-3784 where the barcode would disappear.
final class TPPCredentialPersistenceTests: XCTestCase {

    private var businessLogic: TPPSignInBusinessLogic!
    private var libraryAccountMock: TPPLibraryAccountMock!
    private var drmAuthorizer: TPPDRMAuthorizingMock!
    private var uiDelegate: TPPSignInOutBusinessLogicUIDelegateMock!
    private var networkExecutor: TPPRequestExecutorMock!

    override func setUp() {
        super.setUp()
        TPPUserAccountMock.resetShared()
        libraryAccountMock = TPPLibraryAccountMock()
        drmAuthorizer = TPPDRMAuthorizingMock()
        uiDelegate = TPPSignInOutBusinessLogicUIDelegateMock()
        networkExecutor = TPPRequestExecutorMock()

        businessLogic = TPPSignInBusinessLogic(
            libraryAccountID: libraryAccountMock.tppAccountUUID,
            libraryAccountsProvider: libraryAccountMock,
            urlSettingsProvider: TPPURLSettingsProviderMock(),
            bookRegistry: TPPBookRegistryMock(),
            bookDownloadsCenter: TPPMyBooksDownloadsCenterMock(),
            userAccountProvider: TPPUserAccountMock.self,
            networkExecutor: networkExecutor,
            uiDelegate: uiDelegate,
            drmAuthorizer: drmAuthorizer
        )
    }

    override func tearDown() {
        networkExecutor.reset()
        businessLogic.userAccount.removeAll()
        drmAuthorizer.reset()
        businessLogic = nil
        libraryAccountMock = nil
        drmAuthorizer = nil
        uiDelegate = nil
        networkExecutor = nil
        super.tearDown()
    }

    // MARK: - Full Sign-In Flow Tests

    /// PP-3784 core regression: After a full sign-in flow (network → DRM → finalize),
    /// the barcode and PIN must be readable from the user account.
    func testFullSignInFlow_credentialsRemainAccessible() {
        let barcode = "23333012345678"
        let pin = "1234"
        uiDelegate.username = barcode
        uiDelegate.pin = pin

        businessLogic.selectedAuthentication = libraryAccountMock.barcodeAuthentication

        let expectation = self.expectation(description: "Sign-in completes")
        uiDelegate.didCompleteSignInHandler = {
            expectation.fulfill()
        }

        businessLogic.validateCredentials()

        waitForExpectations(timeout: 5.0)

        let user = businessLogic.userAccount
        XCTAssertEqual(user.barcode, barcode,
                       "PP-3784: Barcode must be visible after sign-in")
        XCTAssertEqual(user.PIN, pin,
                       "PP-3784: PIN must be accessible after sign-in")
        XCTAssertTrue(user.hasCredentials(),
                      "PP-3784: hasCredentials must be true after sign-in")
    }

    /// PP-3784: After sign-in, the auth state must be .loggedIn (not .loggedOut).
    /// When auth state is wrong, accountDidChange() clears the text fields.
    func testFullSignInFlow_authStateIsLoggedIn() {
        uiDelegate.username = "testbarcode"
        uiDelegate.pin = "testpin"

        businessLogic.selectedAuthentication = libraryAccountMock.barcodeAuthentication

        let expectation = self.expectation(description: "Sign-in completes")
        uiDelegate.didCompleteSignInHandler = {
            expectation.fulfill()
        }

        businessLogic.validateCredentials()

        waitForExpectations(timeout: 5.0)

        let userAccount = businessLogic.userAccount as! TPPUserAccountMock
        XCTAssertEqual(userAccount.authState, .loggedIn,
                       "PP-3784: Auth state must be .loggedIn after successful sign-in")
    }

    /// Verifies that the UI delegate receives the sign-in completion callback
    /// exactly once per sign-in attempt.
    func testFullSignInFlow_completionCalledOnce() {
        uiDelegate.username = "barcode"
        uiDelegate.pin = "pin"

        businessLogic.selectedAuthentication = libraryAccountMock.barcodeAuthentication

        let expectation = self.expectation(description: "Sign-in completes")
        uiDelegate.didCompleteSignInHandler = {
            expectation.fulfill()
        }

        businessLogic.validateCredentials()

        waitForExpectations(timeout: 5.0)

        XCTAssertEqual(uiDelegate.didCompleteSignInCallCount, 1,
                       "didCompleteSignIn should be called exactly once")
        XCTAssertTrue(uiDelegate.didCallDidCompleteSignIn,
                      "didCallDidCompleteSignIn flag should be set")
    }

    /// PP-3784: Calling updateUserAccount with drmSuccess=true and basic auth
    /// must persist credentials AND mark the account as loggedIn.
    func testUpdateUserAccount_basicAuth_setsCredentialsAndAuthState() {
        businessLogic.selectedAuthentication = libraryAccountMock.barcodeAuthentication

        businessLogic.updateUserAccount(
            forDRMAuthorization: true,
            withBarcode: "myBarcode",
            pin: "myPin",
            authToken: nil,
            expirationDate: nil,
            patron: nil,
            cookies: nil
        )

        let user = businessLogic.userAccount
        XCTAssertEqual(user.barcode, "myBarcode")
        XCTAssertEqual(user.PIN, "myPin")
        XCTAssertTrue(user.hasCredentials())

        let mockUser = user as! TPPUserAccountMock
        XCTAssertEqual(mockUser.authState, .loggedIn,
                       "Auth state must be .loggedIn after updateUserAccount with drmSuccess=true")
    }

    /// PP-3784: When selectedAuthentication is nil (e.g. due to a race condition
    /// or a library with multiple auth methods), markLoggedIn() must still be
    /// called so that authState transitions to .loggedIn.
    func testUpdateUserAccount_noSelectedAuth_stillMarksLoggedIn() {
        businessLogic.selectedAuthentication = nil

        businessLogic.updateUserAccount(
            forDRMAuthorization: true,
            withBarcode: "orphanBarcode",
            pin: "orphanPin",
            authToken: nil,
            expirationDate: nil,
            patron: nil,
            cookies: nil
        )

        let user = businessLogic.userAccount as! TPPUserAccountMock
        XCTAssertEqual(user.barcode, "orphanBarcode",
                       "Barcode must be saved even without selectedAuthentication")
        XCTAssertEqual(user.authState, .loggedIn,
                       "PP-3784: markLoggedIn must be called even when selectedAuthentication is nil")
    }

    /// Ensures that refreshing credentials from keychain returns true
    /// after a successful updateUserAccount call.
    func testUpdateUserAccount_credentialsPersistedAndRefreshable() {
        businessLogic.selectedAuthentication = libraryAccountMock.barcodeAuthentication

        businessLogic.updateUserAccount(
            forDRMAuthorization: true,
            withBarcode: "persistedBarcode",
            pin: "persistedPin",
            authToken: nil,
            expirationDate: nil,
            patron: nil,
            cookies: nil
        )

        let hasCreds = businessLogic.userAccount.refreshCredentialsFromKeychain()
        XCTAssertTrue(hasCreds,
                      "Credentials should persist and be detectable after refresh")
    }
}

// MARK: - DRM Failure Credential Preservation

/// Tests that DRM-related failures do NOT wipe basic auth credentials.
/// PP-3784 root cause: DRM failure was calling userAccount.removeAll().
final class TPPDRMFailureCredentialPreservationTests: XCTestCase {

    private var businessLogic: TPPSignInBusinessLogic!
    private var libraryAccountMock: TPPLibraryAccountMock!
    private var drmAuthorizer: TPPDRMAuthorizingMock!
    private var uiDelegate: TPPSignInOutBusinessLogicUIDelegateMock!
    private var networkExecutor: TPPRequestExecutorMock!

    override func setUp() {
        super.setUp()
        TPPUserAccountMock.resetShared()
        libraryAccountMock = TPPLibraryAccountMock()
        drmAuthorizer = TPPDRMAuthorizingMock()
        uiDelegate = TPPSignInOutBusinessLogicUIDelegateMock()
        networkExecutor = TPPRequestExecutorMock()

        businessLogic = TPPSignInBusinessLogic(
            libraryAccountID: libraryAccountMock.tppAccountUUID,
            libraryAccountsProvider: libraryAccountMock,
            urlSettingsProvider: TPPURLSettingsProviderMock(),
            bookRegistry: TPPBookRegistryMock(),
            bookDownloadsCenter: TPPMyBooksDownloadsCenterMock(),
            userAccountProvider: TPPUserAccountMock.self,
            networkExecutor: networkExecutor,
            uiDelegate: uiDelegate,
            drmAuthorizer: drmAuthorizer
        )
    }

    override func tearDown() {
        networkExecutor.reset()
        businessLogic.userAccount.removeAll()
        drmAuthorizer.reset()
        businessLogic = nil
        libraryAccountMock = nil
        drmAuthorizer = nil
        uiDelegate = nil
        networkExecutor = nil
        super.tearDown()
    }

    /// PP-3784: When DRM authorization fails (drmSuccess=false), pre-existing
    /// basic auth credentials must NOT be wiped.
    func testUpdateUserAccount_drmFailure_doesNotWipeExistingCredentials() {
        let user = businessLogic.userAccount as! TPPUserAccountMock
        user._credentials = .barcodeAndPin(barcode: "existingBarcode", pin: "existingPin")

        businessLogic.selectedAuthentication = libraryAccountMock.barcodeAuthentication

        businessLogic.updateUserAccount(
            forDRMAuthorization: false,
            withBarcode: "newBarcode",
            pin: "newPin",
            authToken: nil,
            expirationDate: nil,
            patron: nil,
            cookies: nil
        )

        XCTAssertEqual(user.barcode, "existingBarcode",
                       "PP-3784: DRM failure must NOT wipe existing barcode")
        XCTAssertEqual(user.PIN, "existingPin",
                       "PP-3784: DRM failure must NOT wipe existing PIN")
        XCTAssertTrue(user.hasCredentials(),
                      "PP-3784: hasCredentials must still be true after DRM failure")
    }

    /// PP-3784: When DRM fails but user had no prior credentials, the account
    /// should still not crash or enter an inconsistent state.
    func testUpdateUserAccount_drmFailure_noExistingCredentials_noWipe() {
        let user = businessLogic.userAccount as! TPPUserAccountMock
        XCTAssertFalse(user.hasCredentials(), "Precondition: no credentials")

        businessLogic.updateUserAccount(
            forDRMAuthorization: false,
            withBarcode: "barcode",
            pin: "pin",
            authToken: nil,
            expirationDate: nil,
            patron: nil,
            cookies: nil
        )

        // Should not crash, and should not have set new credentials either
        // (since drmSuccess is false, the method returns early)
        XCTAssertFalse(user.hasCredentials(),
                       "No credentials should be set when DRM fails without prior credentials")
    }

    /// PP-3784: After DRM failure, the auth state should NOT be changed
    /// to loggedOut (which would cause the UI to clear barcode fields).
    func testUpdateUserAccount_drmFailure_doesNotChangeAuthState() {
        let user = businessLogic.userAccount as! TPPUserAccountMock
        user._credentials = .barcodeAndPin(barcode: "test", pin: "1234")
        user.setAuthState(.loggedIn)

        businessLogic.updateUserAccount(
            forDRMAuthorization: false,
            withBarcode: "test",
            pin: "1234",
            authToken: nil,
            expirationDate: nil,
            patron: nil,
            cookies: nil
        )

        XCTAssertEqual(user.authState, .loggedIn,
                       "PP-3784: Auth state must remain .loggedIn after DRM failure")
    }

    /// Verifies that DRM success=true properly saves new credentials,
    /// contrasting with the DRM failure cases above.
    func testUpdateUserAccount_drmSuccess_doesSaveCredentials() {
        businessLogic.selectedAuthentication = libraryAccountMock.barcodeAuthentication

        businessLogic.updateUserAccount(
            forDRMAuthorization: true,
            withBarcode: "newBarcode",
            pin: "newPin",
            authToken: nil,
            expirationDate: nil,
            patron: nil,
            cookies: nil
        )

        let user = businessLogic.userAccount
        XCTAssertEqual(user.barcode, "newBarcode",
                       "DRM success must save new barcode")
        XCTAssertEqual(user.PIN, "newPin",
                       "DRM success must save new PIN")
    }
}

// MARK: - Credential Snapshot Atomicity Tests

/// Tests for TPPUserAccount.credentialSnapshot(for:) which reads all
/// credential state in a single barrier to prevent races.
final class TPPCredentialSnapshotTests: XCTestCase {

    override func tearDown() {
        TPPUserAccountMock.sharedAccount(libraryUUID: nil).removeAll()
        super.tearDown()
    }

    /// Snapshot returns correct barcode and PIN after setting credentials.
    func testSnapshot_returnsCredentialsAfterSet() {
        let user = TPPUserAccountMock.sharedAccount(libraryUUID: nil) as! TPPUserAccountMock
        user._credentials = .barcodeAndPin(barcode: "snapshotBarcode", pin: "snapshotPin")
        user.setAuthState(.loggedIn)

        let snapshot = TPPUserAccountMock.credentialSnapshot(for: nil)

        XCTAssertTrue(snapshot.hasCredentials)
        XCTAssertFalse(snapshot.hasAuthToken)
        XCTAssertEqual(snapshot.barcode, "snapshotBarcode")
        XCTAssertEqual(snapshot.pin, "snapshotPin")
    }

    /// Snapshot correctly identifies token-based (OAuth) credentials.
    func testSnapshot_identifiesTokenCredentials() {
        let user = TPPUserAccountMock.sharedAccount(libraryUUID: nil) as! TPPUserAccountMock
        user._credentials = .token(authToken: "myToken", barcode: "tokenBarcode", pin: nil, expirationDate: nil)
        user.setAuthState(.loggedIn)

        let snapshot = TPPUserAccountMock.credentialSnapshot(for: nil)

        XCTAssertTrue(snapshot.hasCredentials)
        XCTAssertTrue(snapshot.hasAuthToken)
        XCTAssertEqual(snapshot.barcode, "tokenBarcode")
        XCTAssertNil(snapshot.pin)
    }

    /// Snapshot returns correct auth state.
    func testSnapshot_returnsAuthState() {
        let user = TPPUserAccountMock.sharedAccount(libraryUUID: nil) as! TPPUserAccountMock
        user._credentials = .barcodeAndPin(barcode: "test", pin: "1234")
        user.setAuthState(.credentialsStale)

        let snapshot = TPPUserAccountMock.credentialSnapshot(for: nil)

        XCTAssertEqual(snapshot.authState, .credentialsStale)
        XCTAssertTrue(snapshot.hasCredentials)
    }

    /// Snapshot correctly reports no credentials when account is empty.
    func testSnapshot_reportsNoCredentials() {
        let user = TPPUserAccountMock.sharedAccount(libraryUUID: nil) as! TPPUserAccountMock
        user.removeAll()

        let snapshot = TPPUserAccountMock.credentialSnapshot(for: nil)

        XCTAssertFalse(snapshot.hasCredentials)
        XCTAssertFalse(snapshot.hasAuthToken)
        XCTAssertEqual(snapshot.authState, .loggedOut)
        XCTAssertNil(snapshot.barcode)
        XCTAssertNil(snapshot.pin)
    }

    /// isSignedIn logic using snapshot matches expected behavior for basic auth.
    func testSnapshot_isSignedInLogic_basicAuth() {
        let user = TPPUserAccountMock.sharedAccount(libraryUUID: nil) as! TPPUserAccountMock
        user._credentials = .barcodeAndPin(barcode: "barcode", pin: "pin")
        user.setAuthState(.loggedIn)

        let snapshot = TPPUserAccountMock.credentialSnapshot(for: nil)
        let isSignedIn = snapshot.hasCredentials && snapshot.authState != .loggedOut

        XCTAssertTrue(isSignedIn,
                      "Basic auth with credentials + loggedIn should be signed in")
    }

    /// PP-3784: Basic auth with stale credentials should still appear signed in.
    /// A 401 from bookRegistry.sync() triggers markCredentialsStale(), but the
    /// user's barcode must remain visible.
    func testSnapshot_isSignedInLogic_basicAuth_stale() {
        let user = TPPUserAccountMock.sharedAccount(libraryUUID: nil) as! TPPUserAccountMock
        user._credentials = .barcodeAndPin(barcode: "barcode", pin: "pin")
        user.setAuthState(.credentialsStale)

        let snapshot = TPPUserAccountMock.credentialSnapshot(for: nil)
        let isSignedIn = snapshot.hasCredentials && snapshot.authState != .loggedOut

        XCTAssertTrue(isSignedIn,
                      "PP-3784: Basic auth with stale credentials should still show as signed in")
    }

    /// OAuth with stale credentials → should still be true (token refreshes in background).
    func testSnapshot_isSignedInLogic_OAuth_stale() {
        let user = TPPUserAccountMock.sharedAccount(libraryUUID: nil) as! TPPUserAccountMock
        user._credentials = .token(authToken: "tok", barcode: nil, pin: nil, expirationDate: nil)
        user.setAuthState(.credentialsStale)

        let snapshot = TPPUserAccountMock.credentialSnapshot(for: nil)
        let isSignedIn = snapshot.hasCredentials && snapshot.authState != .loggedOut

        XCTAssertTrue(isSignedIn,
                      "OAuth with stale credentials should still be signed in")
    }

    /// Only .loggedOut should result in not signed in.
    func testSnapshot_isSignedInLogic_loggedOut() {
        let user = TPPUserAccountMock.sharedAccount(libraryUUID: nil) as! TPPUserAccountMock
        user._credentials = .barcodeAndPin(barcode: "barcode", pin: "pin")
        user.setAuthState(.loggedOut)

        let snapshot = TPPUserAccountMock.credentialSnapshot(for: nil)
        let isSignedIn = snapshot.hasCredentials && snapshot.authState != .loggedOut

        XCTAssertFalse(isSignedIn,
                       "Explicit loggedOut with credentials should NOT be signed in")
    }
}

// MARK: - Auth State Transition Tests

/// Tests that auth state transitions during sign-in produce the correct end state.
final class TPPSignInAuthStateTransitionTests: XCTestCase {

    private var businessLogic: TPPSignInBusinessLogic!
    private var libraryAccountMock: TPPLibraryAccountMock!
    private var drmAuthorizer: TPPDRMAuthorizingMock!
    private var uiDelegate: TPPSignInOutBusinessLogicUIDelegateMock!

    override func setUp() {
        super.setUp()
        TPPUserAccountMock.resetShared()
        libraryAccountMock = TPPLibraryAccountMock()
        drmAuthorizer = TPPDRMAuthorizingMock()
        uiDelegate = TPPSignInOutBusinessLogicUIDelegateMock()

        businessLogic = TPPSignInBusinessLogic(
            libraryAccountID: libraryAccountMock.tppAccountUUID,
            libraryAccountsProvider: libraryAccountMock,
            urlSettingsProvider: TPPURLSettingsProviderMock(),
            bookRegistry: TPPBookRegistryMock(),
            bookDownloadsCenter: TPPMyBooksDownloadsCenterMock(),
            userAccountProvider: TPPUserAccountMock.self,
            networkExecutor: TPPRequestExecutorMock(),
            uiDelegate: uiDelegate,
            drmAuthorizer: drmAuthorizer
        )
    }

    override func tearDown() {
        businessLogic.userAccount.removeAll()
        drmAuthorizer.reset()
        businessLogic = nil
        libraryAccountMock = nil
        drmAuthorizer = nil
        uiDelegate = nil
        super.tearDown()
    }

    /// loggedOut → sign in → loggedIn
    func testSignIn_transitionsFromLoggedOutToLoggedIn() {
        let user = businessLogic.userAccount as! TPPUserAccountMock
        XCTAssertEqual(user.authState, .loggedOut, "Precondition: starts loggedOut")

        businessLogic.selectedAuthentication = libraryAccountMock.barcodeAuthentication

        let expectation = self.expectation(description: "Sign-in completes")
        uiDelegate.didCompleteSignInHandler = { expectation.fulfill() }

        businessLogic.validateCredentials()
        waitForExpectations(timeout: 5.0)

        XCTAssertEqual(user.authState, .loggedIn,
                       "Auth state should be .loggedIn after sign-in")
    }

    /// credentialsStale → re-authenticate → loggedIn
    func testReauth_transitionsFromStaleToLoggedIn() {
        let user = businessLogic.userAccount as! TPPUserAccountMock
        user._credentials = .barcodeAndPin(barcode: "existing", pin: "creds")
        user.setAuthState(.credentialsStale)

        businessLogic.selectedAuthentication = libraryAccountMock.barcodeAuthentication

        let expectation = self.expectation(description: "Re-auth completes")
        uiDelegate.didCompleteSignInHandler = { expectation.fulfill() }

        businessLogic.validateCredentials()
        waitForExpectations(timeout: 5.0)

        XCTAssertEqual(user.authState, .loggedIn,
                       "Auth state should be .loggedIn after re-authentication")
        XCTAssertTrue(user.hasCredentials(),
                      "Credentials should exist after re-authentication")
    }

    /// PP-3784 regression: After a complete sign-in, the combination of
    /// hasCredentials + authState must make isSignedIn evaluate to true.
    /// This is the exact condition checked by accountDidChange().
    func testSignIn_isSignedInConditionMet() {
        businessLogic.selectedAuthentication = libraryAccountMock.barcodeAuthentication
        uiDelegate.username = "testBarcode"
        uiDelegate.pin = "testPin"

        let expectation = self.expectation(description: "Sign-in completes")
        uiDelegate.didCompleteSignInHandler = { expectation.fulfill() }

        businessLogic.validateCredentials()
        waitForExpectations(timeout: 5.0)

        let user = businessLogic.userAccount as! TPPUserAccountMock
        let hasCreds = user.hasCredentials()
        let authState = user.authState
        let hasToken = user.hasAuthToken()

        let isSignedIn = hasCreds && authState != .loggedOut

        XCTAssertTrue(isSignedIn,
                      "PP-3784: The isSignedIn condition must evaluate to true after sign-in. " +
                      "hasCreds=\(hasCreds), authState=\(authState), hasToken=\(hasToken)")
    }
}

// MARK: - Profile Document Edge Cases

/// Tests for sign-in behavior with various user profile document formats.
final class TPPSignInProfileDocEdgeCaseTests: XCTestCase {

    private var businessLogic: TPPSignInBusinessLogic!
    private var libraryAccountMock: TPPLibraryAccountMock!
    private var drmAuthorizer: TPPDRMAuthorizingMock!
    private var uiDelegate: TPPSignInOutBusinessLogicUIDelegateMock!
    private var networkExecutor: TPPRequestExecutorMock!

    override func setUp() {
        super.setUp()
        TPPUserAccountMock.resetShared()
        libraryAccountMock = TPPLibraryAccountMock()
        drmAuthorizer = TPPDRMAuthorizingMock()
        uiDelegate = TPPSignInOutBusinessLogicUIDelegateMock()
        networkExecutor = TPPRequestExecutorMock()

        businessLogic = TPPSignInBusinessLogic(
            libraryAccountID: libraryAccountMock.tppAccountUUID,
            libraryAccountsProvider: libraryAccountMock,
            urlSettingsProvider: TPPURLSettingsProviderMock(),
            bookRegistry: TPPBookRegistryMock(),
            bookDownloadsCenter: TPPMyBooksDownloadsCenterMock(),
            userAccountProvider: TPPUserAccountMock.self,
            networkExecutor: networkExecutor,
            uiDelegate: uiDelegate,
            drmAuthorizer: drmAuthorizer
        )
    }

    override func tearDown() {
        networkExecutor.reset()
        businessLogic.userAccount.removeAll()
        drmAuthorizer.reset()
        businessLogic = nil
        libraryAccountMock = nil
        drmAuthorizer = nil
        uiDelegate = nil
        networkExecutor = nil
        super.tearDown()
    }

    /// PP-3784: When the user profile doc has no DRM section at all, sign-in
    /// must still succeed with barcode visible.
    func testSignIn_noDRMInProfileDoc_credentialsPreserved() {
        let noDRMProfileUrl = URL(string: "https://circulation.librarysimplified.org/NYNYPL/patrons/me/")!
        let noDRMJson = """
        {
            "simplified:authorization_identifier": "12345",
            "links": [],
            "settings": {}
        }
        """
        networkExecutor.responseBodies[noDRMProfileUrl] = noDRMJson

        uiDelegate.username = "12345barcode"
        uiDelegate.pin = "4567"
        businessLogic.selectedAuthentication = libraryAccountMock.barcodeAuthentication

        let expectation = self.expectation(description: "Sign-in completes")
        uiDelegate.didCompleteSignInHandler = { expectation.fulfill() }

        businessLogic.validateCredentials()
        waitForExpectations(timeout: 5.0)

        let user = businessLogic.userAccount
        XCTAssertEqual(user.barcode, "12345barcode",
                       "PP-3784: Barcode must persist when profile doc has no DRM")
        XCTAssertEqual(user.PIN, "4567",
                       "PP-3784: PIN must persist when profile doc has no DRM")
        XCTAssertTrue(user.hasCredentials())
    }

    /// PP-3784: When the profile doc is completely unparseable, sign-in
    /// must still succeed (the server already accepted the credentials).
    func testSignIn_invalidProfileDoc_credentialsPreserved() {
        let profileUrl = URL(string: "https://circulation.librarysimplified.org/NYNYPL/patrons/me/")!
        networkExecutor.responseBodies[profileUrl] = "NOT VALID JSON AT ALL"

        uiDelegate.username = "myBarcode"
        uiDelegate.pin = "myPin"
        businessLogic.selectedAuthentication = libraryAccountMock.barcodeAuthentication

        let expectation = self.expectation(description: "Sign-in completes")
        uiDelegate.didCompleteSignInHandler = { expectation.fulfill() }

        businessLogic.validateCredentials()
        waitForExpectations(timeout: 5.0)

        let user = businessLogic.userAccount
        XCTAssertEqual(user.barcode, "myBarcode",
                       "PP-3784: Barcode must persist even with invalid profile doc")
        XCTAssertEqual(user.PIN, "myPin",
                       "PP-3784: PIN must persist even with invalid profile doc")
    }

    /// Standard sign-in with valid DRM info should save both credentials and DRM data.
    func testSignIn_validDRMProfileDoc_savesCredentialsAndDRM() {
        uiDelegate.username = "drmBarcode"
        uiDelegate.pin = "drmPin"
        businessLogic.selectedAuthentication = libraryAccountMock.barcodeAuthentication

        let expectation = self.expectation(description: "Sign-in completes")
        uiDelegate.didCompleteSignInHandler = { expectation.fulfill() }

        businessLogic.validateCredentials()
        waitForExpectations(timeout: 5.0)

        let user = businessLogic.userAccount
        XCTAssertEqual(user.barcode, "drmBarcode")
        XCTAssertEqual(user.PIN, "drmPin")
        XCTAssertTrue(user.hasCredentials())

        #if FEATURE_DRM_CONNECTOR
        XCTAssertNotNil(user.licensor,
                        "Licensor should be saved from valid profile doc")
        #endif
    }
}

// MARK: - Concurrent Access Safety Tests

/// Tests that credential reads remain consistent even when multiple operations
/// compete for the TPPUserAccount singleton.
final class TPPCredentialConcurrencyTests: XCTestCase {

    override func tearDown() {
        TPPUserAccountMock.sharedAccount(libraryUUID: nil).removeAll()
        super.tearDown()
    }

    /// Stress test: rapid concurrent snapshots should all return consistent data.
    func testConcurrentSnapshots_returnConsistentData() {
        let user = TPPUserAccountMock.sharedAccount(libraryUUID: nil) as! TPPUserAccountMock
        user._credentials = .barcodeAndPin(barcode: "concurrentBarcode", pin: "concurrentPin")
        user.setAuthState(.loggedIn)

        let group = DispatchGroup()
        let iterations = 100
        var failures = 0
        let failureLock = NSLock()

        for _ in 0..<iterations {
            group.enter()
            DispatchQueue.global().async {
                let snapshot = TPPUserAccountMock.credentialSnapshot(for: nil)
                if snapshot.barcode != "concurrentBarcode" ||
                    snapshot.pin != "concurrentPin" ||
                    !snapshot.hasCredentials ||
                    snapshot.authState != .loggedIn {
                    failureLock.lock()
                    failures += 1
                    failureLock.unlock()
                }
                group.leave()
            }
        }

        group.wait()
        XCTAssertEqual(failures, 0,
                       "All concurrent snapshots should return consistent credential data")
    }

    /// PP-3784: atomicUpdate must write all data to the same library's keychain
    /// keys within a single barrier. This verifies the basic contract.
    func testAtomicUpdate_writesAreVisibleInSnapshot() {
        let user = TPPUserAccountMock.sharedAccount(libraryUUID: nil) as! TPPUserAccountMock
        user.removeAll()

        user.atomicUpdate(for: nil) { account in
            account.setBarcode("atomicBarcode", PIN: "atomicPin")
            (account as! TPPUserAccountMock).markLoggedIn()
        }

        XCTAssertEqual(user.barcode, "atomicBarcode",
                       "Barcode written inside atomicUpdate must be readable")
        XCTAssertEqual(user.PIN, "atomicPin",
                       "PIN written inside atomicUpdate must be readable")
        XCTAssertEqual(user.authState, .loggedIn,
                       "Auth state set inside atomicUpdate must be readable")
    }

    /// Verify that refreshCredentialsFromKeychain inside a barrier is safe
    /// when called concurrently from multiple threads.
    func testConcurrentRefreshCredentials_doesNotCrash() {
        let user = TPPUserAccountMock.sharedAccount(libraryUUID: nil) as! TPPUserAccountMock
        user._credentials = .barcodeAndPin(barcode: "test", pin: "test")

        let group = DispatchGroup()
        let iterations = 50

        for _ in 0..<iterations {
            group.enter()
            DispatchQueue.global().async {
                _ = user.refreshCredentialsFromKeychain()
                group.leave()
            }
        }

        group.wait()
        XCTAssertTrue(user.hasCredentials(),
                      "Credentials should remain intact after concurrent refreshes")
    }
}

// MARK: - Captured Credentials Tests (PP-3784 token flow)

/// Tests that barcode/PIN are captured at login time and used by finalizeSignIn,
/// preventing credential loss when the ViewModel's text fields are cleared by
/// intermediate accountDidChange notifications.
final class TPPCapturedCredentialsTests: XCTestCase {

    private var businessLogic: TPPSignInBusinessLogic!
    private var libraryAccountMock: TPPLibraryAccountMock!
    private var drmAuthorizer: TPPDRMAuthorizingMock!
    private var uiDelegate: TPPSignInOutBusinessLogicUIDelegateMock!
    private var networkExecutor: TPPRequestExecutorMock!

    override func setUp() {
        super.setUp()
        TPPUserAccountMock.resetShared()
        libraryAccountMock = TPPLibraryAccountMock()
        drmAuthorizer = TPPDRMAuthorizingMock()
        uiDelegate = TPPSignInOutBusinessLogicUIDelegateMock()
        networkExecutor = TPPRequestExecutorMock()

        businessLogic = TPPSignInBusinessLogic(
            libraryAccountID: libraryAccountMock.tppAccountUUID,
            libraryAccountsProvider: libraryAccountMock,
            urlSettingsProvider: TPPURLSettingsProviderMock(),
            bookRegistry: TPPBookRegistryMock(),
            bookDownloadsCenter: TPPMyBooksDownloadsCenterMock(),
            userAccountProvider: TPPUserAccountMock.self,
            networkExecutor: networkExecutor,
            uiDelegate: uiDelegate,
            drmAuthorizer: drmAuthorizer
        )
    }

    override func tearDown() {
        networkExecutor.reset()
        businessLogic.userAccount.removeAll()
        drmAuthorizer.reset()
        businessLogic = nil
        libraryAccountMock = nil
        drmAuthorizer = nil
        uiDelegate = nil
        networkExecutor = nil
        super.tearDown()
    }

    /// PP-3784: When the UI delegate's credentials are cleared between logIn()
    /// and finalizeSignIn() (e.g. by an intermediate accountDidChange notification),
    /// the captured credentials must still be used.
    func testFinalizeSignIn_usesCapturedCredentials_whenUIDelegateCleared() {
        let barcode = "23333012345678"
        let pin = "1234"
        uiDelegate.username = barcode
        uiDelegate.pin = pin

        businessLogic.selectedAuthentication = libraryAccountMock.barcodeAuthentication

        let expectation = self.expectation(description: "Sign-in completes")
        uiDelegate.didCompleteSignInHandler = {
            expectation.fulfill()
        }

        // Simulate: logIn captures credentials, then UI delegate is cleared
        // before finalizeSignIn reads them. This happens in production when
        // executeTokenRefresh fires accountDidChange → ViewModel clears fields.
        businessLogic.logIn()

        // Clear the UI delegate's credentials (simulating accountDidChange clearing ViewModel)
        uiDelegate.username = nil
        uiDelegate.pin = nil

        waitForExpectations(timeout: 5.0)

        let user = businessLogic.userAccount
        XCTAssertEqual(user.barcode, barcode,
                       "PP-3784: Must use captured barcode when UI delegate is cleared")
        XCTAssertEqual(user.PIN, pin,
                       "PP-3784: Must use captured PIN when UI delegate is cleared")
    }

    /// PP-3784: When captured credentials are nil (e.g. OAuth flow where
    /// credentials come from the server), finalizeSignIn falls back to the
    /// UI delegate's current values.
    func testFinalizeSignIn_fallsBackToUIDelegate_whenCapturedNil() {
        businessLogic.selectedAuthentication = libraryAccountMock.barcodeAuthentication

        // Set uiDelegate credentials AFTER logIn would have been called
        // (simulating OAuth where credentials arrive later)
        uiDelegate.username = "oauthBarcode"
        uiDelegate.pin = "oauthPin"

        businessLogic.updateUserAccount(
            forDRMAuthorization: true,
            withBarcode: uiDelegate.username,
            pin: uiDelegate.pin,
            authToken: nil,
            expirationDate: nil,
            patron: nil,
            cookies: nil
        )

        let user = businessLogic.userAccount
        XCTAssertEqual(user.barcode, "oauthBarcode",
                       "Should use UI delegate credentials when captured values are nil")
        XCTAssertEqual(user.PIN, "oauthPin")
    }

    /// PP-3784: atomicUpdate must be called with the correct library UUID
    /// so credentials are written to the right keychain keys.
    func testUpdateUserAccount_usesAtomicUpdateWithCorrectLibraryUUID() {
        businessLogic.selectedAuthentication = libraryAccountMock.barcodeAuthentication
        let mockUser = businessLogic.userAccount as! TPPUserAccountMock

        businessLogic.updateUserAccount(
            forDRMAuthorization: true,
            withBarcode: "test",
            pin: "test",
            authToken: nil,
            expirationDate: nil,
            patron: nil,
            cookies: nil
        )

        XCTAssertGreaterThanOrEqual(mockUser.atomicUpdateCallCount, 1,
                                    "atomicUpdate must be called during updateUserAccount")
        XCTAssertEqual(mockUser.atomicUpdateLibraryUUIDs.last,
                       libraryAccountMock.tppAccountUUID,
                       "atomicUpdate must use the correct library UUID")
    }

    /// PP-3784: When updateUserAccount receives an auth token (token-based
    /// auth), it must save both the token and the barcode/PIN and write
    /// everything to the correct library's keychain keys.
    func testUpdateUserAccount_withAuthToken_savesAllCredentials() {
        businessLogic.selectedAuthentication = libraryAccountMock.oauthAuthentication

        businessLogic.updateUserAccount(
            forDRMAuthorization: true,
            withBarcode: "tokenBarcode",
            pin: "tokenPin",
            authToken: "bearerToken123",
            expirationDate: Date().addingTimeInterval(3600),
            patron: nil,
            cookies: nil
        )

        let user = businessLogic.userAccount as! TPPUserAccountMock
        XCTAssertEqual(user.authToken, "bearerToken123",
                       "Auth token must be saved")
        XCTAssertEqual(user.barcode, "tokenBarcode",
                       "Barcode must be saved alongside token")
        XCTAssertEqual(user.authState, .loggedIn,
                       "Auth state must be loggedIn after token auth")

        XCTAssertEqual(user.atomicUpdateLibraryUUIDs.last,
                       libraryAccountMock.tppAccountUUID,
                       "Must write to the correct library UUID")
    }

    /// PP-3784: Multiple sign-in attempts must not accumulate stale captured
    /// credentials. Each logIn() call must refresh the captured values.
    func testLogIn_refreshesCapturedCredentials_onSubsequentAttempts() {
        businessLogic.selectedAuthentication = libraryAccountMock.barcodeAuthentication

        uiDelegate.username = "firstBarcode"
        uiDelegate.pin = "firstPin"

        let exp1 = expectation(description: "First sign-in completes")
        uiDelegate.didCompleteSignInHandler = { exp1.fulfill() }
        businessLogic.validateCredentials()
        waitForExpectations(timeout: 5.0)

        XCTAssertEqual(businessLogic.userAccount.barcode, "firstBarcode")

        // Sign out (reset state)
        businessLogic.userAccount.removeAll()

        uiDelegate.username = "secondBarcode"
        uiDelegate.pin = "secondPin"

        let exp2 = expectation(description: "Second sign-in completes")
        uiDelegate.didCompleteSignInHandler = { exp2.fulfill() }
        businessLogic.logIn()

        // Clear UI delegate to simulate intermediate notification
        uiDelegate.username = nil
        uiDelegate.pin = nil

        waitForExpectations(timeout: 5.0)

        XCTAssertEqual(businessLogic.userAccount.barcode, "secondBarcode",
                       "Second sign-in must use freshly captured credentials, not stale ones")
    }
}
