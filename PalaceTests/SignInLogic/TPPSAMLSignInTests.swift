//
//  TPPSAMLSignInTests.swift
//  PalaceTests
//
//  SAML-specific sign-in tests to prevent regressions in SAML authentication flow.
//  These tests verify credential persistence, state synchronization, and keychain operations.
//

import XCTest
import Combine
@testable import Palace

// MARK: - SAML Sign-In Regression Tests

final class TPPSAMLSignInTests: XCTestCase {
  
  // MARK: - Properties
  
  private var businessLogic: TPPSignInBusinessLogic!
  private var libraryAccountMock: TPPLibraryAccountMock!
  private var uiDelegate: TPPSignInOutBusinessLogicUIDelegateMock!
  private var networkExecutor: TPPRequestExecutorMock!
  private var bookRegistry: TPPBookRegistryMock!
  private var downloadCenter: TPPMyBooksDownloadsCenterMock!
  private var drmAuthorizer: TPPDRMAuthorizingMock!
  
  // MARK: - Setup/Teardown
  
  override func setUpWithError() throws {
    try super.setUpWithError()
    
    libraryAccountMock = TPPLibraryAccountMock()
    uiDelegate = TPPSignInOutBusinessLogicUIDelegateMock()
    networkExecutor = TPPRequestExecutorMock()
    bookRegistry = TPPBookRegistryMock()
    downloadCenter = TPPMyBooksDownloadsCenterMock()
    drmAuthorizer = TPPDRMAuthorizingMock()
    
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
    businessLogic.userAccount.removeAll()
    businessLogic = nil
    libraryAccountMock = nil
    uiDelegate = nil
    networkExecutor = nil
    bookRegistry = nil
    downloadCenter = nil
    drmAuthorizer = nil
    try super.tearDownWithError()
  }
  
  // MARK: - SAML Credential Persistence Tests
  
  /// PP-418 Regression Test: Verifies that SAML credentials are persisted after sign-in.
  /// 
  /// Bug: After SAML sign-in from the borrow flow, credentials were not persisted,
  /// causing the Settings screen to show the user as signed out.
  func testSAMLSignIn_PP418_credentialsArePersisted() {
    // Setup: Configure for SAML authentication
    businessLogic.selectedAuthentication = libraryAccountMock.samlAuthentication
    
    let testToken = "saml-auth-token-\(UUID().uuidString)"
    let testPatron: [String: Any] = [
      "name": "Test SAML User",
      "email": "test@example.com"
    ]
    let testCookies = [
      HTTPCookie(properties: [
        .domain: "idp.example.com",
        .path: "/",
        .name: "saml_session",
        .value: "session_token_123"
      ])!
    ]
    
    // Precondition: User should not be signed in
    XCTAssertFalse(businessLogic.userAccount.hasCredentials(),
                   "Precondition: User should not have credentials")
    
    // Act: Simulate SAML sign-in by calling updateUserAccount
    // (This is what happens after SAML redirect is processed)
    businessLogic.updateUserAccount(
      forDRMAuthorization: true,
      withBarcode: nil,
      pin: nil,
      authToken: testToken,
      expirationDate: nil,
      patron: testPatron,
      cookies: testCookies
    )
    
    // Assert: Credentials should be persisted
    XCTAssertTrue(businessLogic.userAccount.hasCredentials(),
                  "PP-418: Credentials should be persisted after SAML sign-in")
    XCTAssertTrue(businessLogic.userAccount.hasAuthToken(),
                  "PP-418: Auth token should be persisted")
    XCTAssertEqual(businessLogic.userAccount.authToken, testToken,
                   "PP-418: Auth token should match what was set")
    XCTAssertEqual(businessLogic.userAccount.authState, .loggedIn,
                   "PP-418: Auth state should be loggedIn")
    XCTAssertNotNil(businessLogic.userAccount.patron,
                    "PP-418: Patron info should be persisted")
    XCTAssertEqual(businessLogic.userAccount.cookies?.count, 1,
                   "PP-418: SAML cookies should be persisted")
  }
  
  /// Tests that auth state is correctly set to loggedIn after SAML sign-in.
  func testSAMLSignIn_setsAuthStateToLoggedIn() {
    // Setup
    businessLogic.selectedAuthentication = libraryAccountMock.samlAuthentication
    
    // Precondition
    XCTAssertEqual(businessLogic.userAccount.authState, .loggedOut,
                   "Precondition: Auth state should be loggedOut")
    
    // Act
    businessLogic.updateUserAccount(
      forDRMAuthorization: true,
      withBarcode: nil,
      pin: nil,
      authToken: "test-token",
      expirationDate: nil,
      patron: ["name": "Test User"],
      cookies: nil
    )
    
    // Assert
    XCTAssertEqual(businessLogic.userAccount.authState, .loggedIn,
                   "Auth state should be loggedIn after SAML sign-in")
  }
  
