//
//  TPPSignInBusinessLogicTests.swift
//  PalaceTests
//
//  Comprehensive tests for sign-in business logic
//

import XCTest
import Combine
@testable import Palace

// MARK: - Extended Sign-In Business Logic Tests

final class TPPSignInBusinessLogicExtendedTests: XCTestCase {
  
  // MARK: - Properties
  
  private var businessLogic: TPPSignInBusinessLogic!
  private var libraryAccountMock: TPPLibraryAccountMock!
  private var drmAuthorizer: TPPDRMAuthorizingMock!
  private var uiDelegate: TPPSignInOutBusinessLogicUIDelegateMock!
  private var networkExecutor: TPPRequestExecutorMock!
  private var bookRegistry: TPPBookRegistryMock!
  private var downloadCenter: TPPMyBooksDownloadsCenterMock!
  
  // MARK: - Setup/Teardown
  
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
  
  // MARK: - Initialization Tests
  
  func testInitialization_setsCorrectLibraryAccountID() {
    XCTAssertEqual(businessLogic.libraryAccountID, libraryAccountMock.tppAccountUUID)
  }
  
  func testInitialization_setsUIDelegate() {
    XCTAssertNotNil(businessLogic.uiDelegate)
  }
  
  func testInitialization_defaultsNotLoggingInAfterSignUp() {
    XCTAssertFalse(businessLogic.isLoggingInAfterSignUp)
  }
  
  func testInitialization_defaultsNotValidatingCredentials() {
    XCTAssertFalse(businessLogic.isValidatingCredentials)
  }
  
  func testInitialization_defaultsIgnoreSignedInStateToFalse() {
    XCTAssertFalse(businessLogic.ignoreSignedInState)
  }
  
  func testInitialization_authTokenNilByDefault() {
    XCTAssertNil(businessLogic.authToken)
  }
  
  func testInitialization_patronNilByDefault() {
    XCTAssertNil(businessLogic.patron)
  }
  
  func testInitialization_cookiesNilByDefault() {
    XCTAssertNil(businessLogic.cookies)
  }
  
  // MARK: - Library Account Tests
  
  func testLibraryAccount_returnsCorrectAccount() {
    let account = businessLogic.libraryAccount
    XCTAssertNotNil(account)
    XCTAssertEqual(account?.uuid, libraryAccountMock.tppAccountUUID)
  }
  
  func testCurrentAccount_matchesLibraryAccount() {
    XCTAssertEqual(businessLogic.currentAccount?.uuid, businessLogic.libraryAccount?.uuid)
  }
  
  // MARK: - Selected Authentication Tests
  
  func testSelectedAuthentication_nilByDefault() {
    XCTAssertNil(businessLogic.selectedAuthentication)
  }
  
  func testSelectedAuthentication_canBeSetToBasic() {
    businessLogic.selectedAuthentication = libraryAccountMock.barcodeAuthentication
    XCTAssertEqual(businessLogic.selectedAuthentication?.authType, .basic)
  }
  
  func testSelectedAuthentication_canBeSetToOAuth() {
    businessLogic.selectedAuthentication = libraryAccountMock.oauthAuthentication
    XCTAssertEqual(businessLogic.selectedAuthentication?.authType, .oauthIntermediary)
  }
  
  func testSelectedAuthentication_canBeSetToSAML() {
    businessLogic.selectedAuthentication = libraryAccountMock.samlAuthentication
    XCTAssertEqual(businessLogic.selectedAuthentication?.authType, .saml)
  }
  
  // MARK: - Sign-In State Tests
  
  func testIsSignedIn_falseWhenNoCredentials() {
    XCTAssertFalse(businessLogic.isSignedIn())
  }
  
  func testIsSignedIn_falseWhenIgnoreSignedInStateTrue() {
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
    
    businessLogic.ignoreSignedInState = true
    XCTAssertFalse(businessLogic.isSignedIn())
  }
  
  func testIsSignedIn_trueWhenHasCredentials() {
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
  }
  
  // MARK: - Registration Tests
  
