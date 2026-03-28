//
//  UserAccountAuthState.swift
//  Palace
//
//  Extracted from TPPUserAccount to isolate token management,
//  expiry checking, and credential state logic.
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation

/// Provides auth-state queries and token lifecycle logic without owning storage.
/// All state is read through the `TPPUserAccountProvider` protocol (i.e. TPPUserAccount).
///
/// Thread-safety note: callers are responsible for ensuring the underlying
/// account's `libraryUUID` is stable when calling these methods (e.g. via
/// `accountInfoQueue` barrier or `credentialSnapshot`).
@objcMembers
class UserAccountAuthHelper: NSObject {

    // MARK: - Token Expiry

    private enum TokenExpiry {
        static let refreshThresholdSeconds: TimeInterval = 300  // 5 minutes
    }

    /// Returns `true` when an auth-token credential exists and its expiration date is in the past.
    /// Returns `false` when there is no token or the token has no expiration.
    static func isTokenExpired(credentials: TPPCredentials?) -> Bool {
        guard let credentials = credentials,
              case let TPPCredentials.token(authToken: _, barcode: _, pin: _, expirationDate: expirationDate) = credentials else {
            return false
        }
        guard let expirationDate = expirationDate else {
            return false  // No expiration = doesn't expire
        }
        return expirationDate <= Date()
    }

    /// Returns `true` when an auth-token credential exists and will expire within 5 minutes.
    /// Useful for proactive refresh before making requests.
    static func isTokenNearExpiry(credentials: TPPCredentials?) -> Bool {
        guard let credentials = credentials,
              case let TPPCredentials.token(authToken: _, barcode: _, pin: _, expirationDate: expirationDate) = credentials,
              let expirationDate = expirationDate else {
            return false
        }
        let expiryThreshold = Date().addingTimeInterval(TokenExpiry.refreshThresholdSeconds)
        return expirationDate <= expiryThreshold
    }

    /// Extracts the raw auth token string from credentials, if present.
    static func authToken(from credentials: TPPCredentials?) -> String? {
        guard let credentials = credentials,
              case let TPPCredentials.token(authToken: token, barcode: _, pin: _, expirationDate: _) = credentials else {
            return nil
        }
        return token
    }

    // MARK: - Credential Checks

    static func hasBarcodeAndPIN(credentials: TPPCredentials?) -> Bool {
        guard let credentials = credentials, case .barcodeAndPin = credentials else {
            return false
        }
        return true
    }

    static func hasAuthToken(credentials: TPPCredentials?) -> Bool {
        guard let credentials = credentials, case .token = credentials else {
            return false
        }
        return true
    }

    static func hasCredentials(_ credentials: TPPCredentials?) -> Bool {
        return hasAuthToken(credentials: credentials) || hasBarcodeAndPIN(credentials: credentials)
    }

    // MARK: - Barcode / PIN extraction

    static func barcode(from credentials: TPPCredentials?) -> String? {
        guard let credentials = credentials else { return nil }
        switch credentials {
        case let .barcodeAndPin(barcode: barcode, pin: _):
            return barcode
        case let .token(_, barcode, _, _):
            return barcode
        default:
            return nil
        }
    }

    static func pin(from credentials: TPPCredentials?) -> String? {
        guard let credentials = credentials else { return nil }
        switch credentials {
        case let .barcodeAndPin(barcode: _, pin: pin):
            return pin
        case let .token(_, _, pin, _):
            return pin
        default:
            return nil
        }
    }

    // MARK: - Token Refresh Logic

    /// Determines whether a token refresh is required given the current auth definition and credentials.
    static func isTokenRefreshRequired(
        authDefinition: AccountDetails.Authentication?,
        credentials: TPPCredentials?,
        username: String?,
        pin: String?
    ) -> Bool {
        guard let authDefinition = authDefinition else { return false }

        let tokenExpired = isTokenExpired(credentials: credentials)

        if authDefinition.isToken {
            guard authDefinition.tokenURL != nil,
                  username != nil,
                  pin != nil else {
                return false
            }
            return tokenExpired
        }

        let isOAuthAndNeedsRefresh = authDefinition.isOauth &&
            !hasAuthToken(credentials: credentials) &&
            (authDefinition.tokenURL != nil)

        return (tokenExpired || isOAuthAndNeedsRefresh) && hasCredentials(credentials)
    }

    // MARK: - Auth State Resolution

    /// Resolves the effective auth state from a stored state and current credentials.
    /// Used by both live account access and atomic snapshots.
    static func resolveAuthState(
        storedState: TPPAccountAuthState?,
        hasCredentials: Bool
    ) -> TPPAccountAuthState {
        if let storedState = storedState {
            if storedState.hasStoredCredentials && !hasCredentials {
                return .loggedOut
            }
            return storedState
        }
        return hasCredentials ? .loggedIn : .loggedOut
    }

    // MARK: - Auth Requirements

    static func needsAuth(authDefinition: AccountDetails.Authentication?) -> Bool {
        let authType = authDefinition?.authType ?? .none
        return authType == .basic || authType == .oauthIntermediary || authType == .saml || authType == .token
    }

    static func needsAgeCheck(authDefinition: AccountDetails.Authentication?) -> Bool {
        return authDefinition?.authType == .coppa
    }

    static func catalogRequiresAuthentication(authDefinition: AccountDetails.Authentication?) -> Bool {
        return authDefinition?.catalogRequiresAuthentication ?? false
    }

    // MARK: - Patron Name

    static func patronFullName(from patron: [String: Any]?) -> String? {
        guard let patron = patron,
              let name = patron["name"] as? [String: String] else {
            return nil
        }

        var fullname = ""

        if let first = name["first"] {
            fullname.append(first)
        }
        if let middle = name["middle"] {
            if !fullname.isEmpty { fullname.append(" ") }
            fullname.append(middle)
        }
        if let last = name["last"] {
            if !fullname.isEmpty { fullname.append(" ") }
            fullname.append(last)
        }

        return fullname.isEmpty ? nil : fullname
    }
}