  /// Tests that hasCredentials() returns true after SAML sign-in.
  func testSAMLSignIn_hasCredentialsReturnsTrue() {
    // Setup
    businessLogic.selectedAuthentication = libraryAccountMock.samlAuthentication
    
    // Act
    businessLogic.updateUserAccount(
      forDRMAuthorization: true,
      withBarcode: nil,
      pin: nil,
      authToken: "test-token-123",
      expirationDate: nil,
      patron: nil,
      cookies: nil
    )
    
    // Assert
    XCTAssertTrue(businessLogic.userAccount.hasCredentials(),
                  "hasCredentials() should return true after SAML sign-in")
    XCTAssertTrue(businessLogic.isSignedIn(),
                  "isSignedIn() should return true after SAML sign-in")
  }
  
  /// Tests that SAML cookies are properly stored.
  func testSAMLSignIn_cookiesAreStored() {
    // Setup
    businessLogic.selectedAuthentication = libraryAccountMock.samlAuthentication
    
    let cookies = [
      HTTPCookie(properties: [
        .domain: "idp1.example.com",
        .path: "/",
        .name: "session1",
        .value: "value1"
      ])!,
      HTTPCookie(properties: [
        .domain: "idp2.example.com",
        .path: "/auth",
        .name: "session2",
        .value: "value2"
      ])!
    ]
    
    // Act
    businessLogic.updateUserAccount(
      forDRMAuthorization: true,
      withBarcode: nil,
      pin: nil,
      authToken: "token",
      expirationDate: nil,
      patron: nil,
      cookies: cookies
    )
    
    // Assert
    XCTAssertEqual(businessLogic.userAccount.cookies?.count, 2,
                   "All SAML cookies should be stored")
    XCTAssertTrue(businessLogic.userAccount.cookies?.contains { $0.name == "session1" } ?? false,
                  "First cookie should be present")
    XCTAssertTrue(businessLogic.userAccount.cookies?.contains { $0.name == "session2" } ?? false,
                  "Second cookie should be present")
  }
  
  /// Tests that patron information is properly stored after SAML sign-in.
  func testSAMLSignIn_patronInfoIsStored() {
    // Setup
    businessLogic.selectedAuthentication = libraryAccountMock.samlAuthentication
    
    let patron: [String: Any] = [
      "name": "John Doe",
      "email": "john@example.com",
      "id": "patron-123"
    ]
    
    // Act
    businessLogic.updateUserAccount(
      forDRMAuthorization: true,
      withBarcode: nil,
      pin: nil,
      authToken: "token",
      expirationDate: nil,
      patron: patron,
      cookies: nil
    )
    
    // Assert
    XCTAssertNotNil(businessLogic.userAccount.patron,
                    "Patron info should be stored")
    XCTAssertEqual(businessLogic.userAccount.patron?["name"] as? String, "John Doe",
                   "Patron name should match")
    XCTAssertEqual(businessLogic.userAccount.patron?["email"] as? String, "john@example.com",
                   "Patron email should match")
  }
  
  // MARK: - Sign-Out Tests
  
  /// Tests that SAML credentials are cleared on sign-out.
  func testSAMLSignOut_clearsAllCredentials() {
    // Setup: Sign in first
    businessLogic.selectedAuthentication = libraryAccountMock.samlAuthentication
    businessLogic.updateUserAccount(
      forDRMAuthorization: true,
      withBarcode: nil,
      pin: nil,
      authToken: "test-token",
      expirationDate: nil,
      patron: ["name": "Test"],
      cookies: [HTTPCookie(properties: [
        .domain: "example.com",
        .path: "/",
        .name: "session",
        .value: "value"
      ])!]
    )
    
    // Precondition
    XCTAssertTrue(businessLogic.userAccount.hasCredentials(),
                  "Precondition: User should have credentials before sign-out")
    
    // Act
    businessLogic.userAccount.removeAll()
    
    // Assert
    XCTAssertFalse(businessLogic.userAccount.hasCredentials(),
                   "hasCredentials() should return false after sign-out")
    XCTAssertEqual(businessLogic.userAccount.authState, .loggedOut,
                   "Auth state should be loggedOut after sign-out")
    XCTAssertNil(businessLogic.userAccount.authToken,
                 "Auth token should be nil after sign-out")
    XCTAssertNil(businessLogic.userAccount.patron,
                 "Patron should be nil after sign-out")
    XCTAssertNil(businessLogic.userAccount.cookies,
                 "Cookies should be nil after sign-out")
  }
  
