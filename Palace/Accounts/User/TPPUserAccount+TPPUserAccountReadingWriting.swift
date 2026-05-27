//
//  TPPUserAccount+TPPUserAccountReadingWriting.swift
//  Palace
//
//  Conforms a thin adapter over `TPPUserAccount` to the narrow read +
//  write protocols consumed by PalaceAuth's `AuthCoordinator`. The
//  protocols intentionally expose only what the coordinator needs
//  (`hasCredentials`, `authTokenHasExpired`, `markCredentialsStale`)
//  — they do NOT promote the full ~17-method TPPUserAccount surface
//  (Phase 3 trunk-move scope per the architecture plan).
//
//  We use an adapter class instead of a direct extension because
//  `TPPUserAccount.hasCredentials()` is already a method on the primary
//  declaration; adding a computed property of the same name in an
//  extension would create call-site ambiguity. The adapter also lets the
//  coordinator hold a stable reference even when the underlying
//  `currentUserAccount` flips during a library swap (the adapter resolves
//  the account lazily via the accounts manager on every read).
//
//  Module C of swarm_66819d80.
//

import Foundation
import PalaceAuth

/// Adapter conforming to `TPPUserAccountReading & TPPUserAccountWriting`.
/// Resolves the current user account through `AccountsManager` on every
/// access so library swaps mid-coordinator-flight are observed (matches
/// MBDC's existing computed-property semantics for `userAccount`).
final class CoordinatorUserAccountAdapter: TPPUserAccountReading, TPPUserAccountWriting {

    private let accountsManager: AccountsManager

    init(accountsManager: AccountsManager) {
        self.accountsManager = accountsManager
    }

    var hasCredentials: Bool {
        accountsManager.currentUserAccount.hasCredentials()
    }

    var authTokenHasExpired: Bool {
        accountsManager.currentUserAccount.authTokenHasExpired
    }

    func markCredentialsStale() {
        accountsManager.currentUserAccount.markCredentialsStale()
    }
}
