//
//  TPPReauthenticator.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 11/18/20.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

import Foundation
import UIKit

protocol Reauthenticator: NSObject {
    func authenticateIfNeeded(_ user: TPPUserAccount,
                              usingExistingCredentials: Bool,
                              authenticationCompletion: (() -> Void)?)
}

/// This class is a front-end for taking care of situations where an
/// already authenticated user somehow sees its requests fail with a 401
/// HTTP status as it the request lacked proper authentication.
///
/// This typically involves refreshing the authentication token and, depending
/// on the chosen authentication method, opening up a sign-in VC to interact
/// with the user.
///
/// This class takes care of initializing the VC's UI, its business logic,
/// opening up the VC when needed, and performing the log-in request under
/// the hood when no user input is needed.
@objc class TPPReauthenticator: NSObject, Reauthenticator {

    /// Test-observable counter of how many times `authenticateIfNeeded`
    /// has been invoked on this instance. Used by security tests to
    /// verify single-flight behavior at upstream call sites
    /// (e.g. `TokenRefreshInterceptor.isRequestingCredentials` dedupe).
    /// Not used for any production logic.
    public private(set) var authenticateCallCount: Int = 0

    /// Re-authenticates the user. This may involve presenting the sign-in
    /// modal UI or not, depending on the sign-in business logic.
    ///
    /// - Parameters:
    ///   - user: The current user.
    ///   - usingExistingCredentials: Use the existing credentials for `user`.
    ///   - authenticationCompletion: Code to run after the authentication
    ///   flow completes.
    @objc func authenticateIfNeeded(_ user: TPPUserAccount,
                                    usingExistingCredentials: Bool,
                                    authenticationCompletion: (() -> Void)?) {
        authenticateCallCount += 1
        Task { @MainActor in
            Log.info(#file, "TPPReauthenticator: Re-authentication requested, using existing credentials: \(usingExistingCredentials)")

            // Use new SwiftUI sign-in modal
            SignInModalPresenter.presentSignInModalForCurrentAccount {
                Log.info(#file, "TPPReauthenticator: Re-authentication completed")
                authenticationCompletion?()
            }
        }
    }
}

// MARK: - SAMLReauthCoordinator

/// Single-flight coordinator for browser-based (SAML/OIDC) re-authentication.
///
/// Without this, `TPPNetworkResponder` marks the account `.credentialsStale`
/// when /patrons/me/ or /loans/ returns 401 but no UI ever surfaces — SAML
/// users are left polling 401s forever with no way to recover short of
/// uninstalling the app. HelpSpot 17716 (Cornell SAML).
///
/// We can't simply call `SignInModalPresenter` from the responder on every
/// 401: loans-refresh polls fire continuously while stale, which would stack
/// modals. The publisher's `removeDuplicates()` only deduplicates on state
/// transitions, so once the account is stale every subsequent 401 still
/// flows in. This coordinator dedupes via an `isPresenting` flag plus a
/// foreground gate.
@MainActor
final class SAMLReauthCoordinator {

    static let shared = SAMLReauthCoordinator()

    /// True while the sign-in modal owned by this coordinator is on screen.
    /// Reset when the modal's completion fires (whether the user signed in
    /// or cancelled). Visible for tests.
    private(set) var isPresenting: Bool = false

    private let reauthenticator: Reauthenticator
    private let applicationStateProvider: () -> UIApplication.State

    init(reauthenticator: Reauthenticator = TPPReauthenticator(),
         applicationStateProvider: @escaping () -> UIApplication.State = { UIApplication.shared.applicationState }) {
        self.reauthenticator = reauthenticator
        self.applicationStateProvider = applicationStateProvider
    }

    /// Present the SAML/OIDC re-auth modal if all preconditions hold:
    /// browser-based reauth strategy, account in `.credentialsStale`,
    /// app foreground, no other reauth modal already presenting.
    ///
    /// Caller (typically `TPPNetworkResponder`) may invoke on every 401 —
    /// the coordinator's gates make repeated calls cheap and idempotent.
    func requestReauth(for user: TPPUserAccount,
                       authDef: AccountDetails.Authentication?,
                       triggerURL: URL?) {
        let urlStr = triggerURL?.absoluteString ?? "<nil>"
        let strategy = String(describing: authDef?.reauthStrategy)
        Log.info(#file, "[SAML-REAUTH] requestReauth url=\(urlStr) state=\(user.authState) strategy=\(strategy)")

        guard authDef?.reauthStrategy == .browser else {
            Log.info(#file, "[SAML-REAUTH] skip: reauthStrategy is not .browser (got \(strategy))")
            return
        }
        guard user.authState == .credentialsStale else {
            Log.info(#file, "[SAML-REAUTH] skip: authState is \(user.authState), not .credentialsStale")
            return
        }
        let appState = applicationStateProvider()
        guard appState == .active else {
            Log.info(#file, "[SAML-REAUTH] skip: app not active (state.rawValue=\(appState.rawValue))")
            return
        }
        guard !isPresenting else {
            Log.info(#file, "[SAML-REAUTH] skip: another reauth modal already presenting")
            return
        }

        isPresenting = true
        Log.info(#file, "[SAML-REAUTH] presenting sign-in modal for browser-based reauth")
        reauthenticator.authenticateIfNeeded(user, usingExistingCredentials: true) { [weak self] in
            Task { @MainActor in
                guard let self = self else { return }
                self.isPresenting = false
                Log.info(#file, "[SAML-REAUTH] modal dismissed; isPresenting reset")
            }
        }
    }

    /// Test-only: reset the single-flight flag without going through the
    /// modal. Production code must never call this.
    func _resetForTesting() {
        isPresenting = false
    }
}
