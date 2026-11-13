//
//  AccountCredentialResolver.swift
//  Palace
//
//  Per-account credential resolution. `userAccount(for:)` checks, builds and
//  inserts under one lock: one instance per UUID with immutable keychain keys
//  (PP-4020). No shared-singleton fallback (PR #822 caused spurious sign-in
//  modals). A class, not an actor: reached synchronously from `@objc` code.
//  `@unchecked Sendable`: all mutable state is guarded by `userAccountsLock`.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation

/// Resolves per-library `TPPUserAccount` instances with immutable-key isolation and
/// the account-switch ride-out. Injected into `AccountsManager`, which keeps the
/// `@objc TPPUserAccountResolving` facades; tests construct it directly with a spy
/// `currentAccountIdProvider`.
final class AccountCredentialResolver: @unchecked Sendable {

    /// Live read of the current library's UUID. MUST re-read on every call (not a
    /// captured snapshot) — the ride-out below depends on observing the transient nil
    /// window in real time.
    private let currentAccountIdProvider: () -> String?

    /// Cache of per-library `TPPUserAccount` instances. Each instance has immutable
    /// keychain keys, eliminating the TOCTOU race that the singleton's mutable
    /// `libraryUUID` pattern was subject to.
    private var userAccounts = [String: TPPUserAccount]()
    private let userAccountsLock = NSLock()

    /// Last account returned from `currentUserAccount`. Used to ride out the brief
    /// windows where `currentAccountId` is nil during an account switch — without this,
    /// consumers observe a transiently-unauthenticated state on an account that IS
    /// signed in, and fire spurious sign-in modals.
    private var lastKnownCurrentUserAccount: TPPUserAccount?

    /// Sentinel UUID for the "no account selected" placeholder. Not a real library
    /// UUID — keychain reads for this instance return nil, so hasCredentials()
    /// deterministically returns false.
    private static let noAccountSentinelUUID = "__no_account_selected__"

    /// Placeholder returned by `currentUserAccount` only on a truly fresh install
    /// before any account has ever been selected. Lazily created so app launch doesn't
    /// pay for a keychain-probed instance.
    private lazy var noAccountPlaceholder: TPPUserAccount = TPPUserAccount(
        libraryUUID: Self.noAccountSentinelUUID
    )

    init(currentAccountIdProvider: @escaping () -> String?) {
        self.currentAccountIdProvider = currentAccountIdProvider
    }

    /// Returns a library-scoped `TPPUserAccount` instance. Creates and caches a new one
    /// on first access for a given UUID.
    func userAccount(for libraryUUID: String) -> TPPUserAccount {
        userAccountsLock.lock()
        defer { userAccountsLock.unlock() }
        if let existing = userAccounts[libraryUUID] {
            return existing
        }
        let account = TPPUserAccount(libraryUUID: libraryUUID)
        userAccounts[libraryUUID] = account
        return account
    }

    /// The current library's user account. During the transient nil
    /// `currentAccountId` window of a switch this returns the last-resolved account;
    /// the placeholder is only returned on a fresh install.
    var currentUserAccount: TPPUserAccount {
        if let id = currentAccountIdProvider() {
            let account = userAccount(for: id)
            userAccountsLock.lock()
            lastKnownCurrentUserAccount = account
            userAccountsLock.unlock()
            return account
        }
        // The placeholder is a `lazy var`: build it inside the lock so concurrent
        // first reads cannot each build (and return) their own instance.
        userAccountsLock.lock()
        defer { userAccountsLock.unlock() }
        return lastKnownCurrentUserAccount ?? noAccountPlaceholder
    }
}