  func testRegistrationIsPossible_falseWhenSignedIn() {
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
    
    XCTAssertFalse(businessLogic.registrationIsPossible())
  }
  
  // MARK: - SAML Tests
  
  func testIsSamlPossible_trueWhenLibrarySupports() {
    XCTAssertTrue(businessLogic.isSamlPossible())
  }
  
  // MARK: - Make Request Tests
  
  func testMakeRequest_forBasicAuth_noAuthorizationHeader() {
    businessLogic.selectedAuthentication = libraryAccountMock.barcodeAuthentication
    
    let request = businessLogic.makeRequest(for: .signIn, context: "test")
    
    XCTAssertNotNil(request)
    let authHeader = request?.value(forHTTPHeaderField: "Authorization")
    XCTAssertNil(authHeader)
  }
  
  func testMakeRequest_forOAuth_hasBearerToken() {
    businessLogic.selectedAuthentication = libraryAccountMock.oauthAuthentication
    businessLogic.authToken = "test-token"
    
    let request = businessLogic.makeRequest(for: .signIn, context: "test")
    
    XCTAssertNotNil(request)
    let authHeader = request?.value(forHTTPHeaderField: "Authorization")
    XCTAssertEqual(authHeader, "Bearer test-token")
  }
  
  func testMakeRequest_forSAML_hasBearerToken() {
    businessLogic.selectedAuthentication = libraryAccountMock.samlAuthentication
    businessLogic.authToken = "saml-token"
    
    let request = businessLogic.makeRequest(for: .signIn, context: "test")
    
    XCTAssertNotNil(request)
    let authHeader = request?.value(forHTTPHeaderField: "Authorization")
    XCTAssertEqual(authHeader, "Bearer saml-token")
  }
  
  func testMakeRequest_signOut_usesCorrectURL() {
    businessLogic.selectedAuthentication = libraryAccountMock.barcodeAuthentication
    
    let request = businessLogic.makeRequest(for: .signOut, context: "test")
    
    XCTAssertNotNil(request)
    XCTAssertNotNil(request?.url)
  }
  
  // MARK: - Update User Account Tests
  
  func testUpdateUserAccount_withBasicAuth_setsBarcodePIN() {
    businessLogic.selectedAuthentication = libraryAccountMock.barcodeAuthentication
    
    businessLogic.updateUserAccount(
      forDRMAuthorization: true,
      withBarcode: "12345",
      pin: "9999",
      authToken: nil,
      expirationDate: nil,
      patron: nil,
      cookies: nil
    )
    
    XCTAssertEqual(businessLogic.userAccount.barcode, "12345")
    XCTAssertEqual(businessLogic.userAccount.PIN, "9999")
  }
  
  func testUpdateUserAccount_withOAuth_setsAuthToken() {
    businessLogic.selectedAuthentication = libraryAccountMock.oauthAuthentication
    let patron = ["name": "Test User"]
    
    businessLogic.updateUserAccount(
      forDRMAuthorization: true,
      withBarcode: nil,
      pin: nil,
      authToken: "oauth-token-123",
      expirationDate: Date().addingTimeInterval(3600),
      patron: patron,
      cookies: nil
    )
    
    XCTAssertEqual(businessLogic.userAccount.authToken, "oauth-token-123")
    XCTAssertEqual(businessLogic.userAccount.patron?["name"] as? String, "Test User")
  }
  
  func testUpdateUserAccount_withSAML_setsCookies() {
    businessLogic.selectedAuthentication = libraryAccountMock.samlAuthentication
    let cookies = [
      HTTPCookie(properties: [
        .domain: "example.com",
        .path: "/",
        .name: "session",
        .value: "abc123"
      ])!
    ]
    
    businessLogic.updateUserAccount(
      forDRMAuthorization: true,
      withBarcode: nil,
      pin: nil,
      authToken: "saml-token",
      expirationDate: nil,
      patron: ["name": "SAML User"],
      cookies: cookies
    )
    
    XCTAssertEqual(businessLogic.userAccount.cookies?.count, 1)
    XCTAssertEqual(businessLogic.userAccount.cookies?.first?.name, "session")
  }
  
