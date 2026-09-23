//
//  AccountCredentialResolver.swift
//  Palace
//
//  god-class decomposition — Wave 3 / 3a-5 (the fifth in-target collaborator split
//  out of `AccountsManager`).
//
//  Per-account credential resolution: the cache of library-scoped `TPPUserAccount`
//  instances (each with immutable keychain keys), the `currentUserAccount` resolution
//  with its "ride-out" over the transient `currentAccountId == nil` account-switch
//  window, and the fresh-install placeholder. This is the credential-isolation
//  boundary — a defect here is a silent cross-account credential leak (F-034) or a
//  spurious sign-in modal (F-016) — so the bodies below are relocated VERBATIM from
//  the hub and the two invariants are preserved exactly:
//
//    * F-034 (TOCTOU): `userAccount(for:)` does check-build-insert in ONE
//      `userAccountsLock` span, returning the same cached instance per UUID whose
//      keychain keys are immutable for its lifetime. Splitting the read/insert would
//      let two instances exist for one UUID and reopen the 6-year race (PP-4020).
//    * F-016 (ride-out): `currentUserAccount` writes `lastKnownCurrentUserAccount`
//      under the lock on EVERY id-present resolution, and during the nil window
//      returns that last-resolved instance (placeholder only on true fresh install)
//      so consumers never observe `hasCredentials == false` on a signed-in account.
//
//  A `final class` (not an actor): `currentUserAccount` is reached synchronously from
//  the `@objc TPPUserAccountResolving` facade on `AccountsManager` (which stays the
//  protocol witness) and from the non-async `currentAccount` setter — an actor would
//  force `await` through the `@objc` conformance. The resolver is a plain internal
//  collaborator; it is NOT `@objc` and does NOT conform to the protocol.
//
//  `@unchecked Sendable` invariant: the only mutable state is `userAccounts` and
//  `lastKnownCurrentUserAccount`, read/written exclusively under `userAccountsLock`
//  (an immutable `NSLock`); `noAccountPlaceholder` is a `lazy var` resolved at most
//  once on the fresh-install path and immutable thereafter (write-once);
//  `currentAccountIdProvider` is an immutable `let` reading the internally
//  thread-safe `UserDefaults` live on every call.
//
//  There is NO shared-singleton credential fallback anywhere here — the only fallbacks
//  are `lastKnownCurrentUserAccount` then `noAccountPlaceholder`. A shared-singleton
//  safety-net is the PR #822 defect that caused spurious sign-in modals.
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

    /// Convenience for the current library's user account.
    ///
    /// Thread-safety note: `currentAccountId` can transiently be nil during an account
    /// switch (the old id is cleared before the new id is assigned). If we blindly fell
    /// back to a fresh/empty instance in that window, consumers like
    /// MyBooksDownloadCenter would observe `hasCredentials == false` on an account that
    /// IS signed in and fire a spurious login modal. We cache the last-resolved account
    /// and return it during the nil window instead. The placeholder path only fires on a
    /// true fresh-install state where no account has ever been selected.
    var currentUserAccount: TPPUserAccount {
        if let id = currentAccountIdProvider() {
            let account = userAccount(for: id)
            userAccountsLock.lock()
            lastKnownCurrentUserAccount = account
            userAccountsLock.unlock()
            return account
        }
        userAccountsLock.lock()
        let last = lastKnownCurrentUserAccount
        userAccountsLock.unlock()
        return last ?? noAccountPlaceholder
    }
}
