//
//  TPPUserAccount+TPPUserAccountReadingWriting.swift
//  Palace
//
//  Adapts `TPPUserAccount` to the narrow read/write protocols PalaceAuth's
//  `AuthCoordinator` consumes. An adapter rather than an extension because
//  `TPPUserAccount.hasCredentials()` already exists as a method, and a
//  same-named computed property would make call sites ambiguous.
//

import Foundation
import PalaceAuth

/// Resolves the current user account through `AccountsManager` on every
/// access so a library switch mid-flow is observed.
/// `@unchecked Sendable`: captured into `AuthCoordinator`'s `@Sendable` refresh
/// Task; the adapter holds no mutable state, only the immutable `accountsManager`.
final class CoordinatorUserAccountAdapter: TPPUserAccountReading, TPPUserAccountWriting, @unchecked Sendable {

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
