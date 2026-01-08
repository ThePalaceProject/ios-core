import Combine
import SwiftUI

@MainActor
final class HoldsBookViewModel: ObservableObject, Identifiable {
    let book: TPPBook

    var id: String { book.identifier }

    var isReserved: Bool {
        var reservedFlag = false
        book.defaultAcquisition?.availability.matchUnavailable(
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
    @Published var showLibraryAccountView: Bool = false
    @Published var selectNewLibrary: Bool = false
    @Published var showSearchSheet: Bool = false
    @Published var searchQuery: String = ""
    @Published var visibleBooks: [TPPBook] = []
    private var cancellables = Set<AnyCancellable>()

    init() {
        NotificationCenter.default.publisher(for: .TPPSyncBegan)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.isLoading = true
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

        reloadData()
    }

    private var allBooks: [TPPBook] {
        reservedBookVMs.map { $0.book } + heldBookVMs.map { $0.book }
    }

    func reloadData() {
        // Use test books if debug configuration is enabled, otherwise use real registry data
        #if DEBUG
        let allHeld: [TPPBook] = DebugSettings.shared.createTestHoldBooks() ?? TPPBookRegistry.shared.heldBooks
        #else
        let allHeld = TPPBookRegistry.shared.heldBooks
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

        withAnimation {
            self.reservedBookVMs = reservedVMs
            self.heldBookVMs = heldVMs
            self.visibleBooks = self.allBooks
        }
        
        // Trigger badge update via notification (badge is now centrally managed by AppTabHostView)
        NotificationCenter.default.post(name: .TPPBookRegistryStateDidChange, object: nil)
    }

    func refresh() {
        if TPPUserAccount.sharedAccount().needsAuth {
            if TPPUserAccount.sharedAccount().hasCredentials() {
                TPPBookRegistry.shared.sync()
            } else {
                SignInModalPresenter.presentSignInModalForCurrentAccount {
                    self.reloadData()
                }
            }
        } else {
            TPPBookRegistry.shared.load()
        }
    }

    func loadAccount(_ account: Account) {
        updateFeed(account)
        showLibraryAccountView = false
        selectNewLibrary = false
        reloadData()
    }
    
    private func updateFeed(_ account: Account) {
        if let urlString = account.catalogUrl, let url = URL(string: urlString) {
            TPPSettings.shared.accountMainFeedURL = url
        }
        AccountsManager.shared.currentAccount = account
        
        account.loadAuthenticationDocument { _ in }
        
        NotificationCenter.default.post(name: .TPPCurrentAccountDidChange, object: nil)
    }

    var openSearchDescription: TPPOpenSearchDescription {
        let title = NSLocalizedString("Search Reservations", comment: "")
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
