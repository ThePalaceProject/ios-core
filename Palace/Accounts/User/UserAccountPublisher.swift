//
//  UserAccountPublisher.swift
//  Palace
//
//  Copyright © 2025 The Palace Project. All rights reserved.
//

import Foundation
import Combine

/// Modern Combine-based user account state publisher
/// Replaces notification-based patterns with type-safe publishers
@MainActor
final class UserAccountPublisher: ObservableObject {
  
  // MARK: - Published State
  
  /// The current authentication state of the account.
  /// Use this to determine if the user is logged in, logged out, or has stale credentials.
  @Published private(set) var authState: TPPAccountAuthState = .loggedOut
  
  /// Backwards-compatible property that returns true if the account has any stored credentials.
  /// Note: This returns true for both `.loggedIn` and `.credentialsStale` states.
  @Published private(set) var hasCredentials: Bool = false
  
  @Published private(set) var authToken: String?
  @Published private(set) var barcode: String?
  @Published private(set) var patronName: String?
  @Published private(set) var isSigningOut: Bool = false
  
  // MARK: - Publishers
  
  /// Publishes when account credentials change (sign in/out)
  var credentialsDidChangePublisher: AnyPublisher<Bool, Never> {
    $hasCredentials
      .removeDuplicates()
      .eraseToAnyPublisher()
  }
  
  /// Publishes when user signs out
  var didSignOutPublisher: AnyPublisher<Void, Never> {
    $isSigningOut
      .filter { $0 }
      .map { _ in () }
      .eraseToAnyPublisher()
  }
  
  /// Publishes when credentials become stale (e.g., after receiving a 401).
  /// UI can observe this to prompt the user to re-authenticate.
  var credentialsStalePublisher: AnyPublisher<Void, Never> {
    $authState
      .removeDuplicates()
      .filter { $0 == .credentialsStale }
      .map { _ in () }
      .eraseToAnyPublisher()
  }
  
  /// Publishes auth state changes
  var authStateDidChangePublisher: AnyPublisher<TPPAccountAuthState, Never> {
    $authState
      .removeDuplicates()
      .eraseToAnyPublisher()
  }
  
  /// Publishes any account state change
  var accountDidChangePublisher: AnyPublisher<Void, Never> {
    Publishers.Merge4(
      $hasCredentials.map { _ in () },
      $authToken.map { _ in () },
      $barcode.map { _ in () },
      $patronName.map { _ in () }
    )
    .eraseToAnyPublisher()
  }
  
  // MARK: - Internal Update Methods
  
  func updateState(from account: TPPUserAccount) {
    hasCredentials = account.hasCredentials()
    authToken = account.authToken
    barcode = account.barcode
    patronName = account.patronFullName
    authState = account.authState
  }
  
  /// Marks the current account's credentials as stale.
  /// This should be called when a 401 is received for an authenticated request.
  /// The account retains its Adobe DRM activation but needs re-authentication.
  func markCredentialsStale() {
    guard authState == .loggedIn else {
      Log.debug(#file, "Cannot mark credentials stale - current state is \(authState)")
      return
    }
    
    Log.info(#file, "Marking credentials as stale (Adobe activation preserved)")
    authState = .credentialsStale
    
    // Also update the persisted state in TPPUserAccount
    TPPUserAccount.sharedAccount().setAuthState(.credentialsStale)
  }
  
  /// Marks the account as fully logged in.
  /// This should be called after successful authentication.
  func markLoggedIn() {
    Log.info(#file, "Marking account as logged in")
    authState = .loggedIn
    hasCredentials = true
  }
  
  func signOut() {
    isSigningOut = true
    authState = .loggedOut
    hasCredentials = false
    authToken = nil
    barcode = nil
    patronName = nil
    
    // Reset flag after a brief delay to allow subscribers to react
    Task {
      try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
      isSigningOut = false
    }
  }
}

// MARK: - Global Publisher Instance

extension UserAccountPublisher {
  /// Shared publisher for observing account state changes
  /// Use this instead of NotificationCenter for account-related events
  static let shared = UserAccountPublisher()
}