  // MARK: - State Transition Tests
  
  /// Tests the full SAML sign-in flow state transitions.
  func testSAMLSignIn_stateTransitions() {
    // Setup
    businessLogic.selectedAuthentication = libraryAccountMock.samlAuthentication
    
    // Initial state
    XCTAssertEqual(businessLogic.userAccount.authState, .loggedOut,
                   "Initial state should be loggedOut")
    XCTAssertFalse(businessLogic.userAccount.hasCredentials(),
                   "Should not have credentials initially")
    
    // After setting auth token
    businessLogic.updateUserAccount(
      forDRMAuthorization: true,
      withBarcode: nil,
      pin: nil,
      authToken: "token",
      expirationDate: nil,
      patron: nil,
      cookies: nil
    )
    
    // Final state
    XCTAssertEqual(businessLogic.userAccount.authState, .loggedIn,
                   "Final state should be loggedIn")
    XCTAssertTrue(businessLogic.userAccount.hasCredentials(),
                  "Should have credentials after sign-in")
  }
  
  /// Tests that auth state can transition from loggedOut to loggedIn.
  func testAuthState_transitionsFromLoggedOutToLoggedIn() {
    // Setup
    businessLogic.selectedAuthentication = libraryAccountMock.samlAuthentication
    
    XCTAssertEqual(businessLogic.userAccount.authState, .loggedOut)
    
    // Act
    businessLogic.userAccount.setAuthToken("token", barcode: nil, pin: nil, expirationDate: nil)
    businessLogic.userAccount.markLoggedIn()
    
    // Assert
    XCTAssertEqual(businessLogic.userAccount.authState, .loggedIn)
  }
  
  // MARK: - Library UUID Tests
  
  /// Tests that credentials are associated with the correct library UUID.
  func testSAMLSignIn_usesCorrectLibraryUUID() {
    // Setup
    businessLogic.selectedAuthentication = libraryAccountMock.samlAuthentication
    let expectedLibraryID = libraryAccountMock.tppAccountUUID
    
    // Verify library ID is set correctly
    XCTAssertEqual(businessLogic.libraryAccountID, expectedLibraryID,
                   "Business logic should have correct library ID")
    
    // Act
    businessLogic.updateUserAccount(
      forDRMAuthorization: true,
      withBarcode: nil,
      pin: nil,
      authToken: "token",
      expirationDate: nil,
      patron: nil,
      cookies: nil
    )
    
    // Assert: Credentials should be retrievable with same library UUID
    let account = TPPUserAccountMock.sharedAccount(libraryUUID: expectedLibraryID)
    XCTAssertTrue(account.hasCredentials(),
                  "Credentials should be retrievable with the same library UUID")
  }
  
  // MARK: - Edge Case Tests
  
  /// Tests that sign-in works even without patron info.
  func testSAMLSignIn_worksWithoutPatronInfo() {
    // Setup
    businessLogic.selectedAuthentication = libraryAccountMock.samlAuthentication
    
    // Act: Sign in without patron info
    businessLogic.updateUserAccount(
      forDRMAuthorization: true,
      withBarcode: nil,
      pin: nil,
      authToken: "token-only",
      expirationDate: nil,
      patron: nil,
      cookies: nil
    )
    
    // Assert
    XCTAssertTrue(businessLogic.userAccount.hasCredentials(),
                  "Should have credentials even without patron info")
    XCTAssertEqual(businessLogic.userAccount.authToken, "token-only",
                   "Auth token should be set")
  }
  
  /// Tests that sign-in works even without cookies.
  func testSAMLSignIn_worksWithoutCookies() {
    // Setup
    businessLogic.selectedAuthentication = libraryAccountMock.samlAuthentication
    
    // Act: Sign in without cookies
    businessLogic.updateUserAccount(
      forDRMAuthorization: true,
      withBarcode: nil,
      pin: nil,
      authToken: "token-no-cookies",
      expirationDate: nil,
      patron: ["name": "User"],
      cookies: nil
    )
    
    // Assert
    XCTAssertTrue(businessLogic.userAccount.hasCredentials(),
                  "Should have credentials even without cookies")
  }
  
