//
//  TPPAccountAuthStateTests.swift
//  PalaceTests
//
//  Tests for the auth state machine that prevents unnecessary Adobe device activations
//  when users re-authenticate after session expiration (e.g., SAML cookie expiry).
//
//  Related Android ticket: PP-XXXX - Skip Adobe activation on session refresh
//

import XCTest
import Combine
@testable import Palace

// MARK: - Auth State Enum Tests

final class TPPAccountAuthStateEnumTests: XCTestCase {
  
  func testDescription_returnsCorrectStrings() {
    XCTAssertEqual(TPPAccountAuthState.loggedOut.description, "loggedOut")
    XCTAssertEqual(TPPAccountAuthState.loggedIn.description, "loggedIn")
    XCTAssertEqual(TPPAccountAuthState.credentialsStale.description, "credentialsStale")
  }
  
  func testHasStoredCredentials_falseOnlyForLoggedOut() {
    XCTAssertFalse(TPPAccountAuthState.loggedOut.hasStoredCredentials)
    XCTAssertTrue(TPPAccountAuthState.loggedIn.hasStoredCredentials)
    XCTAssertTrue(TPPAccountAuthState.credentialsStale.hasStoredCredentials)
  }
  
  func testNeedsReauthentication_trueForLoggedOutAndStale() {
    XCTAssertTrue(TPPAccountAuthState.loggedOut.needsReauthentication)
    XCTAssertFalse(TPPAccountAuthState.loggedIn.needsReauthentication)
    XCTAssertTrue(TPPAccountAuthState.credentialsStale.needsReauthentication)
  }
  
  func testHasAdobeActivation_trueForLoggedInAndStale() {
    XCTAssertFalse(TPPAccountAuthState.loggedOut.hasAdobeActivation)
    XCTAssertTrue(TPPAccountAuthState.loggedIn.hasAdobeActivation)
    XCTAssertTrue(TPPAccountAuthState.credentialsStale.hasAdobeActivation)
  }
  
  func testCodable_encodesAndDecodesCorrectly() throws {
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    
    for state: TPPAccountAuthState in [.loggedOut, .loggedIn, .credentialsStale] {
      let encoded = try encoder.encode(state)
      let decoded = try decoder.decode(TPPAccountAuthState.self, from: encoded)
      XCTAssertEqual(state, decoded, "State \(state) should encode and decode correctly")
    }
  }
}

// MARK: - User Account Auth State Tests

final class TPPUserAccountAuthStateTests: XCTestCase {
  
  private var userAccount: TPPUserAccountMock!
  
  override func setUp() {
    super.setUp()
    userAccount = TPPUserAccountMock()
  }
  
  override func tearDown() {
    userAccount.removeAll()
    userAccount = nil
    super.tearDown()
  }
  
  // MARK: - State Transitions
  
  func testAuthState_defaultsToLoggedOut() {
    XCTAssertEqual(userAccount.authState, .loggedOut)
  }
  
  func testAuthState_derivedFromCredentialsIfNotExplicitlySet() {
    // Given: No explicit auth state set, but credentials exist
    userAccount._credentials = .barcodeAndPin(barcode: "test", pin: "1234")
    
    // Then: Should derive loggedIn from credentials
    XCTAssertEqual(userAccount.authState, .loggedIn)
  }
  
  func testMarkCredentialsStale_transitionsFromLoggedInToStale() {
    // Given: User is logged in
    userAccount._credentials = .barcodeAndPin(barcode: "test", pin: "1234")
    userAccount.setAuthState(.loggedIn)
    XCTAssertEqual(userAccount.authState, .loggedIn)
    
    // When: Mark credentials as stale
    userAccount.markCredentialsStale()
    
    // Then: State should be credentialsStale
    XCTAssertEqual(userAccount.authState, .credentialsStale)
  }
  
  func testMarkCredentialsStale_doesNotTransitionFromLoggedOut() {
    // Given: User is logged out
    XCTAssertEqual(userAccount.authState, .loggedOut)
    
    // When: Try to mark as stale
    userAccount.markCredentialsStale()
    
    // Then: State should remain loggedOut (can't go stale if not logged in)
    XCTAssertEqual(userAccount.authState, .loggedOut)
  }
  
  func testMarkLoggedIn_transitionsFromStaleToLoggedIn() {
    // Given: Credentials are stale
    userAccount._credentials = .barcodeAndPin(barcode: "test", pin: "1234")
    userAccount.setAuthState(.credentialsStale)
    
    // When: Mark as logged in (after successful re-auth)
    userAccount.markLoggedIn()
    
    // Then: State should be loggedIn
    XCTAssertEqual(userAccount.authState, .loggedIn)
  }
  
