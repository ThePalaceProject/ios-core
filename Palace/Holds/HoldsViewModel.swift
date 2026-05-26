import Combine
import SwiftUI
import PalaceLogging
import PalaceCatalog

@MainActor
final class HoldsBookViewModel: ObservableObject, Identifiable {
    let book: TPPBook

    var id: String { book.identifier }

    var isReserved: Bool {
        var reservedFlag = false
        book.defaultAcquisition?.availability.match(unavailable:
            nil,
            limited: nil,
            unlimited: nil,
            reserved: { (_: TPPOPDSAcquisitionAvailabilityReserved) in reservedFlag = true },
            ready: { (_: TPPOPDSAcquisitionAvailabilityReady) in reservedFlag = true }
        )
        return reservedFlag
    }

    init(book: TPPBook) {
        self.book = book
    }
}

@MainActor
final class HoldsViewModel: ObservableObject {
    @Published var reservedBookVMs: [HoldsBookViewModel] = []
    @Published var heldBookVMs: [HoldsBookViewModel] = []
    @Published var isLoading: Bool = false
    @Published var syncError: SyncError? = nil
    @Published var showLibraryAccountView: Bool = false
    @Published var selectNewLibrary: Bool = false
    @Published var showSearchSheet: Bool = false
    @Published var searchQuery: String = ""
    @Published var visibleBooks: [TPPBook] = []
    var isVisible: Bool = false

    private let bookRegistry: TPPBookRegistryProvider
    private let accountsManager: AccountsManager
    private let settings: TPPSettings
    private let debugSettings: DebugSettings
    private let hasCredentials: () -> Bool
    private let currentLibraryNeedsAuth: () -> Bool
    private let presentSignIn: (@escaping () -> Void) -> Void
    private let store: Store<HoldsState, HoldsAction, HoldsEnvironment>
    private var cancellables = Set<AnyCancellable>()

    struct SyncError: Identifiable {
        let id = UUID()
        let message: String
    }

    convenience init(appContainer: AppContainer) {
        self.init(
            bookRegistry: appContainer.bookRegistry,
            accountsManager: appContainer.accountsManager,
            settings: appContainer.settings,
            debugSettings: appContainer.debugSettings
        )
    }