  /// Tests that DRM failure prevents credential storage.
  func testSAMLSignIn_drmFailurePreventsCredentialStorage() {
    // Setup
    businessLogic.selectedAuthentication = libraryAccountMock.samlAuthentication
    
    // First, set some credentials
    businessLogic.updateUserAccount(
      forDRMAuthorization: true,
      withBarcode: nil,
      pin: nil,
      authToken: "initial-token",
      expirationDate: nil,
      patron: nil,
      cookies: nil
    )
    
    XCTAssertTrue(businessLogic.userAccount.hasCredentials(),
                  "Should have initial credentials")
    
    // Act: Attempt sign-in with DRM failure
    // Note: In non-DRM builds, this parameter is ignored
    #if FEATURE_DRM_CONNECTOR
    businessLogic.updateUserAccount(
      forDRMAuthorization: false,  // DRM failed
      withBarcode: nil,
      pin: nil,
      authToken: "new-token",
      expirationDate: nil,
      patron: nil,
      cookies: nil
    )
    
    // Assert: Credentials should be removed when DRM fails
    XCTAssertFalse(businessLogic.userAccount.hasCredentials(),
                   "Credentials should be removed when DRM fails")
    #endif
  }
  
  // MARK: - Credentials Stale State Tests (PP-418)
  
  /// PP-418 Regression Test: Verifies that credentialsStale state is handled correctly.
  ///
  /// Bug: When SAML token expired (401 response), the Settings screen showed user as
  /// signed out even though they still had credentials. The credentialsStale state
  /// should be treated as "signed in" for UI purposes.
  func testCredentialsStale_PP418_userStillHasCredentials() {
    // Setup: Sign in first
    businessLogic.selectedAuthentication = libraryAccountMock.samlAuthentication
    businessLogic.updateUserAccount(
      forDRMAuthorization: true,
      withBarcode: nil,
      pin: nil,
      authToken: "test-token",
      expirationDate: nil,
      patron: ["name": "Test User"],
      cookies: nil
    )
    
    // Precondition: User should be signed in
    XCTAssertTrue(businessLogic.userAccount.hasCredentials(),
                  "Precondition: User should have credentials")
    XCTAssertEqual(businessLogic.userAccount.authState, .loggedIn,
                   "Precondition: Auth state should be loggedIn")
    
    // Act: Mark credentials as stale (simulates 401 response from server)
    businessLogic.userAccount.markCredentialsStale()
    
    // Assert: User still has credentials, just stale
    XCTAssertTrue(businessLogic.userAccount.hasCredentials(),
                  "PP-418: User should still have credentials when stale")
    XCTAssertEqual(businessLogic.userAccount.authState, .credentialsStale,
                   "PP-418: Auth state should be credentialsStale")
    XCTAssertNotNil(businessLogic.userAccount.authToken,
                    "PP-418: Auth token should still exist when stale")
  }
  
  /// Tests that hasCredentials returns true even when credentials are stale.
  func testCredentialsStale_hasCredentialsReturnsTrue() {
    // Setup: Sign in and mark stale
    businessLogic.selectedAuthentication = libraryAccountMock.samlAuthentication
    businessLogic.updateUserAccount(
      forDRMAuthorization: true,
      withBarcode: nil,
      pin: nil,
      authToken: "stale-token",
      expirationDate: nil,
      patron: nil,
      cookies: nil
    )
    businessLogic.userAccount.markCredentialsStale()
    
    // Assert
    XCTAssertTrue(businessLogic.userAccount.hasCredentials(),
                  "hasCredentials should return true even when credentials are stale")
  }
  
  /// Tests that re-authentication clears the stale state.
  func testCredentialsStale_reAuthClearsStaleState() {
    // Setup: Sign in and mark stale
    businessLogic.selectedAuthentication = libraryAccountMock.samlAuthentication
    businessLogic.updateUserAccount(
      forDRMAuthorization: true,
      withBarcode: nil,
      pin: nil,
      authToken: "original-token",
      expirationDate: nil,
      patron: nil,
      cookies: nil
    )
    businessLogic.userAccount.markCredentialsStale()
    
    XCTAssertEqual(businessLogic.userAccount.authState, .credentialsStale,
                   "Precondition: Should be stale")
    
    // Act: Re-authenticate with new token
    businessLogic.updateUserAccount(
      forDRMAuthorization: true,
      withBarcode: nil,
      pin: nil,
      authToken: "new-fresh-token",
      expirationDate: nil,
      patron: nil,
      cookies: nil
    )
    
    // Assert: State should be loggedIn again
    XCTAssertEqual(businessLogic.userAccount.authState, .loggedIn,
                   "Re-authentication should set state to loggedIn")
    XCTAssertEqual(businessLogic.userAccount.authToken, "new-fresh-token",
                   "Auth token should be updated")
  }
  
  // MARK: - UI Delegate Loading State Tests
  
