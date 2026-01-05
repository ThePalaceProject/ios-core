//
//  AuthenticationFlowIntegrationTests.swift
//  PalaceTests
//
//  Integration tests for complete authentication flows
//

import XCTest
@testable import Palace

final class AuthenticationFlowIntegrationTests: XCTestCase {
  
  // MARK: - Properties
  
  private var libraryAccountMock: TPPLibraryAccountMock!
  private var networkExecutor: TPPRequestExecutorMock!
  private var drmAuthorizer: TPPDRMAuthorizingMock!
  private var uiDelegate: TPPSignInOutBusinessLogicUIDelegateMock!
  
  // MARK: - Setup
  
  override func setUpWithError() throws {
    try super.setUpWithError()
    libraryAccountMock = TPPLibraryAccountMock()
    networkExecutor = TPPRequestExecutorMock()
    drmAuthorizer = TPPDRMAuthorizingMock()
    uiDelegate = TPPSignInOutBusinessLogicUIDelegateMock()
  }
  
  override func tearDownWithError() throws {
    libraryAccountMock = nil
    networkExecutor = nil
    drmAuthorizer = nil
    uiDelegate = nil
    try super.tearDownWithError()
  }
  
  // MARK: - Business Logic Creation Tests
  
  func testBasicAuthFlow_createsBusinessLogic() {
    let businessLogic = TPPSignInBusinessLogic(
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
    
    XCTAssertNotNil(businessLogic)
    XCTAssertNotNil(businessLogic.userAccount)
  }
  
  func testBasicAuthFlow_canSelectAuthentication() {
    let businessLogic = TPPSignInBusinessLogic(
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
    
    // Select basic auth
    businessLogic.selectedAuthentication = libraryAccountMock.barcodeAuthentication
    XCTAssertNotNil(businessLogic.selectedAuthentication)
  }
  
  func testBasicAuthFlow_updateUserAccountDoesNotCrash() {
    let businessLogic = TPPSignInBusinessLogic(
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
    
    // Select basic auth
    businessLogic.selectedAuthentication = libraryAccountMock.barcodeAuthentication
    
    // Update credentials should not crash
    businessLogic.updateUserAccount(
      forDRMAuthorization: false,
      withBarcode: "test-barcode",
      pin: "test-pin",
      authToken: nil,
      expirationDate: nil,
      patron: nil,
      cookies: nil
    )
    
    XCTAssertTrue(true, "Update completed without crash")
  }
  
  // MARK: - Token Auth Flow Tests
  
  func testTokenAuthFlow_createsBusinessLogic() {
    let businessLogic = TPPSignInBusinessLogic(
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
    
    // Select OAuth
    businessLogic.selectedAuthentication = libraryAccountMock.oauthAuthentication
    
    XCTAssertNotNil(businessLogic)
  }
  
  func testTokenAuthFlow_updateWithTokenDoesNotCrash() {
    let businessLogic = TPPSignInBusinessLogic(
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
    
    // Select OAuth
    businessLogic.selectedAuthentication = libraryAccountMock.oauthAuthentication
    
    // Update with token should not crash
    let patron = ["name": "Test User"]
    businessLogic.updateUserAccount(
      forDRMAuthorization: false,
      withBarcode: nil,
      pin: nil,
      authToken: "oauth-token-xyz",
      expirationDate: Date().addingTimeInterval(3600),
      patron: patron,
      cookies: nil
    )
    
    XCTAssertTrue(true, "Token update completed without crash")
  }
  
  // MARK: - SAML Auth Flow Tests
  
  func testSAMLAuthFlow_createsBusinessLogic() {
    let businessLogic = TPPSignInBusinessLogic(
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
    
    // Select SAML
    businessLogic.selectedAuthentication = libraryAccountMock.samlAuthentication
    
    XCTAssertNotNil(businessLogic)
  }
  
  // MARK: - User Account Tests
  
  func testUserAccount_removeAllDoesNotCrash() {
    let businessLogic = TPPSignInBusinessLogic(
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
    
    // Remove all should not crash even on fresh account
    businessLogic.userAccount.removeAll()
    
    XCTAssertTrue(true, "Remove all completed without crash")
  }
  
  // MARK: - Auth Definition Tests
  
  func testAuthDefinition_hasRequiredTypes() {
    // Test that mock has required authentication types
    XCTAssertNotNil(libraryAccountMock.barcodeAuthentication)
    XCTAssertNotNil(libraryAccountMock.oauthAuthentication)
    XCTAssertNotNil(libraryAccountMock.samlAuthentication)
  }
  
  func testAuthDefinition_barcodeHasCorrectType() {
    let auth = libraryAccountMock.barcodeAuthentication
    XCTAssertEqual(auth.authType, .basic)
  }
  
  func testAuthDefinition_oauthHasCorrectType() {
    let auth = libraryAccountMock.oauthAuthentication
    XCTAssertEqual(auth.authType, .oauthIntermediary)
  }
  
  func testAuthDefinition_samlHasCorrectType() {
    let auth = libraryAccountMock.samlAuthentication
    XCTAssertEqual(auth.authType, .saml)
  }
}
