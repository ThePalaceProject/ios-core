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
/// `AccountScopeProviding` surface, so no Accounts type crosses into
/// PalaceBookRegistry.
///
/// `@unchecked Sendable`: the only stored property is an immutable `let` to the
/// process-lifetime `AccountsManager`; this adapter adds no mutable state.
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

    /// Awaits account-details readiness for the captured uuid, then returns the
    /// loans URL. Throws propagate (the registry reverts to `.loaded` and retries);
    /// nil means anonymous (no loansUrl) or account not found.
    ///
    /// The bounded overload is required. Other `awaitReady` consumers each own a
    /// pipeline-level timeout; registry sync has none, so an unbounded await here
    /// is the HelpSpot #18414 load-forever hang. Pinned by
    /// `BookRegistrySyncTimeoutSeamTests`.
    func loansURL(forAccount accountID: String, readinessTimeout: TimeInterval) async throws -> URL? {
        guard let account = accountsManager.account(accountID) else { return nil }
        let details = try await account.awaitReady(timeout: readinessTimeout)
        return details.loansUrl
    }
}
