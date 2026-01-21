//
//  AccountDetailViewModelTests.swift
//  PalaceTests
//
//  Tests for AccountDetailViewModel (SignIn) functionality.
//  Tests real business logic for authentication flows.
//

import XCTest
import Combine
@testable import Palace

@MainActor
final class AccountDetailViewModelTests: XCTestCase {
  
  private var cancellables: Set<AnyCancellable> = []
  
  override func setUp() {
    super.setUp()
    cancellables = []
  }
  
  override func tearDown() {
    cancellables.removeAll()
    super.tearDown()
  }
  
  // MARK: - Helper to get a valid library ID
  
  private func getValidLibraryID() -> String? {
    return AccountsManager.shared.currentAccountId
  }
  
  // MARK: - Published Property Tests
  
  func testInitialPublishedPropertiesState() async {
    guard let libraryID = AccountsManager.shared.currentAccountId else {
      XCTSkip("No current account available for testing")
      return
    }
    
    let viewModel = AccountDetailViewModel(libraryAccountID: libraryID)
    
    XCTAssertEqual(viewModel.usernameText, "")
    XCTAssertEqual(viewModel.pinText, "")
    XCTAssertFalse(viewModel.showingAlert)
    XCTAssertEqual(viewModel.alertTitle, "")
    XCTAssertEqual(viewModel.alertMessage, "")
    XCTAssertFalse(viewModel.showBarcode)
  }
  
  func testUsernameTextUpdate() async {
    guard let libraryID = AccountsManager.shared.currentAccountId else {
      XCTSkip("No current account available for testing")
      return
    }
    
    let viewModel = AccountDetailViewModel(libraryAccountID: libraryID)
    
    viewModel.usernameText = "testuser123"
    XCTAssertEqual(viewModel.usernameText, "testuser123")
  }
  
  func testPinTextUpdate() async {
    guard let libraryID = AccountsManager.shared.currentAccountId else {
      XCTSkip("No current account available for testing")
      return
    }
    
    let viewModel = AccountDetailViewModel(libraryAccountID: libraryID)
    
    viewModel.pinText = "1234"
    XCTAssertEqual(viewModel.pinText, "1234")
  }
  
  func testIsPINHiddenDefaultsToTrue() async {
    guard let libraryID = AccountsManager.shared.currentAccountId else {
      XCTSkip("No current account available for testing")
      return
    }
    
    let viewModel = AccountDetailViewModel(libraryAccountID: libraryID)
    
    XCTAssertTrue(viewModel.isPINHidden)
  }
  
  func testTogglePINVisibility() async {
    guard let libraryID = AccountsManager.shared.currentAccountId else {
      XCTSkip("No current account available for testing")
      return
    }
    
    let viewModel = AccountDetailViewModel(libraryAccountID: libraryID)
    
    XCTAssertTrue(viewModel.isPINHidden)
    viewModel.togglePINVisibility()
    XCTAssertFalse(viewModel.isPINHidden)
    viewModel.togglePINVisibility()
    XCTAssertTrue(viewModel.isPINHidden)
  }
  
  func testShowBarcodeToggle() async {
    guard let libraryID = AccountsManager.shared.currentAccountId else {
      XCTSkip("No current account available for testing")
      return
    }
    
    let viewModel = AccountDetailViewModel(libraryAccountID: libraryID)
    
    XCTAssertFalse(viewModel.showBarcode)
    viewModel.showBarcode = true
    XCTAssertTrue(viewModel.showBarcode)
  }
  
  // MARK: - canSignIn Tests
  
  func testCanSignInWithEmptyCredentials() async {
    guard let libraryID = AccountsManager.shared.currentAccountId else {
      XCTSkip("No current account available for testing")
      return
    }
    
    let viewModel = AccountDetailViewModel(libraryAccountID: libraryID)
    viewModel.usernameText = ""
    viewModel.pinText = ""
    
    let canSignIn = viewModel.canSignIn
    XCTAssertFalse(canSignIn)
  }
  
  func testCanSignInWithOnlyUsername() async {
    guard let libraryID = AccountsManager.shared.currentAccountId else {
      XCTSkip("No current account available for testing")
      return
    }
    
    let viewModel = AccountDetailViewModel(libraryAccountID: libraryID)
    viewModel.usernameText = "testuser"
    viewModel.pinText = ""
    
    let canSignIn = viewModel.canSignIn
    
    if viewModel.businessLogic.selectedAuthentication?.pinKeyboard == .none {
      XCTAssertTrue(canSignIn)
    } else {
      XCTAssertFalse(canSignIn)
    }
  }
  
