//
//  TPPReauthenticator+Reauthenticating.swift
//  Palace
//
//  Bridges the existing `TPPReauthenticator` (Obj-C-flavored,
//  closure-based) to PalaceAuth's `Reauthenticating` protocol used by
//  `AuthCoordinator`. Coordinator-mediated re-auth routes through this
//  3-line extension so the coordinator never has to import main-target
//  types.
//
//  Module C of swarm_66819d80.
//

import Foundation
import PalaceAuth

extension TPPReauthenticator: Reauthenticating {

    /// Bridge from the actor-friendly async surface to the existing
    /// closure-based `authenticateIfNeeded` on `TPPReauthenticator`. The
    /// underlying implementation always presents the SwiftUI sign-in
    /// modal — true silent refresh for `.basic` / `.token` is wired
    /// separately at the network layer via token refresh. For the
    /// coordinator's purposes, the modal completion is the success
    /// signal.
    ///
    /// - Parameter usingExistingCredentials: forwarded to the legacy
    ///   surface. `true` means "try silent first"; `false` means "force
    ///   the modal". The coordinator currently only invokes this with
    ///   `true` (silent path) — the modal-routed mechanisms call
    ///   `SignInModalPresenting.presentSignInModalForCurrentAccount`
    ///   directly instead.
    /// - Returns: `true` when the user account has credentials after the
    ///   completion fires (modal completed or silent refresh succeeded);
    ///   `false` on cancel / no credentials.
    public func authenticateIfNeeded(usingExistingCredentials: Bool) async -> Bool {
        let userAccount = AppContainer.production().accountsManager.currentUserAccount
        return await withCheckedContinuation { continuation in
            self.authenticateIfNeeded(
                userAccount,
                usingExistingCredentials: usingExistingCredentials,
                authenticationCompletion: {
                    let hasCreds = userAccount.hasCredentials()
                    continuation.resume(returning: hasCreds)
                }
            )
        }
    }
}
