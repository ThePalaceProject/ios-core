//
//  LibrariesSectionViewModel.swift
//  Palace
//
//  Owns state for the inline MY LIBRARIES section on the Settings screen
//  (PP-917): sorted accounts, current-account identification, stale-uuid
//  filter, secondary-library deletion with FCM token cleanup, and refresh
//  on TPPCurrentAccountDidChange.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import Combine

/// Environment seam for `LibrariesSectionViewModel`. Production wiring
/// closes over `AccountsManager`, `TPPSettings`, and
/// `NotificationService.shared`. Tests inject fakes.
protocol LibrariesSectionEnvironment {
    func currentAccountUUID() -> String?
    func loadPersistedAccounts() -> [Account]
    func lookupAccount(_ uuid: String) -> Account?
    func persistAccountIds(_ ids: [String])
    func deleteToken(for account: Account)
    /// Switches the active library to `account`. Mirrors
    /// `MyBooksViewModel.updateFeed` — adds to the persisted accounts list,
    /// updates the main-feed URL, assigns `accountsManager.currentAccount`,
    /// loads the auth document, and posts `TPPCurrentAccountDidChange`.
    /// `completion` fires once the auth document has loaded (success or
    /// failure) — that's the readiness signal the catalog needs before
    /// rendering the new library, so the view uses it to time both the
    /// loading overlay dismiss and the tab jump.
    func switchToAccount(_ account: Account, completion: @escaping () -> Void)
}

@MainActor
final class LibrariesSectionViewModel: ObservableObject {

    @Published private(set) var accounts: [Account] = []
    @Published private(set) var currentAccountUUID: String?
    @Published private(set) var isSwitching: Bool = false
    @Published var showAddLibrarySheet: Bool = false

    /// Upper bound on how long the loading overlay parks the user — picked
    /// to be just longer than a healthy auth-doc fetch on a fast network.
    /// If the real callback hasn't fired by then we fall through so a stuck
    /// or hung network can't strand the user on the spinner.
    private let switchTimeout: TimeInterval = 2.5

    private let environment: LibrariesSectionEnvironment
    private var accountChangeObserver: NSObjectProtocol?

    init(environment: LibrariesSectionEnvironment, observeNotifications: Bool = true) {
        self.environment = environment
        refresh()

        if observeNotifications {
            accountChangeObserver = NotificationCenter.default.addObserver(
                forName: .TPPCurrentAccountDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                // Hop to the main actor explicitly — the observer block is
                // delivered on .main queue but isn't statically isolated.
                Task { @MainActor [weak self] in
                    self?.refresh()
                }
            }
        }
    }

    deinit {
        if let accountChangeObserver {
            NotificationCenter.default.removeObserver(accountChangeObserver)
        }
    }

    /// Recomputes `accounts` + `currentAccountUUID` from the environment.
    /// Filters UUIDs that no longer resolve in the registry and persists
    /// the cleaned list so the next launch doesn't re-load stale entries.
    func refresh() {
        let persisted = environment.loadPersistedAccounts()
        let resolved = persisted.filter { environment.lookupAccount($0.uuid) != nil }

        let currentUUID = environment.currentAccountUUID()
        let current = resolved.first { $0.uuid == currentUUID }
        let others = resolved
            .filter { $0.uuid != currentUUID }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        accounts = (current.map { [$0] } ?? []) + others
        currentAccountUUID = currentUUID

        let resolvedIds = resolved.map { $0.uuid }
        if resolvedIds.count != persisted.count {
            environment.persistAccountIds(resolvedIds)
        }
    }

    /// Sets `account` as the active library. No-ops when it already is.
    /// `completion` fires on the main actor when the new library's auth
    /// document has loaded (or when `switchTimeout` elapses, whichever is
    /// first). The view uses that signal to dismiss its loading overlay
    /// and time the Catalog tab jump so the user lands on data that is
    /// already populated, not a stale-then-refreshing screen.
    ///
    /// `isSwitching` is published `true` for the duration so the view can
    /// render an overlay.
    func switchToAccount(_ account: Account, completion: (() -> Void)? = nil) {
        guard account.uuid != currentAccountUUID else {
            completion?()
            return
        }

        isSwitching = true

        // Resort optimistically so the checkmark moves to the new row the
        // moment the user accepts, even before the network call settles.
        currentAccountUUID = account.uuid
        let current = accounts.first { $0.uuid == account.uuid }
        let others = accounts
            .filter { $0.uuid != account.uuid }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        accounts = (current.map { [$0] } ?? [account]) + others

        // Guard the completion so neither the auth-doc callback nor the
        // timeout fire it twice — whichever wins owns the dismissal.
        var hasFired = false
        let finish: () -> Void = { [weak self] in
            guard !hasFired else { return }
            hasFired = true
            self?.isSwitching = false
            completion?()
        }

        environment.switchToAccount(account) {
            Task { @MainActor in finish() }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + switchTimeout) {
            finish()
        }
    }

    /// Removes a secondary library from the user's configured list.
    /// No-ops for the active library (which can't be deleted from this UX
    /// — the user must switch first, then delete the former active).
    func deleteSecondary(_ account: Account) {
        guard account.uuid != currentAccountUUID else { return }
        environment.deleteToken(for: account)
        accounts.removeAll { $0.uuid == account.uuid }
        environment.persistAccountIds(accounts.map { $0.uuid })
    }

    func presentAddLibrary() {
        showAddLibrarySheet = true
    }
}

// MARK: - Production environment

struct ProductionLibrariesSectionEnvironment: LibrariesSectionEnvironment {
    private let accountsManager: AccountsManager
    private let settings: TPPSettings
    private let tokenDeleter: (Account) -> Void

    init(
        accountsManager: AccountsManager,
        settings: TPPSettings,
        tokenDeleter: @escaping (Account) -> Void = { NotificationService.shared.deleteToken(for: $0) }
    ) {
        self.accountsManager = accountsManager
        self.settings = settings
        self.tokenDeleter = tokenDeleter
    }

    func currentAccountUUID() -> String? {
        accountsManager.currentAccount?.uuid
    }

    func loadPersistedAccounts() -> [Account] {
        settings.settingsAccountsList
    }

    func lookupAccount(_ uuid: String) -> Account? {
        accountsManager.account(uuid)
    }

    func persistAccountIds(_ ids: [String]) {
        settings.settingsAccountIdsList = ids
    }

    func deleteToken(for account: Account) {
        tokenDeleter(account)
    }

    func switchToAccount(_ account: Account, completion: @escaping () -> Void) {
        if !settings.settingsAccountIdsList.contains(account.uuid) {
            settings.settingsAccountIdsList.append(account.uuid)
        }
        if let urlString = account.catalogUrl, let url = URL(string: urlString) {
            settings.accountMainFeedURL = url
        }
        accountsManager.currentAccount = account
        // Posting the notification BEFORE the auth-doc callback fires lets
        // downstream observers (catalog, MyBooks) start their own refresh
        // off the new currentAccount in parallel — by the time the auth
        // doc resolves the receivers have already kicked off their work,
        // shaving visible latency off the user-facing transition.
        NotificationCenter.default.post(name: .TPPCurrentAccountDidChange, object: nil)
        account.loadAuthenticationDocument { _ in completion() }
    }
}
