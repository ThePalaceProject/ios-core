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
  }
  
  func signOut() {
    isSigningOut = true
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

