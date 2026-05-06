import Combine
import SwiftUI

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
    private var cancellables = Set<AnyCancellable>()
    private let bookRegistry: TPPBookRegistryProvider
    private let accountsManager: AccountsManager
    private let settings: TPPSettings
    private let hasCredentials: () -> Bool

    struct SyncError: Identifiable {
        let id = UUID()
        let message: String
    }

    convenience init() {
        self.init(bookRegistry: TPPBookRegistry.shared)
    }

    init(
        bookRegistry: TPPBookRegistryProvider,
        accountsManager: AccountsManager = .shared,
        settings: TPPSettings = .shared,
        hasCredentials: (() -> Bool)? = nil
    ) {
        self.accountsManager = accountsManager
        self.settings = settings
        self.bookRegistry = bookRegistry
        self.hasCredentials = hasCredentials ?? { accountsManager.currentUserAccount.hasCredentials() }

        NotificationCenter.default.publisher(for: .TPPSyncBegan)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.isLoading = true
                self?.syncError = nil
            }
            .store(in: &cancellables)

        let syncEnd = NotificationCenter.default.publisher(for: .TPPSyncEnded)
        let registryChange = NotificationCenter.default.publisher(for: .TPPBookRegistryDidChange)

        syncEnd
            .merge(with: registryChange)
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.isLoading = false
                self?.reloadData()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .TPPSyncFailed)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.handleSyncFailure(notification)
            }
            .store(in: &cancellables)

        reloadData()
    }

    private func handleSyncFailure(_ notification: Notification) {
        isLoading = false
        // Don't show error banner if we already have holds displayed —
        // the cached data is still useful, no need to alarm the user
        guard visibleBooks.isEmpty else {
            Log.debug(#file, "Sync failed but holds are cached — suppressing error banner")
            return
        }
        // Anonymous users can't fetch holds by design. The empty-state text
        // already explains the Holds tab; an error banner here is noise.
        guard hasCredentials() else {
            Log.debug(#file, "Sync failed for anonymous user — suppressing error banner")
            return
        }
        if let errorDoc = notification.userInfo?[TPPBookRegistry.syncFailureErrorDocumentKey] as? [AnyHashable: Any],
           let detail = (errorDoc["detail"] as? String) ?? (errorDoc["title"] as? String),
           !detail.isEmpty {
            syncError = SyncError(message: detail)
        } else {
            syncError = SyncError(message: Strings.HoldsView.syncFailedMessage)
        }
    }

    func dismissSyncError() {
        syncError = nil
    }

    private var allBooks: [TPPBook] {
        reservedBookVMs.map { $0.book } + heldBookVMs.map { $0.book }
    }

    func reloadData() {
        // Use test books if debug configuration is enabled, otherwise use injected registry data
        #if DEBUG
        let allHeld: [TPPBook] = DebugSettings.shared.createTestHoldBooks() ?? bookRegistry.heldBooks
        #else
        let allHeld = bookRegistry.heldBooks
        #endif

        var reservedVMs: [HoldsBookViewModel] = []
        var heldVMs: [HoldsBookViewModel] = []

        for book in allHeld {
            let vm = HoldsBookViewModel(book: book)
            if vm.isReserved {
                reservedVMs.append(vm)
            } else {
                heldVMs.append(vm)
            }
        }

        // PP-3811: Don't wrap in withAnimation — animating @Published array
        // changes while a child view is pushed on the NavigationStack can cause
        // SwiftUI to unexpectedly pop the navigation (known NavigationStack issue).
        // SwiftUI still animates insertions/removals in LazyVGrid naturally.
        self.reservedBookVMs = reservedVMs
        self.heldBookVMs = heldVMs
        self.visibleBooks = self.allBooks

        // Trigger badge update via notification (badge is now centrally managed by AppTabHostView)
        NotificationCenter.default.post(name: .TPPBookRegistryStateDidChange, object: nil)
    }

    func refresh() {
        if AccountsManager.shared.currentUserAccount.needsAuth {
            if AccountsManager.shared.currentUserAccount.hasCredentials() {
                (bookRegistry as? TPPBookRegistry)?.sync()
            } else {
                SignInModalPresenter.presentSignInModalForCurrentAccount {
                    self.reloadData()
                }
            }
        } else {
            (bookRegistry as? TPPBookRegistry)?.load()
        }
    }

    /// Silent background refresh on appear — syncs without disrupting
    /// the current display if we already have holds to show.
    func refreshInBackground() {
        isVisible = true
        guard !isLoading else { return }
        guard AccountsManager.shared.currentUserAccount.hasCredentials() else { return }
        guard !visibleBooks.isEmpty else { return }
        (bookRegistry as? TPPBookRegistry)?.sync()
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
        if query.isEmpty {
            self.visibleBooks = self.allBooks
        } else {
            let sourceBooks = self.allBooks
            let filtered = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let result = sourceBooks.filter {
                        $0.title.localizedCaseInsensitiveContains(query) ||
                            ($0.authors?.localizedCaseInsensitiveContains(query) ?? false)
                    }
                    continuation.resume(returning: result)
                }
            }
            self.visibleBooks = filtered
        }
    }
}