  /// Tests that businessLogicWillSignIn is called when sign-in starts.
  func testSignIn_callsBusinessLogicWillSignIn() {
    // Setup
    businessLogic.selectedAuthentication = libraryAccountMock.samlAuthentication
    
    XCTAssertFalse(uiDelegate.didCallWillSignIn,
                   "Precondition: willSignIn should not have been called")
    
    // Act: Trigger sign-in (this will call businessLogicWillSignIn)
    businessLogic.logIn()
    
    // Assert
    XCTAssertTrue(uiDelegate.didCallWillSignIn,
                  "businessLogicWillSignIn should be called when sign-in starts")
    XCTAssertTrue(uiDelegate.isLoading,
                  "isLoading should be true after willSignIn")
  }
  
  /// Tests that businessLogicDidCompleteSignIn is called when sign-in completes.
  func testSignIn_callsBusinessLogicDidCompleteSignIn() {
    // Setup
    businessLogic.selectedAuthentication = libraryAccountMock.samlAuthentication
    
    // Act: Complete sign-in via finalizeSignIn
    businessLogic.finalizeSignIn(forDRMAuthorization: true)
    
    // Use expectation since finalizeSignIn dispatches to main queue
    let expectation = self.expectation(description: "Sign-in completes")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
      expectation.fulfill()
    }
    
    waitForExpectations(timeout: 1.0)
    
    // Assert
    XCTAssertTrue(uiDelegate.didCallDidCompleteSignIn,
                  "businessLogicDidCompleteSignIn should be called when sign-in completes")
  }
  
  /// Tests that loading state transitions correctly through sign-in flow.
  func testSignIn_loadingStateTransitions() {
    // Setup
    businessLogic.selectedAuthentication = libraryAccountMock.samlAuthentication
    
    // Clear any previous state
    uiDelegate.loadingStateChanges.removeAll()
    
    // Act: Simulate full sign-in flow
    // Step 1: Start sign-in
    uiDelegate.businessLogicWillSignIn(businessLogic)
    
    XCTAssertTrue(uiDelegate.isLoading,
                  "Should be loading after willSignIn")
    
    // Step 2: Complete sign-in
    uiDelegate.businessLogicDidCompleteSignIn(businessLogic)
    
    XCTAssertFalse(uiDelegate.isLoading,
                   "Should not be loading after didCompleteSignIn")
    
    // Assert: Verify the transition sequence
    XCTAssertEqual(uiDelegate.loadingStateChanges, [true, false],
                   "Loading state should transition from true to false")
  }
  
  /// Tests that cancelled sign-in sets loading to false.
  func testSignIn_cancelledSetsLoadingFalse() {
    // Setup
    businessLogic.selectedAuthentication = libraryAccountMock.samlAuthentication
    
    // Start sign-in
    uiDelegate.businessLogicWillSignIn(businessLogic)
    XCTAssertTrue(uiDelegate.isLoading)
    
    // Act: Cancel sign-in
    uiDelegate.businessLogicDidCancelSignIn(businessLogic)
    
    // Assert
    XCTAssertFalse(uiDelegate.isLoading,
                   "Loading should be false after sign-in cancelled")
    XCTAssertTrue(uiDelegate.didCallDidCancelSignIn,
                  "didCancelSignIn should be called")
  }
  
  // MARK: - Refresh Credentials Tests
  
  /// Tests that refreshCredentialsFromKeychain returns true when credentials exist.
  func testRefreshCredentialsFromKeychain_returnsTrueWhenCredentialsExist() {
    // Setup: Sign in
    businessLogic.selectedAuthentication = libraryAccountMock.samlAuthentication
    businessLogic.updateUserAccount(
      forDRMAuthorization: true,
      withBarcode: nil,
      pin: nil,
      authToken: "test-token",
      expirationDate: nil,
      patron: nil,
      cookies: nil
    )
    
    // Act
    let hasCredentials = businessLogic.userAccount.refreshCredentialsFromKeychain()
    
    // Assert
    XCTAssertTrue(hasCredentials,
                  "refreshCredentialsFromKeychain should return true when credentials exist")
  }
  
  /// Tests that refreshCredentialsFromKeychain returns false when no credentials.
  func testRefreshCredentialsFromKeychain_returnsFalseWhenNoCredentials() {
    // Setup: Ensure no credentials
    businessLogic.userAccount.removeAll()
    
    // Act
    let hasCredentials = businessLogic.userAccount.refreshCredentialsFromKeychain()
    
    // Assert
    XCTAssertFalse(hasCredentials,
                   "refreshCredentialsFromKeychain should return false when no credentials")
  }
}
