//
//  MyBooksViewModel.swift
//  Palace
//
//  Created by Maurice Carrier on 12/23/22.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import Foundation
import Combine

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
    private var allBooks: [TPPBook] = []

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
    init(bookRegistry: TPPBookRegistryProvider = TPPBookRegistry.shared, accountsManager: AccountsManager = .shared, settings: TPPSettings = .shared) {
        self.bookRegistry = bookRegistry
        self.accountsManager = accountsManager
        self.settings = settings
        self.activeFacetSort = .author
        self.facetViewModel = FacetViewModel(
            groupName: DisplayStrings.sortBy,
            facets: [.title, .author]
        )
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
        // don't show any books from the registry (they may be stale from a previous session)
        let account = AccountsManager.shared.currentUserAccount
        if account.needsAuth && !account.hasCredentials() {
            Log.info(#file, "User not logged in - showing empty My Books")
            self.allBooks = []
            self.books = []
            self.showInstructionsLabel = true
            self.isLoading = false
            return
        }

        let registryBooks = bookRegistry.myBooks

        // Always filter out expired books. Previously this only happened offline,
        // relying on sync to remove expired books when online. But if sync hasn't
        // run yet (or is delayed), expired books would remain visible with stale UI.
        let (active, expired) = registryBooks.reduce(into: ([TPPBook](), [TPPBook]())) { result, book in
            if book.isExpired {
                result.1.append(book)
            } else {
                result.0.append(book)
            }
        }

        if !expired.isEmpty {
            Log.info(#file, "📚 Removing \(expired.count) expired book(s) from My Books")
            for book in expired {
                Log.info(#file, "  → '\(book.title)' expired")
                MyBooksDownloadCenter.shared.deleteLocalContent(for: book.identifier)
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

        if AccountsManager.shared.currentUserAccount.needsAuth, !AccountsManager.shared.currentUserAccount.hasCredentials() {
            SignInModalPresenter.presentSignInModalForCurrentAccount(completion: nil)
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
        guard AccountsManager.shared.currentUserAccount.hasCredentials() else { return }
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
            guard let self = self, success else { return }

            if !settings.settingsAccountIdsList.contains(account.uuid) {
                settings.settingsAccountIdsList.append(account.uuid)
            }
            self.loadAccount(account)
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
        let stateChange = NotificationCenter.default.publisher(for: .TPPBookRegistryStateDidChange)
        let registryChange = NotificationCenter.default.publisher(for: .TPPBookRegistryDidChange)
        let syncEnd = NotificationCenter.default.publisher(for: .TPPSyncEnded)

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

        // Force a registry sync + reload when authState transitions into
        // `.loggedIn`. We can't use `didSignInPublisher` here — that
        // watches `hasCredentials` flipping false → true, but
        // `hasCredentials` is true for both `.credentialsStale` AND
        // `.loggedIn` (it just checks the keychain for a token/PIN). On
        // SAML re-auth the user starts in `.credentialsStale` with a
        // stale token already in keychain, signs in successfully, and
        // ends in `.loggedIn` — `hasCredentials` stays true the whole
        // time, no signal fires, the My Books tab sits on stale empty
        // state until the user toggles libraries (which forces the
        // registry's `accountDidChangeCancellable` to re-load + sync).
        //
        // `authState` is the authoritative signal: it goes
        // `.credentialsStale → .loggedIn` on re-auth and
        // `.loggedOut → .loggedIn` on fresh sign-in. Either transition
        // means "user just gained valid creds; refresh data".
        // `dropFirst()` skips the initial value so users already
        // logged in at app launch don't get a redundant reload.
        UserAccountPublisher.shared.authStateDidChangePublisher
            .dropFirst()
            .filter { $0 == .loggedIn }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                // Only fire reloadData when the user actually has credentials
                // on the *injected* accountsManager. In tests the
                // `UserAccountPublisher.shared` singleton's `authState` can
                // transition to `.loggedIn` from prior test mutations even
                // though the test's account has no real credentials —
                // observed in MyBooksViewModelExtendedTests etc. Without this
                // guard, the observer fires `reloadData → loadData`, which
                // sees `!hasCredentials()` and clears the test's mock books,
                // breaking 18 tests that pass in isolation. The guard makes
                // the observer a no-op when credentials are absent (which is
                // also the right production behavior — there's nothing to
                // sync if we don't have creds).
                guard let self,
                      self.accountsManager.currentUserAccount.hasCredentials()
                else { return }
                self.reloadData()
            }
            .store(in: &observers)
    }
}
