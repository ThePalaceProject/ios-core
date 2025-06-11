import Combine
import SwiftUI

final class HoldsBookViewModel: ObservableObject, Identifiable {
    let book: TPPBook

    var id: String { book.identifier }

    var isReserved: Bool {
        var reservedFlag = false
        book.defaultAcquisition?.availability.matchUnavailable(
            nil,
            limited: nil,
            unlimited: nil,
            reserved: nil
        ) { (_: TPPOPDSAcquisitionAvailabilityReady) in
            reservedFlag = true
        }
        return reservedFlag
    }

    init(book: TPPBook) {
        self.book = book
    }
}

final class HoldsViewModel: ObservableObject {
    /// Books "available for checkout"
    @Published var reservedBookVMs: [HoldsBookViewModel] = []

    /// Books "waiting for availability"
    @Published var heldBookVMs: [HoldsBookViewModel] = []

    /// Loading indicator (sync in progress)
    @Published var isLoading: Bool = false

    /// Whether to show the "pick library" sheet
    @Published var showLibraryAccountView: Bool = false

    /// Whether to show the action sheet of existing libraries
    @Published var selectNewLibrary: Bool = false

    /// Whether to show the "search reservations" sheet
    @Published var showSearchView: Bool = false

    private var cancellables = Set<AnyCancellable>()

    init() {
        NotificationCenter.default.publisher(for: .TPPSyncBegan)
            .sink { [weak self] _ in
                self?.isLoading = true
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .TPPSyncEnded)
            .sink { [weak self] _ in
                self?.isLoading = false
                self?.reloadData()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .TPPBookRegistryDidChange)
            .sink { [weak self] _ in
                self?.reloadData()
            }
            .store(in: &cancellables)

        reloadData()
    }

    /// Fetch all held books from the registry, wrap them in `HoldsBookViewModel`,
    /// and split into reserved vs held.
    func reloadData() {
        let allHeld = TPPBookRegistry.shared.heldBooks
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

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.reservedBookVMs = reservedVMs
            self.heldBookVMs = heldVMs
            self.updateBadgeCount()
        }
    }

    func refresh() {
        // If the user needs to sign in first:
        if TPPUserAccount.sharedAccount().needsAuth {
            if TPPUserAccount.sharedAccount().hasCredentials() {
                // We have credentials: trigger a sync
                TPPBookRegistry.shared.sync()
            } else {
                DispatchQueue.main.async {
                    TPPAccountSignInViewController.requestCredentials {
                        self.reloadData()
                    }
                }
            }
        } else {
            TPPBookRegistry.shared.load()
        }
    }

    /// Update application icon badge & tab‐bar badge to match the count of "reserved" books
    private func updateBadgeCount() {
        UIApplication.shared.applicationIconBadgeNumber = reservedBookVMs.count
        
        if let items = TPPRootTabBarController.shared().tabBar.items,
           items.indices.contains(1) {
            items[1].badgeValue = reservedBookVMs.isEmpty ? nil : "\(reservedBookVMs.count)"
        }
    }

    /// Change the current loaded account, then reload data
    func loadAccount(_ account: Account) {
        updateFeed(account)
        showLibraryAccountView = false
        selectNewLibrary = false
        reloadData()
    }
    
    private func updateFeed(_ account: Account) {
        AccountsManager.shared.currentAccount = account
        if let catalogNavController = TPPRootTabBarController.shared().viewControllers?.first as? TPPCatalogNavigationController {
            catalogNavController.updateFeedAndRegistryOnAccountChange()
        }
    }

    /// Build the OpenSearch descriptor for "Search Reservations"
    var openSearchDescription: TPPOpenSearchDescription {
        let title = NSLocalizedString("Search Reservations", comment: "")
        // We pass ALL held books (both reserved and waiting) into the search screen:
        let allVMs = reservedBookVMs + heldBookVMs
        let allBooks = allVMs.map { $0.book }
        return TPPOpenSearchDescription(title: title, books: allBooks)
    }
}