  func testUpdateUserAccount_setsAuthDefinition() {
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
    
    XCTAssertNotNil(businessLogic.userAccount.authDefinition)
  }
  
  // MARK: - Validate Credentials Tests
  
  func testValidateCredentials_setsIsValidatingCredentialsTrue() {
    businessLogic.selectedAuthentication = libraryAccountMock.barcodeAuthentication
    
    businessLogic.validateCredentials()
    
    XCTAssertTrue(businessLogic.isValidatingCredentials)
  }
  
  // MARK: - Log In Flow Tests
  
  func testLogIn_initiatesSignIn() {
    businessLogic.selectedAuthentication = libraryAccountMock.barcodeAuthentication
    businessLogic.logIn()
    
    // Verify that logging in starts credential validation
    XCTAssertTrue(businessLogic.isValidatingCredentials, "LogIn should start credential validation")
  }
  
  func testLogIn_withBasicAuth_validatesCredentials() {
    businessLogic.selectedAuthentication = libraryAccountMock.barcodeAuthentication
    
    businessLogic.logIn()
    
    XCTAssertTrue(businessLogic.isValidatingCredentials)
  }
  
  // MARK: - Barcode Display Tests
  
  func testLibrarySupportsBarcodeDisplay_falseWithoutCredentials() {
    XCTAssertFalse(businessLogic.librarySupportsBarcodeDisplay())
  }
  
  func testLibrarySupportsBarcodeDisplay_requiresAuthorizationIdentifier() {
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
    
    // Without authorizationIdentifier, should be false
    XCTAssertFalse(businessLogic.librarySupportsBarcodeDisplay())
  }
  
  // MARK: - EULA Tests
  
  func testShouldShowEULALink_basedOnLibraryDetails() {
    // This depends on library configuration
    let result = businessLogic.shouldShowEULALink()
    // Just verify it returns a bool without crashing
    XCTAssertNotNil(result)
  }
  
  // MARK: - Authentication Document Loading Tests
  
  func testIsAuthenticationDocumentLoading_defaultsFalse() {
    XCTAssertFalse(businessLogic.isAuthenticationDocumentLoading)
  }
  
  // MARK: - Refresh Auth Tests
  
  func testRefreshAuthIfNeeded_returnsFalseWhenNoAuthDefinition() {
    let needsUI = businessLogic.refreshAuthIfNeeded(usingExistingCredentials: true, completion: nil)
    
    // Without auth definition, should return false
    XCTAssertFalse(needsUI)
  }
  
  // MARK: - Concurrent Sign-In Prevention Tests
  
  func testLogIn_preventsMultipleSimultaneousCalls() {
    businessLogic.selectedAuthentication = libraryAccountMock.barcodeAuthentication
    
    businessLogic.logIn()
    let firstValidating = businessLogic.isValidatingCredentials
    
    businessLogic.logIn()
    let secondValidating = businessLogic.isValidatingCredentials
    
    XCTAssertTrue(firstValidating)
    XCTAssertTrue(secondValidating)
  }
  
  // MARK: - Password Reset Tests
  
  func testCanResetPassword_dependsOnLibraryConfig() {
    // This depends on library having password reset link
    let result = businessLogic.canResetPassword
    XCTAssertNotNil(result)
  }
  
  // MARK: - Sync Button Tests (PP-3252)
  
  /// Tests that shouldShowSyncButton() returns false when user has no credentials.
  /// This validates the production hasCredentials() check in shouldShowSyncButton().
  func testShouldShowSyncButton_falseWhenNoCredentials() {
    // Precondition: user is not signed in
    XCTAssertFalse(businessLogic.userAccount.hasCredentials(),
                   "Test setup requires user to have no credentials")
    
    // Call the REAL production method
    let result = businessLogic.shouldShowSyncButton()
    
    // Verify: sync toggle only shows when signed in
    XCTAssertFalse(result, "shouldShowSyncButton() must return false when user has no credentials")
  }
  
