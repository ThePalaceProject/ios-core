import Combine
import PalacePreferences
import SwiftUI
import PalaceLogging
import PalaceCatalog
import PalaceBookModel

@MainActor
final class HoldsBookViewModel: ObservableObject, Identifiable {
    let book: TPPBook

    // `nonisolated`: satisfies `Identifiable.id` without the @MainActor class's
    // isolation crossing into the protocol requirement. `book` is a `let` of an
    // @unchecked-Sendable type, so reading it off-actor is safe. No logic change.
    nonisolated var id: String { book.identifier }

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

    /// Trailing-edge debounce interval for the merged sync-ended /
    /// registry-changed refresh. Defaults to 300ms — byte-identical to the
    /// `.debounce(for: .milliseconds(300))` it replaces — so RELEASE timing is
    /// unchanged. Tests inject `0` to make the S7 refresh seam settle instantly.
    private let debounceInterval: TimeInterval
    /// The cancel-and-replace Task backing the debounced refresh. Replaces the
    /// Combine `.debounce(scheduler: DispatchQueue.main)` operator so a test can
    /// deterministically JOIN the actual work via `_awaitRefreshForTesting()`
    /// instead of racing a fixed wall-clock timeout against a starved main queue.
    private var refreshDebounceTask: Task<Void, Never>?

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
        presentSignIn: ((@escaping () -> Void) -> Void)? = nil,
        debounceInterval: TimeInterval = 0.3
    ) {
        self.bookRegistry = bookRegistry
        self.accountsManager = accountsManager
        self.settings = settings
        self.debugSettings = debugSettings
        self.debounceInterval = debounceInterval
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
        self.presentSignIn = presentSignIn ?? { completion in
            // swarm_d8f11437 Module A wave 4 — migrated to AppContainer-
            // injected sheet presenter. The presenter resolves
            // `currentAccountId` from its container's accountsManager,
            // which is the same `_cached` singleton used everywhere else
            // (accountsManager was previously captured by the static-API
            // call; capture removed as the presenter handles resolution).
            AppContainer.production().signInModalSheetPresenter
                .presentSignInModalForCurrentAccount(completion: completion)
        }

        let environment = HoldsEnvironment(filterBooks: { query, books in
            // Filter in-place. This runs on the reducer effect's `@Sendable`
            // (off-main) task, so it never blocks the UI, and a holds list is
            // tiny — an in-memory title/author substring match. The previous
            // implementation bridged this through `withCheckedContinuation` +
            // `DispatchQueue.global(qos:).async`, which made a trivial filter a
            // VICTIM of global-queue thread-pool exhaustion: under full-suite CI
            // load, when leaked blocking work saturates the global pool, the
            // enqueued filter block never runs and `sendAwait(.searchQueryChanged)`
            // hangs to the 120s execution allowance (the HoldsViewModel flake).
            // A synchronous filter has no queue dependency and cannot starve.
            books.filter {
                $0.title.localizedCaseInsensitiveContains(query) ||
                    ($0.authors?.localizedCaseInsensitiveContains(query) ?? false)
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

        // Trailing-edge debounce of the merged sync-ended / registry-changed
        // stream. Previously `.debounce(for: .milliseconds(300), scheduler:
        // DispatchQueue.main)`; that Combine timer + `.receive(on: main)` hop is
        // exactly the starvation-prone shape that made the Holds tests race a
        // fixed wall-clock timeout under parallel-CI load — the debounce fired
        // late on a saturated main queue and `fulfillment(timeout:)` expired.
        // We re-express the SAME 300ms trailing debounce as a cancel-and-replace
        // Task (`scheduleDebouncedRefresh`), whose interval defaults to 300ms in
        // production (byte-identical user-visible timing) but which a test can
        // construct with `debounceInterval: 0` and deterministically JOIN via
        // `_awaitRefreshForTesting()` — no timer, no deadline. The `.receive(on:
        // main)` hop is kept so the scheduling call mutates main-actor state on
        // main, matching the `.TPPSyncBegan` observer above.
        syncEnd
            .merge(with: registryChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleDebouncedRefresh() }
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

    /// Trailing-edge debounce of the merged sync-ended / registry-changed
    /// refresh, expressed as a cancel-and-replace Task so it can be joined
    /// deterministically in tests. Each incoming event cancels the pending Task
    /// and starts a fresh `debounceInterval` timer; only the last event in a
    /// burst survives to fire `syncEnded` + `reloadData` — the same trailing-edge
    /// semantics Combine's `.debounce` provided. Created from this `@MainActor`
    /// context, so the Task body is main-actor-isolated and `store.send` /
    /// `reloadData` run on main exactly as before.
    private func scheduleDebouncedRefresh() {
        refreshDebounceTask?.cancel()
        refreshDebounceTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(self.debounceInterval * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self.store.send(.syncEnded)
            self.reloadData()
        }
    }

    /// Test-only deterministic JOIN over the debounced refresh above (the S7
    /// seam). Awaiting this replaces the wall-clock `fulfillment(timeout:)` polls
    /// the Holds tests used to observe the fire-and-forget debounce: under
    /// parallel-CI sim clones a fixed deadline STARVES and fails, whereas
    /// awaiting the actual `Task` value is timing-independent. Bounded because
    /// the Task always completes — it sleeps `debounceInterval` (0 in tests) then
    /// runs a synchronous body, and `.value` returns even if the Task was
    /// cancelled. The grow-until-stable loop re-awaits only when a new Task has
    /// replaced the last-awaited one (a fresh event scheduled during the join).
    /// RELEASE behavior is byte-identical: production never calls this, and it
    /// awaits the same handle the VM already stores.
    func _awaitRefreshForTesting() async {
        var previous: Task<Void, Never>?
        while true {
            let current = refreshDebounceTask
            if current != previous {
                previous = current
                _ = await current?.value
                continue
            }
            break
        }
    }

    func reloadData() {
        #if DEBUG
        let allHeld: [TPPBook] = debugSettings.createTestHoldBooks() ?? bookRegistry.heldBooks
        #else
        let allHeld = bookRegistry.heldBooks
        #endif

        store.send(.registryChanged(held: allHeld))

        // Badge update — centrally managed by AppTabHostView. Migrated off the
        // `.TPPBookRegistryStateDidChange` post to the registry's holds-changed
        // publisher (swarm_8ce6f5ae WS3), which AppTabHostView subscribes to.
        bookRegistry.notifyHoldsChanged()
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
