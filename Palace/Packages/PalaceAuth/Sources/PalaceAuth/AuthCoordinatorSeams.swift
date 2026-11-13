//
//  AuthCoordinatorSeams.swift
//  PalaceAuth
//
//  Protocol seams that let `AuthCoordinator` reach the main-target
//  re-authenticator and sign-in modal without importing main-target types.
//  Kept narrow on purpose: every member becomes public surface.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import PalaceCatalog

// MARK: - AuthMechanism (internal dispatch helper, exposed for tests)

/// Family of auth mechanisms the coordinator can dispatch to. Mirrors
/// `AccountDetails.Authentication.authType` from the main target without
/// importing the rich type. Tests construct cases directly; production
/// translates from `AccountDetails.Authentication` at the call site.
///
/// The coordinator uses this to decide whether a silent refresh is
/// possible (`.basic`, `.token`) or whether the user must complete a
/// browser/modal flow (`.saml`, `.oidc`, `.oauthIntermediary`).
public enum AuthMechanism: Equatable, Sendable {
    case basic
    case token
    case oauthIntermediary
    case saml
    case oidc

    /// True for mechanisms that route through an out-of-process browser
    /// or in-app web view — these cannot complete without user
    /// interaction, so the coordinator surfaces a modal.
    public var requiresBrowserFlow: Bool {
        switch self {
        case .saml, .oidc, .oauthIntermediary: return true
        case .basic, .token: return false
        }
    }
}

// MARK: - Reauthenticating

/// The main-target type that knows how to drive a silent token refresh
/// or trigger a basic-auth retry without surfacing UI. `AuthCoordinator`
/// calls this for non-browser mechanisms (`.basic`, `.token`).
///
/// `TPPReauthenticator` (main target) conforms; tests use a spy.
public protocol Reauthenticating: AnyObject, Sendable {
    /// Drive a re-auth attempt using credentials already in the keychain
    /// (silent path). For `.token`, this triggers the bearer-token
    /// refresh endpoint. For `.basic`, this re-issues the cached
    /// barcode + PIN.
    ///
    /// - Parameter usingExistingCredentials: when `true`, the silent path
    ///   runs; when `false`, the caller is asking for a full interactive
    ///   re-auth (the coordinator routes that to the modal presenter
    ///   instead and never calls this with `false`).
    /// - Returns: `true` if re-auth succeeded, `false` if it failed
    ///   without a definitive answer (e.g., network blip). A `false`
    ///   result means the coordinator MAY fall back to surfacing a modal.
    func authenticateIfNeeded(usingExistingCredentials: Bool) async -> Bool
}

// MARK: - SignInModalPresenting

/// The main-target type that presents the SignIn modal (basic prompt,
/// SAML web sheet, OIDC ASWebAuthenticationSession, or OAuth-intermediary
/// Universal Link). `AuthCoordinator` calls this for any mechanism that
/// requires browser flow, or as a fallback when silent refresh isn't
/// applicable.
///
/// `SignInModalPresenter` (main target) conforms; tests use a spy.
public protocol SignInModalPresenting: AnyObject, Sendable {
    /// Present the sign-in modal for the currently-selected library
    /// account. The implementation selects the appropriate UI (web sheet
    /// vs basic prompt) based on the account's authentication document.
    ///
    /// - Returns: `true` if the user completed sign-in, `false` if they
    ///   cancelled or the flow errored out.
    func presentSignInModalForCurrentAccount() async -> Bool
}

// MARK: - TPPUserAccountReading

/// Narrow read slice of `TPPUserAccount`. The coordinator only needs to
/// know whether credentials are present and whether the auth token is
/// expired — it does NOT read patron details or keychain internals.
///
/// The full split is described in `docs/3.2.0-auth-deps.md`.
public protocol TPPUserAccountReading: AnyObject, Sendable {
    /// True when there's a stored credential (bearer token, basic pair,
    /// or SAML cookies). Persisted in keychain per library UUID.
    var hasCredentials: Bool { get }

    /// True when the stored bearer-token expiration date has passed.
    /// Always false for basic-auth and SAML accounts (no expiration
    /// tracked client-side).
    var authTokenHasExpired: Bool { get }
}

// MARK: - TPPUserAccountWriting

/// Narrow write slice of `TPPUserAccount`. The coordinator only writes
/// the credentials-stale marker before fanning out a refresh attempt.
public protocol TPPUserAccountWriting: AnyObject, Sendable {
    /// Mark the current credentials as stale so that the next consumer
    /// observes `authState == .credentialsStale` and waits for the
    /// coordinator's re-auth result instead of issuing a fresh request
    /// with the dead token.
    func markCredentialsStale()
}

// MARK: - TPPCurrentLibraryAccountProviding

/// The main-target type that exposes "which library account is active
/// right now". The coordinator reads `currentAccountMechanism` to decide
/// how to dispatch. Implementations are responsible for thread-safety —
/// the coordinator calls this from its actor context but expects sync
/// reads to be safe.
///
/// `AccountsManager` (main target) conforms; tests use a spy. Only the
/// current account's `AuthMechanism` is exposed, not the full `Account`.
public protocol TPPCurrentLibraryAccountProviding: AnyObject {
    /// The auth mechanism for the currently-selected library account, or
    /// `nil` when no library is selected (cold launch, between accounts
    /// during library swap, etc.). `nil` is a signal to the coordinator
    /// that it cannot drive a refresh and should return
    /// `.noActiveAccount`.
    var currentAccountMechanism: AuthMechanism? { get }
}
