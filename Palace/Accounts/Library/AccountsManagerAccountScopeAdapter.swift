//
//  AccountsManagerAccountScopeAdapter.swift
//  Palace
//
//  Copyright © 2025 The Palace Project. All rights reserved.
//

import Foundation
import Combine
import PalaceBookRegistry

/// Adapts the concrete `AccountsManager` to the registry's value-only
/// `AccountScopeProviding` surface (god-class decomposition Wave 2b — the
/// Book→Accounts dependency inversion). No `Account` / `AccountsManager` /
/// `TPPUserAccount` type crosses into PalaceBookRegistry; only a uuid, a Void
/// change signal, a Bool, and a URL do.
///
/// `@unchecked Sendable`: the sole stored property is an immutable `let` to the
/// process-lifetime `AccountsManager` (itself `@unchecked Sendable` — its
/// `accountSetsLock` guards its reads). This adapter adds no mutable state, so it
/// inherits the same thread-safety invariant.
final class AccountsManagerAccountScopeAdapter: AccountScopeProviding, @unchecked Sendable {
    private let accountsManager: AccountsManager

    init(accountsManager: AccountsManager) {
        self.accountsManager = accountsManager
    }

    /// Same synchronous read the facade captured at every mutation dispatch
    /// (PP-4129 capture discipline); `currentAccount?.uuid` == `currentAccountId`.
    var currentAccountID: String? { accountsManager.currentAccount?.uuid }

    var accountDidChangePublisher: AnyPublisher<Void, Never> {
        NotificationCenter.default.publisher(for: .TPPCurrentAccountDidChange)
            .map { _ in () }
            .eraseToAnyPublisher()
    }

    func hasCredentials(forAccount accountID: String) -> Bool {
        TPPUserAccount.sharedAccount(libraryUUID: accountID).hasCredentials()
    }

    /// Awaits account-details readiness then returns the loans URL — the same
    /// `awaitReady()` → `loansUrl` path the sync engine used to run inline, keyed
    /// by the captured uuid (AccountsManager's registry is uuid-keyed, so this
    /// resolves the same `Account` instance and survives a mid-await library switch
    /// identically). Throws propagate (registry reverts to `.loaded` + retries);
    /// nil means anonymous (no loansUrl) or account-not-found (safe revert).
    func loansURL(forAccount accountID: String) async throws -> URL? {
        guard let account = accountsManager.account(accountID) else { return nil }
        let details = try await account.awaitReady()
        return details.loansUrl
    }
}
