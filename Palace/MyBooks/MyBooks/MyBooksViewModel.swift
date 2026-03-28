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
    private var bookRegistry: TPPBookRegistry { TPPBookRegistry.shared }
    private var allBooks: [TPPBook] = []

    // MARK: - Initialization
    override init() {
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

    deinit { }

    // MARK: - Public Methods
    func loadData() {
        guard !isLoading else { return }
        isLoading = true

        // If the account requires authentication and user is not logged in,
        // don't show any books from the registry (they may be stale from a previous session)
        let account = TPPUserAccount.sharedAccount()
        if account.needsAuth && !account.hasCredentials() {
            Log.info(#file, "User not logged in - showing empty My Books")
            self.allBooks = []
            self.books = []
            self.showInstructionsLabel = true
            self.isLoading = false
            return
        }

        let registryBooks = bookRegistry.myBooks
        let isConnected = Reachability.shared.isConnectedToNetwork()

        let newBooks = isConnected
            ? registryBooks
            : registryBooks.filter { !$0.isExpired }

        // Update published properties
        self.allBooks = newBooks
        self.books = newBooks
        self.showInstructionsLabel = newBooks.isEmpty || bookRegistry.state == .unloaded
        self.sortData()
        self.isLoading = false
    }

    func reloadData() {
        guard !isLoading else { return }

        if TPPUserAccount.sharedAccount().needsAuth, !TPPUserAccount.sharedAccount().hasCredentials() {
            SignInModalPresenter.presentSignInModalForCurrentAccount(completion: nil)
        } else {
            bookRegistry.sync { [weak self] _, _ in
                self?.loadData()
            }
        }
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

            if !TPPSettings.shared.settingsAccountIdsList.contains(account.uuid) {
                TPPSettings.shared.settingsAccountIdsList.append(account.uuid)
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
        if !TPPSettings.shared.settingsAccountIdsList.contains(account.uuid) {
            TPPSettings.shared.settingsAccountIdsList.append(account.uuid)
        }

        if let urlString = account.catalogUrl, let url = URL(string: urlString) {
            TPPSettings.shared.accountMainFeedURL = url
        }

        // Setting currentAccount triggers both Combine publisher and NotificationCenter
        AccountsManager.shared.currentAccount = account

        account.loadAuthenticationDocument { _ in }
    }

    // MARK: - Registry Observation
    private func registerNotifications() {
        // Use Combine publishers from TPPBookRegistry directly
        let registryChange = bookRegistry.registryPublisher.map { _ in () }
        let stateChange = bookRegistry.bookStatePublisher.map { _ in () }
        let syncEnd = bookRegistry.syncStatePublisher.filter { !$0 }.map { _ in () }

        registryChange
            .merge(with: stateChange)
            .merge(with: syncEnd)
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.loadData()
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
    }
}
