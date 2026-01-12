//
//  AccountDetailViewModelTests.swift
//  PalaceTests
//
//  Created for testing AccountDetailViewModel (SignIn) functionality.
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
}

