//
//  TPPReauthenticatorTests.swift
//  PalaceTests
//
//  Tests for reauthentication handling
//

import XCTest
@testable import Palace

/// Note: TPPReauthenticator requires UI presentation (SignInModalPresenter) which cannot
/// be tested in unit tests. Use TPPReauthenticatorMockTests for testing reauthentication logic.
final class TPPReauthenticatorTests: XCTestCase {
  
  // MARK: - Properties
  
  private var reauthenticator: TPPReauthenticator!
  private var userAccount: TPPUserAccountMock!
  
  // MARK: - Setup/Teardown
  
  override func setUpWithError() throws {
    try super.setUpWithError()
    reauthenticator = TPPReauthenticator()
    userAccount = TPPUserAccountMock()
  }
  
  override func tearDownWithError() throws {
    reauthenticator = nil
    userAccount = nil
    try super.tearDownWithError()
  }
  
  // MARK: - Initialization Tests
  
  func testInit_createsInstance() {
    XCTAssertNotNil(reauthenticator)
  }
  
  func testInit_isNSObjectSubclass() {
    XCTAssertTrue(reauthenticator is NSObject)
  }
  
  func testInit_conformsToReauthenticatorProtocol() {
    XCTAssertTrue(reauthenticator is Reauthenticator)
  }
  
  func testAuthenticateIfNeeded_withNilCompletion_doesNotCrash() {
    // Should not crash when completion is nil
    // Note: This triggers UI presentation which won't complete in tests
    reauthenticator.authenticateIfNeeded(userAccount, usingExistingCredentials: true, authenticationCompletion: nil)
    
    XCTAssertTrue(true, "Completed without crash")
  }
}

// MARK: - Mock Reauthenticator Tests

final class TPPReauthenticatorMockTests: XCTestCase {
  
  private var mockReauthenticator: TPPReauthenticatorMock!
  private var userAccount: TPPUserAccountMock!
  
  override func setUpWithError() throws {
    try super.setUpWithError()
    mockReauthenticator = TPPReauthenticatorMock()
    userAccount = TPPUserAccountMock()
  }
  
  override func tearDownWithError() throws {
    mockReauthenticator = nil
    userAccount = nil
    try super.tearDownWithError()
  }
  
  func testMockReauthenticator_tracksReauthPerformed() {
    XCTAssertFalse(mockReauthenticator.reauthenticationPerformed)
    
    mockReauthenticator.authenticateIfNeeded(userAccount, usingExistingCredentials: true, authenticationCompletion: nil)
    
    XCTAssertTrue(mockReauthenticator.reauthenticationPerformed)
  }
  
  func testMockReauthenticator_callsCompletion() {
    let expectation = expectation(description: "Mock completion called")
    
    mockReauthenticator.authenticateIfNeeded(userAccount, usingExistingCredentials: true) {
      expectation.fulfill()
    }
    
    wait(for: [expectation], timeout: 1.0)
  }
}