  func testMarkLoggedIn_transitionsFromLoggedOutToLoggedIn() {
    // Given: User is logged out
    XCTAssertEqual(userAccount.authState, .loggedOut)
    
    // When: Mark as logged in
    userAccount.markLoggedIn()
    
    // Then: State should be loggedIn
    XCTAssertEqual(userAccount.authState, .loggedIn)
  }
  
  func testRemoveAll_resetsStateToLoggedOut() {
    // Given: User has credentials and is logged in
    userAccount._credentials = .barcodeAndPin(barcode: "test", pin: "1234")
    userAccount.setAuthState(.loggedIn)
    userAccount.setUserID("adobeUser")
    userAccount.setDeviceID("adobeDevice")
    
    // When: Remove all
    userAccount.removeAll()
    
    // Then: State should be loggedOut and credentials cleared
    XCTAssertEqual(userAccount.authState, .loggedOut)
    XCTAssertNil(userAccount.credentials)
    XCTAssertNil(userAccount.userID)
    XCTAssertNil(userAccount.deviceID)
  }
}

// MARK: - Adobe Activation Skip Tests

final class TPPAdobeActivationSkipTests: XCTestCase {
  
  private var businessLogic: TPPSignInBusinessLogic!
  private var libraryAccountMock: TPPLibraryAccountMock!
  private var drmAuthorizer: TPPDRMAuthorizingMock!
  private var uiDelegate: TPPSignInOutBusinessLogicUIDelegateMock!
  private var networkExecutor: TPPRequestExecutorMock!
  private var bookRegistry: TPPBookRegistryMock!
  private var downloadCenter: TPPMyBooksDownloadsCenterMock!
  
  override func setUp() {
    super.setUp()
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
  
  override func tearDown() {
    businessLogic.userAccount.removeAll()
    drmAuthorizer.reset()
    businessLogic = nil
    libraryAccountMock = nil
    drmAuthorizer = nil
    uiDelegate = nil
    networkExecutor = nil
    bookRegistry = nil
    downloadCenter = nil
    super.tearDown()
  }
  
  // MARK: - shouldSkipAdobeActivation Tests
  
  /// Tests that activation is NOT skipped when user is freshly logging in (loggedOut state)
  func testShouldSkipAdobeActivation_falseWhenLoggedOut() {
    // Given: User is logged out (fresh sign-in)
    XCTAssertEqual(businessLogic.userAccount.authState, .loggedOut)
    
    // Then: Should NOT skip activation
    XCTAssertFalse(businessLogic.shouldSkipAdobeActivation())
  }
  
  /// Tests that activation is NOT skipped when user is fully logged in (no stale state)
  func testShouldSkipAdobeActivation_falseWhenLoggedIn() {
    // Given: User is fully logged in
    let userAccount = businessLogic.userAccount as! TPPUserAccountMock
    userAccount._credentials = .barcodeAndPin(barcode: "test", pin: "1234")
    userAccount.setAuthState(.loggedIn)
    userAccount.setUserID("adobeUser")
    userAccount.setDeviceID("adobeDevice")
    
    // Then: Should NOT skip activation (already logged in, not re-authing)
    XCTAssertFalse(businessLogic.shouldSkipAdobeActivation())
  }
  
  /// Tests that activation IS skipped when credentials are stale and Adobe is authorized
  func testShouldSkipAdobeActivation_trueWhenStaleAndAdobeAuthorized() {
    // Given: Credentials are stale but Adobe DRM is still valid
    let userAccount = businessLogic.userAccount as! TPPUserAccountMock
    userAccount._credentials = .barcodeAndPin(barcode: "test", pin: "1234")
    userAccount.setAuthState(.credentialsStale)
    userAccount.setUserID("adobeUser")
    userAccount.setDeviceID("adobeDevice")
    drmAuthorizer.isUserAuthorizedReturnValue = true
    
    // Then: Should skip activation
    XCTAssertTrue(businessLogic.shouldSkipAdobeActivation())
  }
  
  /// Tests that activation is NOT skipped when stale but no Adobe credentials
  func testShouldSkipAdobeActivation_falseWhenStaleButNoAdobeCredentials() {
    // Given: Credentials are stale but no Adobe userID/deviceID
    let userAccount = businessLogic.userAccount as! TPPUserAccountMock
    userAccount._credentials = .barcodeAndPin(barcode: "test", pin: "1234")
    userAccount.setAuthState(.credentialsStale)
    // Note: Not setting userID and deviceID
    
    // Then: Should NOT skip activation (no Adobe credentials to preserve)
    XCTAssertFalse(businessLogic.shouldSkipAdobeActivation())
  }
  
  /// Tests that activation is NOT skipped when stale but Adobe authorization check fails
  func testShouldSkipAdobeActivation_falseWhenStaleButAdobeNotAuthorized() {
    // Given: Credentials are stale but Adobe DRM check returns false
    let userAccount = businessLogic.userAccount as! TPPUserAccountMock
    userAccount._credentials = .barcodeAndPin(barcode: "test", pin: "1234")
    userAccount.setAuthState(.credentialsStale)
    userAccount.setUserID("adobeUser")
    userAccount.setDeviceID("adobeDevice")
    drmAuthorizer.isUserAuthorizedReturnValue = false  // Adobe says not authorized
    
    // Then: Should NOT skip activation (Adobe needs re-activation)
    XCTAssertFalse(businessLogic.shouldSkipAdobeActivation())
  }
  
  // MARK: - State Transition During Sign-In
  
  /// Tests that successful sign-in marks account as loggedIn
  func testUpdateUserAccount_marksLoggedIn() {
    // Given: User with stale credentials
    let userAccount = businessLogic.userAccount as! TPPUserAccountMock
    userAccount.setAuthState(.credentialsStale)
    
    businessLogic.selectedAuthentication = libraryAccountMock.barcodeAuthentication
    
    // When: Update user account after successful auth
    businessLogic.updateUserAccount(
      forDRMAuthorization: true,
      withBarcode: "newBarcode",
      pin: "newPin",
      authToken: nil,
      expirationDate: nil,
      patron: nil,
      cookies: nil
    )
    
    // Then: State should be loggedIn
    XCTAssertEqual(businessLogic.userAccount.authState, .loggedIn)
  }
}

// MARK: - UserAccountPublisher Auth State Tests

@MainActor
final class UserAccountPublisherAuthStateTests: XCTestCase {
  