    init(
        bookRegistry: TPPBookRegistryProvider,
        accountsManager: AccountsManager,
        settings: TPPSettings,
        debugSettings: DebugSettings,
        hasCredentials: (() -> Bool)? = nil,
        currentLibraryNeedsAuth: (() -> Bool)? = nil,
        presentSignIn: ((@escaping () -> Void) -> Void)? = nil
    ) {
        self.bookRegistry = bookRegistry
        self.accountsManager = accountsManager
        self.settings = settings
        self.debugSettings = debugSettings
        self.hasCredentials = hasCredentials ?? { [accountsManager] in
            accountsManager.currentUserAccount.hasCredentials()
        }
        // BUG-004: anonymous libraries (e.g. Palace Bookshelf) have no patron
        // concept; per-patron endpoints (loans/holds) must not be fetched. We
        // read the *library*'s auth surface rather than the user account's
        // because the user-account path races during library switches —
        // `lastKnownCurrentUserAccount` falls back to the previous (still-
        // credentialed) library while `currentAccountId` is briefly nil.
        // Library-state (Account.needsAuth) reflects the new selection
        // synchronously and returns nil while the auth document is still
        // loading — we default-deny in that window so we don't swallow real
        // failures on cold launch (the BookRegistrySync hydration-race guard).
        self.currentLibraryNeedsAuth = currentLibraryNeedsAuth ?? { [accountsManager] in
            return accountsManager.currentAccount?.needsAuth ?? true
        }
        self.presentSignIn = presentSignIn ?? { [accountsManager] completion in
            SignInModalPresenter.presentSignInModalForCurrentAccount(
                accountsManager: accountsManager,
                completion: completion
            )
        }

        let environment = HoldsEnvironment(filterBooks: { query, books in
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let filtered = books.filter {
                        $0.title.localizedCaseInsensitiveContains(query) ||
                            ($0.authors?.localizedCaseInsensitiveContains(query) ?? false)
                    }
                    continuation.resume(returning: filtered)
                }
            }
        })
        self.store = Store(
            initialState: HoldsState(),
            environment: environment,
            reduce: HoldsReducer.reduce
        )

        store.$state
            .sink { [weak self] state in
                self?.applyStateUpdate(state)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .TPPSyncBegan)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.store.send(.syncBegan) }
            .store(in: &cancellables)

        let syncEnd = NotificationCenter.default.publisher(for: .TPPSyncEnded)
        let registryChange = NotificationCenter.default.publisher(for: .TPPBookRegistryDidChange)

        syncEnd
            .merge(with: registryChange)
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.store.send(.syncEnded)
                self.reloadData()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .TPPSyncFailed)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.dispatchSyncFailure(notification)
            }
            .store(in: &cancellables)

        // Force a registry refresh on any transition into `.loggedIn`
        // (fresh sign-in OR SAML re-auth from `.credentialsStale`). See the
        // matching observer in MyBooksViewModel for the full reasoning.
        // Short version: `hasCredentials`-based publishers miss SAML
        // re-auth because `hasCredentials` stays true through stale →
        // loggedIn; `authState` flips, so observe that. The hasCredentials
        // check inside the sink is for test isolation —
        // `UserAccountPublisher.shared` is singleton-backed and leaks
        // authState across XCTest cases.
        UserAccountPublisher.shared.authStateDidChangePublisher
            .dropFirst()
            .filter { $0 == .loggedIn }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self,
                      self.accountsManager.currentUserAccount.hasCredentials()
                else { return }
                self.refresh()
            }
            .store(in: &cancellables)

        reloadData()
    }

    private func applyStateUpdate(_ state: HoldsState) {
        isLoading = state.isLoading
        if let message = state.syncErrorMessage {
            if syncError?.message != message {
                syncError = SyncError(message: message)
            }
        } else {
            syncError = nil
        }
        // Only rebuild HoldsBookViewModel wrappers when the underlying book
        // identifiers change; otherwise Identifiable diffing in LazyVGrid
        // would thrash and the UI would re-animate on every sync tick.
        let newReservedIds = state.reservedBooks.map { $0.identifier }
        if newReservedIds != reservedBookVMs.map({ $0.id }) {
            reservedBookVMs = state.reservedBooks.map { HoldsBookViewModel(book: $0) }
        }
        let newHeldIds = state.heldBooks.map { $0.identifier }
        if newHeldIds != heldBookVMs.map({ $0.id }) {
            heldBookVMs = state.heldBooks.map { HoldsBookViewModel(book: $0) }
        }
        visibleBooks = state.visibleBooks
    }

    private func dispatchSyncFailure(_ notification: Notification) {
        let detail: String? = {
            guard let errorDoc = notification.userInfo?[TPPBookRegistry.syncFailureErrorDocumentKey] as? [AnyHashable: Any],
                  let text = (errorDoc["detail"] as? String) ?? (errorDoc["title"] as? String),
                  !text.isEmpty
            else { return nil }
            return text
        }()
        let cached = !visibleBooks.isEmpty
        // `anonymous` collapses two distinct anonymous-state signals:
        //   1. The current *library* declares no credential-based auth method
        //      (Palace Bookshelf etc.) — holds aren't a concept here at all.
        //      This is the BUG-004 fix: library state is durable across the
        //      switch, so it catches the race window where the user-account
        //      view of credentials is briefly stale.
        //   2. The user has no credentials stored for the current library —
        //      existing PP-3811 behaviour, kept verbatim so the auth-required
        //      code path doesn't change.
        let anonymous = !currentLibraryNeedsAuth() || !hasCredentials()
        if cached {
            Log.debug(#file, "Sync failed but holds are cached — suppressing error banner")
        } else if anonymous {
            Log.debug(#file, "Sync failed for anonymous library/user — suppressing error banner")
        }
        store.send(.syncFailed(errorMessage: detail, cached: cached, anonymous: anonymous))
    }

    func dismissSyncError() {
        store.send(.dismissSyncError)
    }

    private var allBooks: [TPPBook] {
        reservedBookVMs.map { $0.book } + heldBookVMs.map { $0.book }
    }

    func reloadData() {
        #if DEBUG
        let allHeld: [TPPBook] = debugSettings.createTestHoldBooks() ?? bookRegistry.heldBooks
        #else
        let allHeld = bookRegistry.heldBooks
        #endif

        store.send(.registryChanged(held: allHeld))

        // Badge update — centrally managed by AppTabHostView
        NotificationCenter.default.post(name: .TPPBookRegistryStateDidChange, object: nil)
    }

    func refresh() {
        if accountsManager.currentUserAccount.needsAuth {
            if accountsManager.currentUserAccount.hasCredentials() {
                bookRegistry.sync()
            } else {
                presentSignIn { [weak self] in
                    self?.reloadData()
                }
            }
        } else {
            bookRegistry.load()
        }
    }

    /// Silent background refresh on appear — syncs without disrupting
    /// the current display if we already have holds to show.
    func refreshInBackground() {
        isVisible = true
        guard !isLoading else { return }
        guard accountsManager.currentUserAccount.hasCredentials() else { return }
        guard !visibleBooks.isEmpty else { return }
        bookRegistry.sync()
    }

    func loadAccount(_ account: Account) {
        updateFeed(account)
        showLibraryAccountView = false
        selectNewLibrary = false
        reloadData()
    }

    private func updateFeed(_ account: Account) {
        if let urlString = account.catalogUrl, let url = URL(string: urlString) {
            settings.accountMainFeedURL = url
        }
        accountsManager.currentAccount = account

        account.loadAuthenticationDocument { _ in }

        NotificationCenter.default.post(name: .TPPCurrentAccountDidChange, object: nil)
    }

    var openSearchDescription: TPPOpenSearchDescription {
        let title = NSLocalizedString("Search Holds", comment: "")
        let books = allBooks
        return TPPOpenSearchDescription(title: title, books: books)
    }

    @MainActor
    func filterBooks(query: String) async {
        await store.sendAwait(.searchQueryChanged(query))
    }
}