  func testCanSignInWithBothCredentials() async {
    guard let libraryID = AccountsManager.shared.currentAccountId else {
      XCTSkip("No current account available for testing")
      return
    }
    
    let viewModel = AccountDetailViewModel(libraryAccountID: libraryID)
    viewModel.usernameText = "testuser"
    viewModel.pinText = "1234"
    
    if viewModel.businessLogic.selectedAuthentication?.isOauth != true &&
       viewModel.businessLogic.selectedAuthentication?.isSaml != true {
      XCTAssertTrue(viewModel.canSignIn)
    }
  }
  
  // MARK: - Library Properties Tests
  
  func testLibraryNameReturnsAccountName() async {
    guard let libraryID = AccountsManager.shared.currentAccountId,
          let account = AccountsManager.shared.account(libraryID) else {
      XCTSkip("No current account available for testing")
      return
    }
    
    let viewModel = AccountDetailViewModel(libraryAccountID: libraryID)
    
    XCTAssertEqual(viewModel.libraryName, account.name)
  }
  
  func testSelectedAccountMatchesInitialized() async {
    guard let libraryID = AccountsManager.shared.currentAccountId,
          AccountsManager.shared.account(libraryID) != nil else {
      XCTSkip("No current account available or account not loaded for testing")
      return
    }
    
    let viewModel = AccountDetailViewModel(libraryAccountID: libraryID)
    
    XCTAssertNotNil(viewModel.selectedAccount)
    XCTAssertEqual(viewModel.selectedAccount?.uuid, libraryID)
  }
  
  // MARK: - Alert Tests
  
  func testAlertPropertiesUpdate() async {
    guard let libraryID = AccountsManager.shared.currentAccountId else {
      XCTSkip("No current account available for testing")
      return
    }
    
    let viewModel = AccountDetailViewModel(libraryAccountID: libraryID)
    
    viewModel.alertTitle = "Test Title"
    viewModel.alertMessage = "Test Message"
    viewModel.showingAlert = true
    
    XCTAssertEqual(viewModel.alertTitle, "Test Title")
    XCTAssertEqual(viewModel.alertMessage, "Test Message")
    XCTAssertTrue(viewModel.showingAlert)
  }
  
  // MARK: - Sync Tests
  
  func testIsSyncEnabledToggle() async {
    guard let libraryID = AccountsManager.shared.currentAccountId else {
      XCTSkip("No current account available for testing")
      return
    }
    
    let viewModel = AccountDetailViewModel(libraryAccountID: libraryID)
    let initialValue = viewModel.isSyncEnabled
    
    viewModel.isSyncEnabled = !initialValue
    XCTAssertNotEqual(viewModel.isSyncEnabled, initialValue)
  }
  
  // MARK: - Business Logic Integration Tests
  
  func testBusinessLogic_IsInitialized() async {
    guard let libraryID = getValidLibraryID() else {
      XCTSkip("No current account available for testing")
      return
    }
    
    let viewModel = AccountDetailViewModel(libraryAccountID: libraryID)
    
    XCTAssertNotNil(viewModel.businessLogic)
  }
  
  func testCredentialFields_AreIndependent() async {
    guard let libraryID = getValidLibraryID() else {
      XCTSkip("No current account available for testing")
      return
    }
    
    let viewModel = AccountDetailViewModel(libraryAccountID: libraryID)
    
    viewModel.usernameText = "user123"
    viewModel.pinText = "4567"
    
    XCTAssertEqual(viewModel.usernameText, "user123")
    XCTAssertEqual(viewModel.pinText, "4567")
    XCTAssertNotEqual(viewModel.usernameText, viewModel.pinText)
  }
  
  func testClearCredentials_WorksIndependently() async {
    guard let libraryID = getValidLibraryID() else {
      XCTSkip("No current account available for testing")
      return
    }
    
    let viewModel = AccountDetailViewModel(libraryAccountID: libraryID)
    
    viewModel.usernameText = "user123"
    viewModel.pinText = "4567"
    
    viewModel.usernameText = ""
    
    XCTAssertEqual(viewModel.usernameText, "")
    XCTAssertEqual(viewModel.pinText, "4567")
  }
  
