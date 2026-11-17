//
//  AccountsManagerDownloadContextAdapter.swift
//  Palace
//
//  Adapts `AccountsManager` to the Downloads-owned protocols
//  (`DownloadAccountScopeProviding` + `DownloadCredentialsProviding`) so
//  Downloads never names an Accounts type.
//  `@unchecked Sendable`: the only stored property is an immutable `let` to the
//  process-lifetime `AccountsManager`; this adapter adds no mutable state.
//

import Foundation

final class AccountsManagerDownloadContextAdapter: DownloadAccountScopeProviding,
                                                   DownloadCredentialsProviding,
                                                   @unchecked Sendable {
    private let accountsManager: AccountsManager

    init(accountsManager: AccountsManager) {
        self.accountsManager = accountsManager
    }

    // MARK: - DownloadAccountScopeProviding

    /// The defaults-backed `currentAccountId`, not `currentAccount?.uuid`: a
    /// download file must resolve under the selected library even before that
    /// library's `Account` has loaded (the two diverge during a switch).
    var currentAccountID: String? {
        accountsManager.currentAccountId
    }

    /// The current library's auth-surface hosts (empty when the auth doc has
    /// not loaded — the cold-launch fallback signal).
    var currentAccountAuthSurfaceHosts: Set<String> {
        accountsManager.currentAccount?.authSurfaceHosts ?? []
    }

    // MARK: - DownloadCredentialsProviding

    func currentUserAccount() -> any DownloadUserAccount {
        accountsManager.currentUserAccount
    }

    func userAccount(forAccount accountID: String) -> any DownloadUserAccount {
        accountsManager.userAccount(for: accountID)
    }
}
