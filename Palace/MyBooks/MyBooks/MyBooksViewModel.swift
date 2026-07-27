//
//  MyBooksViewModel.swift
//  Palace
//
//  Created by Maurice Carrier on 12/23/22.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import Foundation
import PalacePreferences
import Combine
import PalaceLogging
import PalaceBookModel
import PalaceBookRegistry

enum Group: Int {
    case groupSortBy
}

@MainActor
@objc class MyBooksViewModel: NSObject, ObservableObject {
    typealias DisplayStrings = Strings.MyBooksView

    // MARK: - Public Properties
    @Published private(set) var books: [TPPBook] = []
    @Published var isLoading = false
    @Published var alert: AlertModel?
    @Published var searchQuery = ""
    @Published var showInstructionsLabel = false
    @Published var showSearchSheet = false
    @Published var selectNewLibrary = false
    @Published var showLibraryAccountView = false
    @Published var selectedBook: TPPBook?

    var isPad: Bool { UIDevice.current.isIpad }

    // MARK: - Private Properties
    var activeFacetSort: Facet
    let facetViewModel: FacetViewModel
    private var observers = Set<AnyCancellable>()
    private let bookRegistry: TPPBookRegistryProvider
    private let accountsManager: AccountsManager
    private let settings: TPPSettings
    private let downloadCenter: MyBooksDownloadCenter
    /// Whether the device currently has connectivity. Injected so the
    /// eviction gate (INV-2) can keep offline-expired downloads readable
    /// instead of deleting them on a possibly-stale cached `until`.
    /// Default reads production reachability.
    private let isOnline: () -> Bool
    private var allBooks: [TPPBook] = []

    /// Decides whether `loadData()` may show the registry contents. Defaults
    /// to consulting the injected `accountsManager`: if the current account
    /// requires auth and has no credentials, the registry is hidden (anti-
    /// stale-data guard from F-007). Tests can override this closure to
    /// bypass the guard when seeding a registry with mock books.
    private let isUserAuthorizedForRegistry: () -> Bool

    /// Tracks whether the My Books tab is currently visible. When false,
    /// notification-driven reloads are deferred until the tab reappears,
    /// avoiding unnecessary sort + diff work while the user is on another tab.
    var isVisible: Bool = false {
        didSet {
            if isVisible && needsReloadOnAppear {
                needsReloadOnAppear = false
                loadData()
            }
        }
    }
    private var needsReloadOnAppear = false

    // MARK: - Initialization

    convenience init(appContainer: AppContainer) {
        let reachability = appContainer.reachability
        self.init(
            bookRegistry: appContainer.bookRegistry,
            accountsManager: appContainer.accountsManager,
            settings: appContainer.settings,
            downloadCenter: appContainer.downloadCenter,
            isOnline: { reachability.isConnectedToNetwork() }
        )
    }