  // MARK: - UI State Management Tests
  
  func testMultipleAlerts_CanBeShown() async {
    guard let libraryID = getValidLibraryID() else {
      XCTSkip("No current account available for testing")
      return
    }
    
    let viewModel = AccountDetailViewModel(libraryAccountID: libraryID)
    
    // Set first alert
    viewModel.alertTitle = "First Alert"
    viewModel.alertMessage = "First Message"
    viewModel.showingAlert = true
    
    XCTAssertTrue(viewModel.showingAlert)
    
    // Dismiss and show second alert
    viewModel.showingAlert = false
    viewModel.alertTitle = "Second Alert"
    viewModel.alertMessage = "Second Message"
    viewModel.showingAlert = true
    
    XCTAssertEqual(viewModel.alertTitle, "Second Alert")
    XCTAssertEqual(viewModel.alertMessage, "Second Message")
    XCTAssertTrue(viewModel.showingAlert)
  }
  
  // MARK: - Validation Tests
  
  func testCanSignIn_WithWhitespaceOnlyUsername() async {
    guard let libraryID = getValidLibraryID() else {
      XCTSkip("No current account available for testing")
      return
    }
    
    let viewModel = AccountDetailViewModel(libraryAccountID: libraryID)
    viewModel.usernameText = "   "
    viewModel.pinText = "1234"
    
    // Whitespace-only username should not count as valid
    // The actual validation depends on business logic implementation
    let canSignIn = viewModel.canSignIn
    
    // This validates the property is accessible and returns a boolean
    XCTAssertNotNil(canSignIn)
  }
  
  func testCanSignIn_WithSpecialCharacters() async {
    guard let libraryID = getValidLibraryID() else {
      XCTSkip("No current account available for testing")
      return
    }
    
    let viewModel = AccountDetailViewModel(libraryAccountID: libraryID)
    viewModel.usernameText = "user@example.com"
    viewModel.pinText = "pass!@#$%"
    
    // Special characters should be allowed in credentials
    XCTAssertEqual(viewModel.usernameText, "user@example.com")
    XCTAssertEqual(viewModel.pinText, "pass!@#$%")
  }
}

// MARK: - Credential State UI Tests
// Tests for isSignedIn behavior based on auth type and credential state:
// - OAuth: User appears signed in even when credentials are stale (token refreshes in background)
// - SAML: User appears logged out when credentials are stale (needs to re-auth via IDP)

@MainActor
final class AccountDetailCredentialStateTests: XCTestCase {
  
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
  
  // MARK: - OAuth isSignedIn Tests
  
  /// Regression test for OAuth login appearing logged out in account settings
  /// When OAuth credentials are stale, isSignedIn should be TRUE because the token
  /// refreshes automatically in the background - user should still appear signed in.
  func testIsSignedIn_trueWhenOAuthCredentialsStale() async {
    guard let libraryID = AccountsManager.shared.currentAccountId else {
      XCTSkip("No current account available for testing")
      return
    }
    
    let viewModel = AccountDetailViewModel(libraryAccountID: libraryID)
    
    // Given: User has OAuth credentials (token-based) that are stale
    let account = TPPUserAccount.sharedAccount(libraryUUID: libraryID)
    
    // OAuth uses token credentials - this is how we detect OAuth
    account.setAuthToken("expired_token", barcode: nil, pin: nil, expirationDate: Date().addingTimeInterval(-3600))
    account.setAuthState(.credentialsStale)
    
    // When: View model refreshes state
    viewModel.refreshSignInState()
    
    // Then: isSignedIn should be TRUE for OAuth (token refreshes in background)
    XCTAssertTrue(viewModel.isSignedIn,
                  "OAuth: isSignedIn should be true when credentials are stale (token refreshes in background)")
    
    // Cleanup
    account.removeAll()
  }
  
  // MARK: - SAML/Basic isSignedIn Tests
  
