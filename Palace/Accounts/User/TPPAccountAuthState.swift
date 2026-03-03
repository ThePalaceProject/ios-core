//
//  TPPAccountAuthState.swift
//  Palace
//
//  Copyright © 2025 The Palace Project. All rights reserved.
//

import Foundation

/// Represents the authentication state of a user account.
///
/// This state machine distinguishes between:
/// - `loggedOut`: No credentials, Adobe DRM deactivated
/// - `loggedIn`: Full credentials, Adobe DRM activated
/// - `credentialsStale`: Session expired but Adobe DRM still valid (e.g., SAML cookie expiry)
///
/// The `credentialsStale` state is critical for preventing unnecessary Adobe device activations
/// when users simply need to refresh their session (e.g., after SAML cookie expiration).
/// Re-authenticating from `credentialsStale` skips Adobe activation since the device is still authorized.
///
/// State Transitions:
/// ```
/// loggedOut ──[sign in]──▶ loggedIn
/// loggedIn ──[401 received]──▶ credentialsStale
/// loggedIn ──[sign out]──▶ loggedOut (triggers Adobe deactivation)
/// credentialsStale ──[re-auth]──▶ loggedIn (skips Adobe activation)
/// credentialsStale ──[sign out]──▶ loggedOut (triggers Adobe deactivation)
/// ```
@objc enum TPPAccountAuthState: Int, Codable, CustomStringConvertible {
  /// No credentials stored. Adobe DRM has been deactivated.
  /// This is the initial state for new accounts and the state after explicit sign-out.
  case loggedOut = 0
  
  /// Fully authenticated with valid credentials. Adobe DRM is activated.
  /// This is the normal operating state for signed-in users.
  case loggedIn = 1
  
  /// Session/token has expired but Adobe DRM credentials remain valid.
  /// This state is entered when a 401 is received for an authenticated request.
  /// Re-authentication from this state should skip Adobe activation.
  case credentialsStale = 2
  
  var description: String {
    switch self {
    case .loggedOut:
      return "loggedOut"
    case .loggedIn:
      return "loggedIn"
    case .credentialsStale:
      return "credentialsStale"
    }
  }
  
  /// Whether the account has any form of credentials (even if stale)
  var hasStoredCredentials: Bool {
    return self != .loggedOut
  }
  
  /// Whether the account needs re-authentication before making authenticated requests
  var needsReauthentication: Bool {
    return self == .credentialsStale || self == .loggedOut
  }
  
  /// Whether Adobe DRM is expected to be activated for this account
  var hasAdobeActivation: Bool {
    return self == .loggedIn || self == .credentialsStale
  }
}
