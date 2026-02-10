//
//  TPPReauthenticatorMock.swift
//  PalaceTests
//
//  Mock implementation of Reauthenticator for testing bookmark sync
//  with stale credentials scenarios.
//

import Foundation
@testable import Palace

/// Mock implementation of the Reauthenticator protocol for testing.
/// Allows tests to control authentication behavior without UI interaction.
class TPPReauthenticatorMock: NSObject, Reauthenticator {
  
  // MARK: - Test Configuration
  
  /// Whether re-authentication should succeed
  var shouldSucceed: Bool = true
  
  /// Delay before calling completion (simulates async auth)
  var completionDelay: TimeInterval = 0
  
  /// Tracks if authenticateIfNeeded was called
  private(set) var authenticateIfNeededCalled = false
  
  /// Tracks the usingExistingCredentials parameter
  private(set) var lastUsingExistingCredentials: Bool?
  
  /// Number of times authenticateIfNeeded was called
  private(set) var authenticateCallCount = 0
  
  /// Closure to execute custom behavior during authentication
  var onAuthenticate: ((_ user: TPPUserAccount, _ usingExisting: Bool) -> Void)?
  
  // MARK: - Reauthenticator Protocol
  
  func authenticateIfNeeded(
    _ user: TPPUserAccount,
    usingExistingCredentials: Bool,
    authenticationCompletion: (() -> Void)?
  ) {
    authenticateIfNeededCalled = true
    authenticateCallCount += 1
    lastUsingExistingCredentials = usingExistingCredentials
    
    // Execute custom behavior if provided
    onAuthenticate?(user, usingExistingCredentials)
    
    // Call completion after optional delay
    if completionDelay > 0 {
      DispatchQueue.main.asyncAfter(deadline: .now() + completionDelay) {
        authenticationCompletion?()
      }
    } else {
      authenticationCompletion?()
    }
  }
  
  // MARK: - Test Helpers
  
  /// Resets the mock to its initial state
  func reset() {
    shouldSucceed = true
    completionDelay = 0
    authenticateIfNeededCalled = false
    lastUsingExistingCredentials = nil
    authenticateCallCount = 0
    onAuthenticate = nil
  }
}