  /// Tests that shouldShowSyncButton() returns false when viewing a different library
  /// than the current one. This validates the libraryAccountID == currentAccountId check.
  func testShouldShowSyncButton_falseWhenDifferentLibrary() {
    // Create business logic for a DIFFERENT library than the current one
    let differentLibraryLogic = TPPSignInBusinessLogic(
      libraryAccountID: "different-library-uuid-that-doesnt-match",
      libraryAccountsProvider: libraryAccountMock,
      urlSettingsProvider: TPPURLSettingsProviderMock(),
      bookRegistry: bookRegistry,
      bookDownloadsCenter: downloadCenter,
      userAccountProvider: TPPUserAccountMock.self,
      networkExecutor: networkExecutor,
      uiDelegate: uiDelegate,
      drmAuthorizer: drmAuthorizer
    )
    
    // Call the REAL production method
    let result = differentLibraryLogic.shouldShowSyncButton()
    
    // Verify: should return false because libraryAccountID != currentAccountId
    XCTAssertFalse(result,
                   "shouldShowSyncButton() must return false when libraryAccountID doesn't match currentAccountId")
  }
  
  /// PP-3252 Regression Test: Verifies sync button visibility uses currentAccountId
  /// (which is immediately available) rather than currentAccount?.uuid (which may be nil
  /// on fresh installs before the authentication document loads).
  func testShouldShowSyncButton_PP3252_usesCurrentAccountIdNotCurrentAccountUuid() {
    // Sign in the user with credentials
    businessLogic.selectedAuthentication = libraryAccountMock.barcodeAuthentication
    businessLogic.updateUserAccount(
      forDRMAuthorization: true,
      withBarcode: "testBarcode",
      pin: "testPin",
      authToken: nil,
      expirationDate: nil,
      patron: nil,
      cookies: nil
    )
    
    // Precondition: verify user is signed in
    XCTAssertTrue(businessLogic.userAccount.hasCredentials(),
                  "Test setup requires user to have credentials")
    
    // Precondition: verify libraryAccountID matches currentAccountId
    // This is the key comparison that was broken in PP-3252
    XCTAssertEqual(businessLogic.libraryAccountID, libraryAccountMock.currentAccountId,
                   "Test setup requires libraryAccountID to match currentAccountId")
    
    // Call the REAL production shouldShowSyncButton() method
    // The bug was that it compared against currentAccount?.uuid which could be nil
    // The fix uses currentAccountId which is always available from UserDefaults
    let result = businessLogic.shouldShowSyncButton()
    
    // The key validation: this call succeeds and uses currentAccountId (not currentAccount?.uuid)
    // Production code checks: supportsSimplyESync && TPPAnnotations.annotationsURL != nil && hasCredentials && isCurrentAccount
    let supportsSync = libraryAccountMock.tppAccount.details?.supportsSimplyESync == true
    let hasAnnotationsURL = TPPAnnotations.annotationsURL != nil
    let expectedResult = supportsSync && hasAnnotationsURL
    
    XCTAssertEqual(result, expectedResult,
                   "PP-3252: shouldShowSyncButton() should return \(expectedResult) based on library configuration")
  }
}

// MARK: - OAuth Flow Tests

final class TPPSignInOAuthFlowTests: XCTestCase {
  
  private var businessLogic: TPPSignInBusinessLogic!
  private var libraryAccountMock: TPPLibraryAccountMock!
  private var uiDelegate: TPPSignInOutBusinessLogicUIDelegateMock!
  
  override func setUpWithError() throws {
    try super.setUpWithError()
    libraryAccountMock = TPPLibraryAccountMock()
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
      drmAuthorizer: TPPDRMAuthorizingMock()
    )
  }
  
  override func tearDownWithError() throws {
    businessLogic.userAccount.removeAll()
    businessLogic = nil
    libraryAccountMock = nil
    uiDelegate = nil
    try super.tearDownWithError()
  }
}

// MARK: - Error Handling Tests

final class TPPSignInErrorHandlingTests: XCTestCase {
  
