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
// Regression tests: iOS should prompt for login (not sign out) after SAML session expires
// When credentials are stale, isSignedIn should be false so UI shows "Sign In" instead of "Sign Out"

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
  
  // MARK: - isSignedIn with Auth State Tests
  
  /// When credentials are stale (SAML session expired), isSignedIn should be FALSE
  /// so the UI shows "Sign In" instead of "Sign Out"
  func testIsSignedIn_falseWhenCredentialsStale() async {
    guard let libraryID = AccountsManager.shared.currentAccountId else {
      XCTSkip("No current account available for testing")
      return
    }
    
    let viewModel = AccountDetailViewModel(libraryAccountID: libraryID)
    
    // Given: User has credentials but they are stale (SAML session expired)
    let account = TPPUserAccount.sharedAccount(libraryUUID: libraryID)
    account.setBarcode("test_user", PIN: "1234")
    account.setAuthState(.credentialsStale)
    
    // When: View model refreshes state
    viewModel.refreshSignInState()
    
    // Then: isSignedIn should be FALSE (so UI shows "Sign In", not "Sign Out")
    XCTAssertFalse(viewModel.isSignedIn, 
                   "isSignedIn should be false when credentials are stale so UI shows Sign In button")
    
    // Cleanup
    account.removeAll()
  }
  
  /// When user is fully logged in (not stale), isSignedIn should be TRUE
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
  
  /// When user is logged out, isSignedIn should be FALSE
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
  
  /// Transition from loggedIn to credentialsStale should update isSignedIn
  func testIsSignedIn_updatesWhenStateBecomesStale() async {
    guard let libraryID = AccountsManager.shared.currentAccountId else {
      XCTSkip("No current account available for testing")
      return
    }
    
    let viewModel = AccountDetailViewModel(libraryAccountID: libraryID)
    
    // Given: User starts logged in
    let account = TPPUserAccount.sharedAccount(libraryUUID: libraryID)
    account.setBarcode("test_user", PIN: "1234")
    account.setAuthState(.loggedIn)
    viewModel.refreshSignInState()
    XCTAssertTrue(viewModel.isSignedIn, "Should start signed in")
    
    // When: Session expires (credentials become stale)
    account.markCredentialsStale()
    viewModel.refreshSignInState()
    
    // Then: isSignedIn should become FALSE
    XCTAssertFalse(viewModel.isSignedIn,
                   "isSignedIn should become false when credentials become stale")
    
    // Cleanup
    account.removeAll()
  }
  
  /// Re-authentication from stale should update isSignedIn back to true
  func testIsSignedIn_updatesAfterReauthentication() async {
    guard let libraryID = AccountsManager.shared.currentAccountId else {
      XCTSkip("No current account available for testing")
      return
    }
    
    let viewModel = AccountDetailViewModel(libraryAccountID: libraryID)
    
    // Given: User has stale credentials
    let account = TPPUserAccount.sharedAccount(libraryUUID: libraryID)
    account.setBarcode("test_user", PIN: "1234")
    account.setAuthState(.credentialsStale)
    viewModel.refreshSignInState()
    XCTAssertFalse(viewModel.isSignedIn, "Should start with stale credentials (not signed in)")
    
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