  private var publisher: UserAccountPublisher!
  private var cancellables: Set<AnyCancellable>!
  
  override func setUp() {
    super.setUp()
    publisher = UserAccountPublisher()
    cancellables = []
  }
  
  override func tearDown() {
    cancellables = nil
    publisher = nil
    super.tearDown()
  }
  
  func testAuthState_defaultsToLoggedOut() {
    XCTAssertEqual(publisher.authState, .loggedOut)
  }
  
  func testMarkCredentialsStale_updatesState() {
    // Given: Publisher starts in loggedIn state
    publisher.markLoggedIn()
    XCTAssertEqual(publisher.authState, .loggedIn)
    
    // When: Mark as stale
    publisher.markCredentialsStale()
    
    // Then: State should be credentialsStale
    XCTAssertEqual(publisher.authState, .credentialsStale)
  }
  
  func testMarkCredentialsStale_doesNotChangeIfNotLoggedIn() {
    // Given: Publisher is logged out
    XCTAssertEqual(publisher.authState, .loggedOut)
    
    // When: Try to mark as stale
    publisher.markCredentialsStale()
    
    // Then: State should remain loggedOut
    XCTAssertEqual(publisher.authState, .loggedOut)
  }
  
  func testCredentialsStalePublisher_firesWhenStateBecomesStale() {
    let expectation = expectation(description: "Stale publisher fires")
    
    publisher.credentialsStalePublisher
      .sink { expectation.fulfill() }
      .store(in: &cancellables)
    
    // Given: Logged in
    publisher.markLoggedIn()
    
    // When: Mark as stale
    publisher.markCredentialsStale()
    
    // Then: Publisher should fire
    waitForExpectations(timeout: 1)
  }
  
  func testAuthStateDidChangePublisher_firesOnStateChanges() {
    var receivedStates: [TPPAccountAuthState] = []
    let expectation = expectation(description: "Received state changes")
    expectation.expectedFulfillmentCount = 3  // loggedOut -> loggedIn -> stale -> loggedIn
    
    publisher.authStateDidChangePublisher
      .dropFirst()  // Skip initial value
      .sink { state in
        receivedStates.append(state)
        expectation.fulfill()
      }
      .store(in: &cancellables)
    
    // Trigger state changes
    publisher.markLoggedIn()
    publisher.markCredentialsStale()
    publisher.markLoggedIn()
    
    waitForExpectations(timeout: 1)
    
    XCTAssertEqual(receivedStates, [.loggedIn, .credentialsStale, .loggedIn])
  }
  
  func testSignOut_resetsToLoggedOut() {
    // Given: Logged in
    publisher.markLoggedIn()
    XCTAssertEqual(publisher.authState, .loggedIn)
    
    // When: Sign out
    publisher.signOut()
    
    // Then: State should be loggedOut
    XCTAssertEqual(publisher.authState, .loggedOut)
  }
}

// MARK: - Integration Test: Full SAML Re-auth Flow

final class TPPSAMLReauthFlowTests: XCTestCase {
  