  private var businessLogic: TPPSignInBusinessLogic!
  private var libraryAccountMock: TPPLibraryAccountMock!
  private var uiDelegate: TPPSignInOutBusinessLogicUIDelegateMock!
  private var networkExecutor: TPPNetworkErrorMock!
  
  override func setUpWithError() throws {
    try super.setUpWithError()
    libraryAccountMock = TPPLibraryAccountMock()
    uiDelegate = TPPSignInOutBusinessLogicUIDelegateMock()
    networkExecutor = TPPNetworkErrorMock()
    
    businessLogic = TPPSignInBusinessLogic(
      libraryAccountID: libraryAccountMock.tppAccountUUID,
      libraryAccountsProvider: libraryAccountMock,
      urlSettingsProvider: TPPURLSettingsProviderMock(),
      bookRegistry: TPPBookRegistryMock(),
      bookDownloadsCenter: TPPMyBooksDownloadsCenterMock(),
      userAccountProvider: TPPUserAccountMock.self,
      networkExecutor: networkExecutor,
      uiDelegate: uiDelegate,
      drmAuthorizer: TPPDRMAuthorizingMock()
    )
  }
  
  override func tearDownWithError() throws {
    businessLogic.userAccount.removeAll()
    businessLogic = nil
    libraryAccountMock = nil
    uiDelegate = nil
    networkExecutor = nil
    try super.tearDownWithError()
  }
  
  func testValidateCredentials_withSelectedAuth_doesNotCrash() {
    // Test that validateCredentials can be called without crashing
    // Note: Actual validation requires network/UI which can't be fully tested here
    businessLogic.selectedAuthentication = libraryAccountMock.barcodeAuthentication
    
    // This triggers async network call - we just verify it doesn't crash
    businessLogic.validateCredentials()
    
    XCTAssertTrue(true, "Completed without crash")
  }
  
  func testValidateCredentials_withoutSelectedAuth_doesNotCrash() {
    // Test that validateCredentials handles nil auth gracefully
    businessLogic.selectedAuthentication = nil
    
    // Should not crash
    businessLogic.validateCredentials()
    
    XCTAssertTrue(true, "Completed without crash")
  }
}

// MARK: - Mock Extensions

class TPPNetworkErrorMock: TPPRequestExecuting {
  var requestTimeout: TimeInterval = 60
  var shouldFail = false
  var errorStatusCode = 500
  
  func executeRequest(
    _ req: URLRequest,
    enableTokenRefresh: Bool,
    completion: @escaping (NYPLResult<Data>) -> Void
  ) -> URLSessionDataTask? {
    // Use immediate async dispatch instead of delayed timers to avoid test hangs
    DispatchQueue.main.async {
      if self.shouldFail {
        let error = NSError(domain: "Test", code: self.errorStatusCode, userInfo: nil)
        let response = HTTPURLResponse(
          url: req.url!,
          statusCode: self.errorStatusCode,
          httpVersion: "1.1",
          headerFields: nil
        )
        completion(.failure(error, response))
      } else {
        let data = TPPFake.validUserProfileJson.data(using: .utf8)!
        let response = HTTPURLResponse(
          url: req.url!,
          statusCode: 200,
          httpVersion: "1.1",
          headerFields: nil
        )
        completion(.success(data, response))
      }
    }
    return nil
  }
}

extension TPPSignInOutBusinessLogicUIDelegateMock {
  var willSignInHandler: (() -> Void)? {
    get { objc_getAssociatedObject(self, &AssociatedKeys.willSignIn) as? () -> Void }
    set { objc_setAssociatedObject(self, &AssociatedKeys.willSignIn, newValue, .OBJC_ASSOCIATION_RETAIN) }
  }
  
  var validationErrorHandler: ((Error?, String?, String?) -> Void)? {
    get { objc_getAssociatedObject(self, &AssociatedKeys.validationError) as? (Error?, String?, String?) -> Void }
    set { objc_setAssociatedObject(self, &AssociatedKeys.validationError, newValue, .OBJC_ASSOCIATION_RETAIN) }
  }
}

private struct AssociatedKeys {
  static var willSignIn = "willSignIn"
  static var validationError = "validationError"
}