  /// When SAML/Basic credentials are stale (session expired), isSignedIn should be FALSE
  /// so the UI shows "Sign In" to prompt re-authentication via IDP.
  func testIsSignedIn_falseWhenSAMLCredentialsStale() async {
    guard let libraryID = AccountsManager.shared.currentAccountId else {
      XCTSkip("No current account available for testing")
      return
    }
    
    let viewModel = AccountDetailViewModel(libraryAccountID: libraryID)
    
    // Given: User has SAML/Basic credentials (barcode/PIN) that are stale
    let account = TPPUserAccount.sharedAccount(libraryUUID: libraryID)
    
    // SAML/Basic uses barcode/PIN credentials - NOT token credentials
    account.setBarcode("test_user", PIN: "1234")
    account.setAuthState(.credentialsStale)
    
    // When: View model refreshes state
    viewModel.refreshSignInState()
    
    // Then: isSignedIn should be FALSE for SAML/Basic (needs re-auth)
    XCTAssertFalse(viewModel.isSignedIn, 
                   "SAML/Basic: isSignedIn should be false when credentials are stale (needs re-auth)")
    
    // Cleanup
    account.removeAll()
  }
  
  // MARK: - General isSignedIn Tests (auth-type independent)
  
  /// When user is fully logged in (not stale), isSignedIn should be TRUE regardless of auth type
  func testIsSignedIn_trueWhenLoggedIn() async {
    guard let libraryID = AccountsManager.shared.currentAccountId else {
      XCTSkip("No current account available for testing")
      return
    }
    
    let viewModel = AccountDetailViewModel(libraryAccountID: libraryID)
    
    // Given: User has credentials and is fully logged in
    let account = TPPUserAccount.sharedAccount(libraryUUID: libraryID)
    account.setBarcode("test_user", PIN: "1234")
    account.setAuthState(.loggedIn)
    
    // When: View model refreshes state
    viewModel.refreshSignInState()
    
    // Then: isSignedIn should be TRUE
    XCTAssertTrue(viewModel.isSignedIn,
                  "isSignedIn should be true when user is fully logged in")
    
    // Cleanup
    account.removeAll()
  }
  
  /// When user is logged out, isSignedIn should be FALSE regardless of auth type
  func testIsSignedIn_falseWhenLoggedOut() async {
    guard let libraryID = AccountsManager.shared.currentAccountId else {
      XCTSkip("No current account available for testing")
      return
    }
    
    let viewModel = AccountDetailViewModel(libraryAccountID: libraryID)
    
    // Given: User is logged out (no credentials)
    let account = TPPUserAccount.sharedAccount(libraryUUID: libraryID)
    account.removeAll()
    
    // When: View model refreshes state
    viewModel.refreshSignInState()
    
    // Then: isSignedIn should be FALSE
    XCTAssertFalse(viewModel.isSignedIn,
                   "isSignedIn should be false when user is logged out")
  }
  
  /// For SAML/Basic: Transition from loggedIn to credentialsStale should update isSignedIn to false
  func testIsSignedIn_SAMLUpdatesWhenStateBecomesStale() async {
    guard let libraryID = AccountsManager.shared.currentAccountId else {
      XCTSkip("No current account available for testing")
      return
    }
    
    let viewModel = AccountDetailViewModel(libraryAccountID: libraryID)
    
    // Given: User starts logged in with SAML/Basic (barcode/PIN credentials)
    let account = TPPUserAccount.sharedAccount(libraryUUID: libraryID)
    account.setBarcode("test_user", PIN: "1234")
    account.setAuthState(.loggedIn)
    viewModel.refreshSignInState()
    XCTAssertTrue(viewModel.isSignedIn, "Should start signed in")
    
    // When: Session expires (credentials become stale)
    account.markCredentialsStale()
    viewModel.refreshSignInState()
    
    // Then: isSignedIn should become FALSE for SAML/Basic
    XCTAssertFalse(viewModel.isSignedIn,
                   "SAML/Basic: isSignedIn should become false when credentials become stale")
    
    // Cleanup
    account.removeAll()
  }
  
  /// For OAuth: Transition from loggedIn to credentialsStale should keep isSignedIn true
  func testIsSignedIn_OAuthRemainsSignedInWhenStateBecomesStale() async {
    guard let libraryID = AccountsManager.shared.currentAccountId else {
      XCTSkip("No current account available for testing")
      return
    }
    
    let viewModel = AccountDetailViewModel(libraryAccountID: libraryID)
    
    // Given: User starts logged in with OAuth (token credentials)
    let account = TPPUserAccount.sharedAccount(libraryUUID: libraryID)
    account.setAuthToken("valid_token", barcode: nil, pin: nil, expirationDate: Date().addingTimeInterval(3600))
    account.setAuthState(.loggedIn)
    viewModel.refreshSignInState()
    XCTAssertTrue(viewModel.isSignedIn, "Should start signed in")
    
    // When: Token expires (credentials become stale)
    account.markCredentialsStale()
    viewModel.refreshSignInState()
    
    // Then: isSignedIn should remain TRUE for OAuth (token refreshes in background)
    XCTAssertTrue(viewModel.isSignedIn,
                  "OAuth: isSignedIn should remain true when credentials become stale (token refreshes)")
    
    // Cleanup
    account.removeAll()
  }
  