  /// Simulates the complete SAML session expiry and re-auth flow
  /// to verify that Adobe activation is skipped during re-authentication.
  func testSAMLReauthFlow_skipsAdobeActivation() {
    // Setup
    let libraryAccountMock = TPPLibraryAccountMock()
    let drmAuthorizer = TPPDRMAuthorizingMock()
    let networkExecutor = TPPRequestExecutorMock()
    
    let businessLogic = TPPSignInBusinessLogic(
      libraryAccountID: libraryAccountMock.tppAccountUUID,
      libraryAccountsProvider: libraryAccountMock,
      urlSettingsProvider: TPPURLSettingsProviderMock(),
      bookRegistry: TPPBookRegistryMock(),
      bookDownloadsCenter: TPPMyBooksDownloadsCenterMock(),
      userAccountProvider: TPPUserAccountMock.self,
      networkExecutor: networkExecutor,
      uiDelegate: TPPSignInOutBusinessLogicUIDelegateMock(),
      drmAuthorizer: drmAuthorizer
    )
    
    let userAccount = businessLogic.userAccount as! TPPUserAccountMock
    
    // Step 1: User is initially logged in with valid Adobe credentials
    userAccount._credentials = .barcodeAndPin(barcode: "library_card", pin: "1234")
    userAccount.setAuthState(.loggedIn)
    userAccount.setUserID("adobe_user_123")
    userAccount.setDeviceID("adobe_device_456")
    drmAuthorizer.isUserAuthorizedReturnValue = true
    
    XCTAssertEqual(userAccount.authState, .loggedIn)
    XCTAssertEqual(drmAuthorizer.authorizeCallCount, 0, "No activation yet")
    
    // Step 2: SAML session expires - server returns 401
    // This would normally be triggered by MyBooksDownloadCenter or TPPNetworkResponder
    userAccount.markCredentialsStale()
    
    XCTAssertEqual(userAccount.authState, .credentialsStale)
    XCTAssertTrue(userAccount.authState.hasAdobeActivation, "Adobe should still be valid")
    
    // Step 3: User re-authenticates via SAML IDP
    // Check that we should skip Adobe activation
    XCTAssertTrue(businessLogic.shouldSkipAdobeActivation(),
                  "Should skip Adobe activation for stale credentials with valid Adobe auth")
    
    // Step 4: Simulate successful re-auth (updateUserAccount is called)
    businessLogic.selectedAuthentication = libraryAccountMock.samlAuthentication
    businessLogic.updateUserAccount(
      forDRMAuthorization: true,  // DRM is considered successful (skipped)
      withBarcode: nil,
      pin: nil,
      authToken: "new_saml_token",
      expirationDate: Date().addingTimeInterval(3600),
      patron: ["name": "Test User"],
      cookies: [HTTPCookie(properties: [
        .domain: "idp.example.com",
        .path: "/",
        .name: "session",
        .value: "new_session_value"
      ])!]
    )
    
    // Step 5: Verify final state
    XCTAssertEqual(userAccount.authState, .loggedIn, "Should be logged in after re-auth")
    XCTAssertEqual(drmAuthorizer.authorizeCallCount, 0,
                   "Adobe authorize() should NOT have been called - activation was skipped")
    
    // Cleanup
    businessLogic.userAccount.removeAll()
  }
  
  /// Simulates a fresh login (not re-auth) to verify Adobe activation IS called
  func testFreshLogin_callsAdobeActivation() {
    // Setup
    let libraryAccountMock = TPPLibraryAccountMock()
    let drmAuthorizer = TPPDRMAuthorizingMock()
    
    let businessLogic = TPPSignInBusinessLogic(
      libraryAccountID: libraryAccountMock.tppAccountUUID,
      libraryAccountsProvider: libraryAccountMock,
      urlSettingsProvider: TPPURLSettingsProviderMock(),
      bookRegistry: TPPBookRegistryMock(),
      bookDownloadsCenter: TPPMyBooksDownloadsCenterMock(),
      userAccountProvider: TPPUserAccountMock.self,
      networkExecutor: TPPRequestExecutorMock(),
      uiDelegate: TPPSignInOutBusinessLogicUIDelegateMock(),
      drmAuthorizer: drmAuthorizer
    )
    
    let userAccount = businessLogic.userAccount as! TPPUserAccountMock
    
    // Step 1: User is logged out (fresh login)
    XCTAssertEqual(userAccount.authState, .loggedOut)
    
    // Step 2: Check that we should NOT skip Adobe activation
    XCTAssertFalse(businessLogic.shouldSkipAdobeActivation(),
                   "Should NOT skip Adobe activation for fresh login")
    
    // Cleanup
    businessLogic.userAccount.removeAll()
  }
}