    init(
        bookRegistry: TPPBookRegistryProvider,
        accountsManager: AccountsManager,
        settings: TPPSettings,
        downloadCenter: MyBooksDownloadCenter,
        isUserAuthorizedForRegistry: (() -> Bool)? = nil,
        isOnline: (() -> Bool)? = nil
    ) {
        self.bookRegistry = bookRegistry
        self.accountsManager = accountsManager
        self.settings = settings
        self.downloadCenter = downloadCenter
        // Default to production reachability. Tests inject a stub so the
        // offline eviction guard (INV-2) is deterministic.
        self.isOnline = isOnline ?? { AppContainer.production().reachability.isConnectedToNetwork() }
        self.activeFacetSort = .author
        self.facetViewModel = FacetViewModel(
            groupName: DisplayStrings.sortBy,
            facets: [.title, .author],
            accountsManager: accountsManager
        )
        // Default: consult the injected accountsManager. F-007 guard.
        self.isUserAuthorizedForRegistry = isUserAuthorizedForRegistry ?? { [weak accountsManager] in
            guard let acc = accountsManager?.currentUserAccount else { return false }
            return !acc.needsAuth || acc.hasCredentials()
        }
        super.init()

        registerPublishers()
        registerNotifications()

        loadData()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Public Methods
    func loadData() {
        guard !isLoading else { return }
        isLoading = true

        // If the account requires authentication and user is not logged in,
        // don't show any books from the registry (they may be stale from a
        // previous session). F-007 guard. Closure is overridable in tests.
        if !isUserAuthorizedForRegistry() {
            Log.info(#file, "User not logged in - showing empty My Books")
            self.allBooks = []
            self.books = []
            self.showInstructionsLabel = true
            self.isLoading = false
            return
        }

        let registryBooks = bookRegistry.myBooks

        // Eviction gate (seam S3 / INV-2). An expired-by-cached-`until` book
        // is NOT unconditionally deleted. LoanEvictionPolicy decides:
        //   - offline + expired      -> keep (never destroy on a stale `until`)
        //   - online + past grace    -> evict (loan provably over)
        //   - online + within grace  -> keep locally; the loans-feed sync
        //                               reconciles. We do not delete here.
        let now = Date()
        // `isOnline` is evaluated lazily — only when an expired book is
        // actually found — so a shelf with no expired loans never triggers
        // a reachability read.
        var onlineCache: Bool?
        var active: [TPPBook] = []
        var toEvict: [TPPBook] = []
        for book in registryBooks {
            guard book.isExpired else {
                active.append(book)
                continue
            }
            let online: Bool
            if let cached = onlineCache {
                online = cached
            } else {
                online = isOnline()
                onlineCache = online
            }
            switch LoanEvictionPolicy.decide(
                expiration: book.getExpirationDate(),
                now: now,
                isOnline: online
            ) {
            case .evict:
                toEvict.append(book)
            case .keep, .confirmWithServer:
                // INV-2: keep the downloaded file + registry record so the
                // book stays openable. No delete, no unregister.
                active.append(book)
            }
        }

        if !toEvict.isEmpty {
            Log.info(#file, "Removing \(toEvict.count) confirmed-expired book(s) from My Books")
            for book in toEvict {
                Log.info(#file, "  -> '\(book.title)' expired (online, past grace) — evicting")
                downloadCenter.deleteLocalContent(for: book.identifier)
                bookRegistry.setState(.unregistered, for: book.identifier)
            }
        }

        let newBooks = active

        // Skip re-publish when nothing visible changed. The registry fires
        // TPPBookRegistryDidChange on every sync — even when the response is
        // structurally identical to what we already have — and each such
        // reload forces a new allBooks assignment, which in turn swaps the
        // TPPBook instances in BookCellModelCache. SwiftUI sees new object
        // identity and re-evaluates every cell; any book whose coverImage is
        // not yet assigned on the new instance shows a skeleton flash before
        // the cache lookup resolves. Gate on a content signature so pure
        // no-op refreshes don't touch the UI at all.
        if !isLoading && Self.contentSignature(for: newBooks, registry: bookRegistry)
            == Self.contentSignature(for: allBooks, registry: bookRegistry)
        {
            self.isLoading = false
            return
        }

        // Update published properties
        self.allBooks = newBooks
        self.books = newBooks
        self.showInstructionsLabel = newBooks.isEmpty || bookRegistry.state == .unloaded
        self.sortData()
        self.isLoading = false
    }

    /// Stable per-book signature for deciding whether a registry update is
    /// actually worth re-publishing to the view. Includes only the fields
    /// that visibly affect a MyBooks cell — identifier (for ordering +
    /// identity), registry state (drives the action button), and the two
    /// metadata fields we currently render in the cell body.
    ///
    /// Intentionally excludes fields like `updated` and `acquisitions` that
    /// can change on the registry record without altering the visible row —
    /// we want no-op sync responses to be invisible to SwiftUI.
    private static func contentSignature(
        for books: [TPPBook],
        registry: TPPBookRegistryProvider
    ) -> [String] {
        books.map { book in
            let state = registry.state(for: book.identifier).rawValue
            let authors = book.authors ?? ""
            return "\(book.identifier)|\(state)|\(book.title)|\(authors)"
        }
    }

    func reloadData() {
        guard !isLoading else { return }

        if accountsManager.currentUserAccount.needsAuth, !accountsManager.currentUserAccount.hasCredentials() {
            // swarm_d8f11437 Module A wave 4 — migrated to AppContainer-
            // injected sheet presenter. The presenter reads from the same
            // `_cached` accountsManager singleton.
            AppContainer.production().signInModalSheetPresenter
                .presentSignInModalForCurrentAccount(completion: nil)
        } else {
            bookRegistry.sync { [weak self] _, _ in
                self?.loadData()
            }
        }
    }

    /// Silent background refresh on appear — syncs without showing loading
    /// spinner if we already have cached books to display. The UI updates
    /// smoothly via registry notification → loadData() when sync completes.
    func refreshInBackground() {
        guard !isLoading else { return }
        guard accountsManager.currentUserAccount.hasCredentials() else { return }
        // Only do a silent sync if we already have books displayed —
        // if empty, the user sees the empty state and can pull to refresh
        guard !books.isEmpty else { return }
        bookRegistry.sync(completion: nil)
    }

    @MainActor
    func filterBooks(query: String) async {
        if query.isEmpty {
            self.books = allBooks
            self.sortData()
        } else {
            let allBooksCopy = self.allBooks
            let filteredBooks = await Task.detached(priority: .userInitiated) {
                allBooksCopy.filter {
                    $0.title.localizedCaseInsensitiveContains(query) ||
                        ($0.authors?.localizedCaseInsensitiveContains(query) ?? false)
                }
            }.value

            self.books = filteredBooks
        }
    }

    func resetFilter() {
        self.books = allBooks
        self.sortData()
    }

    @objc func authenticateAndLoad(account: Account) {
        account.loadAuthenticationDocument { [weak self] success in
            // `loadAuthenticationDocument`'s completion fires on the URLSession
            // delegate queue (off-main — `TPPNetworkExecutor` builds its session
            // with `delegateQueue: nil`). This closure body is `@MainActor`-isolated
            // (mutates `@Published`/settings state via `loadAccount` → `updateFeed`,
            // and reassigns `accountsManager.currentAccount`), so running it off-main
            // trips Swift 6's `swift_task_checkIsolated` SIGTRAP and restarts the
            // process. Hop to main before touching any main-actor state.
            DispatchQueue.main.async {
                guard let self = self, success else { return }

                if self.settings.settingsAccountIdsList.contains(account.uuid) == false {
                    self.settings.settingsAccountIdsList.append(account.uuid)
                }
                self.loadAccount(account)
            }
        }
    }

    func loadAccount(_ account: Account) {
        if bookRegistry.isSyncing {
            alert = AlertModel(
                title: DisplayStrings.accountSyncingAlertTitle,
                message: DisplayStrings.accountSyncingAlertMessage
            )
        } else {
            updateFeed(account)
        }
    }

    // MARK: - Private Methods
    private func sortData() {
        let sortComparator: (TPPBook, TPPBook) -> Bool = { first, second in
            switch self.activeFacetSort {
            case .author:
                return "\(first.authors ?? "") \(first.title)" < "\(second.authors ?? "") \(second.title)"
            case .title:
                return "\(first.title) \(first.authors ?? "")" < "\(second.title) \(second.authors ?? "")"
            }
        }
        books.sort(by: sortComparator)
        allBooks.sort(by: sortComparator)
    }

    private func updateFeed(_ account: Account) {
        if !settings.settingsAccountIdsList.contains(account.uuid) {
            settings.settingsAccountIdsList.append(account.uuid)
        }

        if let urlString = account.catalogUrl, let url = URL(string: urlString) {
            settings.accountMainFeedURL = url
        }

        accountsManager.currentAccount = account

        account.loadAuthenticationDocument { _ in }

        NotificationCenter.default.post(name: .TPPCurrentAccountDidChange, object: nil)
    }

    // MARK: - Notification Handling
    private func registerNotifications() {
        // Per-book state changes migrated off `.TPPBookRegistryStateDidChange` to
        // the registry's `bookStatePublisher` (swarm_8ce6f5ae WS3). The registry
        // and sync notifications stay as-is (out of this contract's scope). All
        // three are mapped to `Void` so they can merge into one refresh trigger.
        let stateChange = bookRegistry.bookStatePublisher.map { _ in () }
        let registryChange = NotificationCenter.default.publisher(for: .TPPBookRegistryDidChange).map { _ in () }
        let syncEnd = NotificationCenter.default.publisher(for: .TPPSyncEnded).map { _ in () }

        stateChange
            .merge(with: registryChange)
            .merge(with: syncEnd)
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                if self.isVisible {
                    self.loadData()
                } else {
                    // Defer reload until the tab becomes visible again.
                    // Avoids sorting + diffing the book list while offscreen.
                    self.needsReloadOnAppear = true
                }
            }
            .store(in: &observers)
    }

    private func registerPublishers() {
        facetViewModel.$activeSort
            .sink { [weak self] sort in
                guard let self = self else { return }
                self.activeFacetSort = sort
                self.sortData()
            }
            .store(in: &observers)

        // Force a registry sync + reload on any transition into `.loggedIn`
        // (fresh sign-in OR SAML re-auth from `.credentialsStale`). The
        // post-sign-in `bookRegistry.sync()` wired into
        // `TPPSignInBusinessLogic.updateUserAccount` is supposed to
        // repopulate loans, but in practice the propagation through
        // `TPPBookRegistryDidChange` doesn't always reach this view model
        // in time — especially when the registry is in the `.unloaded`
        // race window between sign-out and sign-in (handled at the
        // TPPBookRegistry.sync wrapper level, but the safety net here
        // covers the case where sync itself didn't fire).
        //
        // We can't use a `hasCredentials`-based publisher because
        // `hasCredentials` is true for both `.credentialsStale` AND
        // `.loggedIn` — SAML re-auth keeps the keychain populated through
        // both states, no false→true transition fires.
        //
        // The hasCredentials guard inside the sink is for test isolation:
        // `UserAccountPublisher.shared` is a singleton whose authState
        // leaks across XCTest cases, so without the guard the observer
        // fires in tests against a mock account that has no real
        // credentials and clobbers test fixtures (18 MyBooks tests
        // regressed locally without this guard during 3.0.1 hotfix work).
        UserAccountPublisher.shared.authStateDidChangePublisher
            .dropFirst()
            .filter { $0 == .loggedIn }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self,
                      self.accountsManager.currentUserAccount.hasCredentials()
                else { return }
                self.reloadData()
            }
            .store(in: &observers)
    }
}
