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
    /// `awaitReady(timeout:)` → `loansUrl` path the sync engine used to run inline,
    /// keyed by the captured uuid (AccountsManager's registry is uuid-keyed, so this
    /// resolves the same `Account` instance and survives a mid-await library switch
    /// identically). Throws propagate (registry reverts to `.loaded` + retries);
    /// nil means anonymous (no loansUrl) or account-not-found (safe revert).
    ///
    /// The BOUNDED overload is mandatory here, not a nicety. This is the sole
    /// bounded `awaitReady` call site in the app: every other consumer is unbounded
    /// by the ADR's single-timeout policy, because each owns a pipeline-level
    /// timeout. Registry sync owns none — it is fire-and-forget behind My Books —
    /// so an unbounded await here is the HelpSpot #18414 load-forever wedge.
    ///
    /// Regression history: the Wave 3 S2 seam extraction moved this call out of
    /// `BookRegistrySync` and silently dropped `timeout:` in the move. The 3.2.3
    /// hotfix test kept passing because it exercised `Account.awaitReady(timeout:)`
    /// directly — the helper — never this producer. `BookRegistrySyncTimeoutSeamTests`
    /// now pins the producer.
    func loansURL(forAccount accountID: String, readinessTimeout: TimeInterval) async throws -> URL? {
        guard let account = accountsManager.account(accountID) else { return nil }
        let details = try await account.awaitReady(timeout: readinessTimeout)
        return details.loansUrl
    }
}
