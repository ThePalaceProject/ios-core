//
//  AccountsManagerDownloadContextAdapter.swift
//  Palace
//
//  Adapts the concrete `AccountsManager` to the Downloads-owned account-context
//  seams (`DownloadAccountScopeProviding` + `DownloadCredentialsProviding`) —
//  the B-side inversion of the Accounts↔Downloads hub pair (god-class
//  decomposition Wave 3, S2). App-target composition: it is the only place the
//  Downloads protocols and the concrete `AccountsManager` are named together.
//  No `Account` / `AccountsManager` / `TPPUserAccount` type crosses the protocol
//  boundary — only `String?`, `Set<String>`, and `any DownloadUserAccount` do.
//
//  `@unchecked Sendable`: the sole stored property is an immutable `let` to the
//  process-lifetime `AccountsManager` (itself `@unchecked Sendable`). This
//  adapter adds no mutable state, so it inherits the same thread-safety
//  invariant — the same pattern as `AccountsManagerAccountScopeAdapter`.
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

    /// The defaults-backed `currentAccountId`, NOT `currentAccount?.uuid`. This
    /// is the exact read `BookFileManager.fileUrl(for:)` funnelled through: a
    /// download file must resolve under the selected library even before that
    /// library's `Account` object has materialized (the two diverge during a
    /// switch / pre-hydration; only `currentAccountId` preserves behavior).
    var currentAccountID: String? {
        accountsManager.currentAccountId
    }

    /// The current library's auth-surface hosts (empty when the auth doc has
    /// not loaded — the cold-launch fallback signal). Mirrors the ambient
    /// `AppContainer.production().accountsManager.currentAccount?.authSurfaceHosts`
    /// reach the download 401-classification path performs today.
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
