//
//  SignInModalPresenter+SignInModalPresenting.swift
//  Palace
//
//  Bridges the existing static-API `SignInModalPresenter` to PalaceAuth's
//  `SignInModalPresenting` protocol used by `AuthCoordinator`. A 1-method
//  adapter on a small helper class keeps the actor + protocol design
//  intact without changing the existing static-API callers.
//
//  Module C of swarm_66819d80.
//

import Foundation
import PalaceAuth

/// Adapter conforming the static `SignInModalPresenter` API to the
/// instance-method `SignInModalPresenting` protocol consumed by the
/// PalaceAuth `AuthCoordinator`. The coordinator only needs a single
/// method, so a small façade class is the minimum-surface adapter.
@MainActor
final class CoordinatorSignInModalPresenter: NSObject, SignInModalPresenting {

    /// Strong reference to the accounts manager so the adapter can
    /// resolve the current library account at present-time. Constructed
    /// once at app composition root and injected into the coordinator.
    private let accountsManager: AccountsManager

    init(accountsManager: AccountsManager) {
        self.accountsManager = accountsManager
        super.init()
    }

    func presentSignInModalForCurrentAccount() async -> Bool {
        // Capture the active account up-front so we can re-check
        // `hasCredentials()` on the same account after the modal
        // dismisses — a library swap mid-flow shouldn't false-succeed by
        // observing the new account's credentials.
        let accountsManager = self.accountsManager
        guard let libraryID = accountsManager.currentAccountId else {
            return false
        }
        let userAccount = accountsManager.userAccount(for: libraryID)

        return await withCheckedContinuation { continuation in
            // swarm_d8f11437 Module A wave 4 — migrated to AppContainer-
            // injected sheet presenter. The userAccount reference is
            // captured BEFORE the presentation so the post-dismiss
            // `hasCredentials()` re-check pins the same account regardless
            // of library swaps during the modal flow (invariant preserved
            // from the static-API era).
            AppContainer.production().signInModalSheetPresenter
                .presentSignInModalForCurrentAccount {
                    let hasCreds = userAccount.hasCredentials()
                    continuation.resume(returning: hasCreds)
                }
        }
    }
}
