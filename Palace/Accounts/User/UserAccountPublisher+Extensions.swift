//
//  UserAccountPublisher+Extensions.swift
//  Palace
//
//  Copyright © 2025 The Palace Project. All rights reserved.
//

import Foundation
import Combine
import SwiftUI

// MARK: - Convenience Publishers

extension UserAccountPublisher {
  
  /// Publisher that fires once when user signs in (transitions from no credentials to has credentials)
  var didSignInPublisher: AnyPublisher<Void, Never> {
    $hasCredentials
      .removeDuplicates()
      .dropFirst() // Skip initial value
      .filter { $0 } // Only when true
      .map { _ in () }
      .eraseToAnyPublisher()
  }
  
  /// Publisher that fires when barcode changes
  var barcodeDidChangePublisher: AnyPublisher<String?, Never> {
    $barcode
      .removeDuplicates()
      .eraseToAnyPublisher()
  }
  
  /// Publisher that fires when patron name is available
  var patronNamePublisher: AnyPublisher<String?, Never> {
    $patronName
      .removeDuplicates()
      .eraseToAnyPublisher()
  }
}

// MARK: - SwiftUI View Modifiers

extension View {
  
  /// Observes account credentials and performs action when credentials change
  /// - Parameter action: Closure called with hasCredentials state
  func onAccountCredentialsChange(perform action: @escaping (Bool) -> Void) -> some View {
    self.modifier(AccountCredentialsObserver(action: action))
  }
  
  /// Observes account sign-out and performs action
  /// - Parameter action: Closure called when user signs out
  func onAccountSignOut(perform action: @escaping () -> Void) -> some View {
    self.modifier(AccountSignOutObserver(action: action))
  }
  
  /// Observes account sign-in and performs action
  /// - Parameter action: Closure called when user signs in
  func onAccountSignIn(perform action: @escaping () -> Void) -> some View {
    self.modifier(AccountSignInObserver(action: action))
  }
}

// MARK: - View Modifiers Implementation

private struct AccountCredentialsObserver: ViewModifier {
  @StateObject private var publisher = UserAccountPublisher.shared
  let action: (Bool) -> Void
  
  func body(content: Content) -> some View {
    content.onChange(of: publisher.hasCredentials, perform: action)
  }
}

private struct AccountSignOutObserver: ViewModifier {
  @StateObject private var publisher = UserAccountPublisher.shared
  let action: () -> Void
  
  func body(content: Content) -> some View {
    content.onChange(of: publisher.isSigningOut) { isSigningOut in
      if isSigningOut {
        action()
      }
    }
  }
}

private struct AccountSignInObserver: ViewModifier {
  @StateObject private var publisher = UserAccountPublisher.shared
  @State private var previousState = false
  let action: () -> Void
  
  func body(content: Content) -> some View {
    content.onChange(of: publisher.hasCredentials) { hasCredentials in
      // Fire only on transition from false -> true
      if hasCredentials && !previousState {
        action()
      }
      previousState = hasCredentials
    }
  }
}

// MARK: - Combine Operators

extension Publisher where Output == Void, Failure == Never {
  
  /// Throttles void events to avoid rapid-fire updates
  /// - Parameter interval: Minimum time between events
  func throttleVoid(for interval: RunLoop.SchedulerTimeType.Stride) -> AnyPublisher<Void, Never> {
    self
      .map { Date() }
      .removeDuplicates(by: { abs($0.timeIntervalSince($1)) < interval.magnitude })
      .map { _ in () }
      .eraseToAnyPublisher()
  }
}

// MARK: - Testing Support

#if DEBUG
extension UserAccountPublisher {
  
  /// Resets publisher state for testing
  func resetForTesting() {
    // Create mock account state
    let mockAccount = TPPUserAccount.sharedAccount()
    updateState(from: mockAccount)
  }
  
  /// Simulates sign in for testing
  func simulateSignIn(barcode: String, patronName: String?) {
    // Use actual account to trigger real state changes
    TPPUserAccount.sharedAccount().setBarcode(barcode, PIN: "test")
  }
  
  /// Simulates sign out for testing
  func simulateSignOut() {
    signOut()
  }
}
#endif