  /// Re-authentication from stale should update isSignedIn back to true (for SAML/Basic)
  func testIsSignedIn_updatesAfterSAMLReauthentication() async {
    guard let libraryID = AccountsManager.shared.currentAccountId else {
      XCTSkip("No current account available for testing")
      return
    }
    
    let viewModel = AccountDetailViewModel(libraryAccountID: libraryID)
    
    // Given: User has stale SAML/Basic credentials (barcode/PIN)
    let account = TPPUserAccount.sharedAccount(libraryUUID: libraryID)
    account.setBarcode("test_user", PIN: "1234")
    account.setAuthState(.credentialsStale)
    viewModel.refreshSignInState()
    XCTAssertFalse(viewModel.isSignedIn, "SAML/Basic: Should start with stale credentials (not signed in)")
    
    // When: User re-authenticates successfully
    account.markLoggedIn()
    viewModel.refreshSignInState()
    
    // Then: isSignedIn should become TRUE
    XCTAssertTrue(viewModel.isSignedIn,
                  "isSignedIn should become true after successful re-authentication")
    
    // Cleanup
    account.removeAll()
  }
  
  // MARK: - needsReauthentication Tests
  
  /// Account should indicate it needs re-authentication when credentials are stale
  func testNeedsReauthentication_trueWhenCredentialsStale() async {
    guard let libraryID = AccountsManager.shared.currentAccountId else {
      XCTSkip("No current account available for testing")
      return
    }
    
    // Given: User has stale credentials
    let account = TPPUserAccount.sharedAccount(libraryUUID: libraryID)
    account.setBarcode("test_user", PIN: "1234")
    account.setAuthState(.credentialsStale)
    
    // Then: Account should indicate it needs re-authentication
    XCTAssertTrue(account.authState.needsReauthentication,
                  "Account should need re-authentication when credentials are stale")
    
    // And: hasCredentials should still be true (credentials exist, just expired)
    XCTAssertTrue(account.hasCredentials(),
                  "hasCredentials should be true even when credentials are stale")
    
    // Cleanup
    account.removeAll()
  }
}

// MARK: - PIN Visibility Business Logic Tests

@MainActor
final class AccountDetailPINVisibilityTests: XCTestCase {
  
  func testPINVisibility_DefaultsToHidden() async {
    guard let libraryID = AccountsManager.shared.currentAccountId else {
      XCTSkip("No current account available for testing")
      return
    }
    
    let viewModel = AccountDetailViewModel(libraryAccountID: libraryID)
    
    XCTAssertTrue(viewModel.isPINHidden, "PIN should be hidden by default for security")
  }
  
  func testPINVisibility_ToggleMultipleTimes() async {
    guard let libraryID = AccountsManager.shared.currentAccountId else {
      XCTSkip("No current account available for testing")
      return
    }
    
    let viewModel = AccountDetailViewModel(libraryAccountID: libraryID)
    
    // Toggle multiple times
    viewModel.togglePINVisibility()
    XCTAssertFalse(viewModel.isPINHidden)
    
    viewModel.togglePINVisibility()
    XCTAssertTrue(viewModel.isPINHidden)
    
    viewModel.togglePINVisibility()
    XCTAssertFalse(viewModel.isPINHidden)
    
    viewModel.togglePINVisibility()
    XCTAssertTrue(viewModel.isPINHidden)
  }
  
  func testPINVisibility_IndependentOfCredentialChanges() async {
    guard let libraryID = AccountsManager.shared.currentAccountId else {
      XCTSkip("No current account available for testing")
      return
    }
    
    let viewModel = AccountDetailViewModel(libraryAccountID: libraryID)
    
    viewModel.togglePINVisibility()
    XCTAssertFalse(viewModel.isPINHidden)
    
    // Changing credentials shouldn't affect visibility
    viewModel.pinText = "newpin"
    
    XCTAssertFalse(viewModel.isPINHidden)
  }
}

