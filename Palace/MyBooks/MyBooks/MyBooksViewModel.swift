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
class MyBooksViewModel: ObservableObject {
  typealias DisplayStrings = Strings.MyBooksView

  // MARK: - Public Properties
  @Published private(set) var books: [TPPBook] = []
  @Published private(set) var isLoading = false
  @Published var alert: AlertModel?
  @Published var searchQuery = ""
  @Published var showInstructionsLabel = false
  @Published var showSearchSheet = false
  @Published var selectNewLibrary = false
  @Published var showLibraryAccountView = false
  @Published var selectedBook: TPPBook?
  @Published var showAccountScreen = false {
    didSet {
      accountURL = facetViewModel.accountScreenURL
    }
  }

  var accountURL: URL?
  var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

  // MARK: - Private Properties
  var activeFacetSort: Facet
  let facetViewModel: FacetViewModel
  private var observers = Set<AnyCancellable>()
  private var bookRegistry: TPPBookRegistry { TPPBookRegistry.shared }

  // MARK: - Initialization
  init() {
    self.activeFacetSort = .author
    self.facetViewModel = FacetViewModel(
      groupName: DisplayStrings.sortBy,
      facets: [.title, .author]
    )

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

    DispatchQueue.main.async {
      self.isLoading = true
    }

    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self = self else { return }

      let books = Reachability.shared.isConnectedToNetwork()
      ? self.bookRegistry.myBooks
      : self.bookRegistry.myBooks.filter { !$0.isExpired }

      DispatchQueue.main.async {
        self.books = books
        self.showInstructionsLabel = books.isEmpty || self.bookRegistry.state == .unloaded
        self.sortData()
        self.isLoading = false
      }
    }
  }

  func reloadData() {
    guard !isLoading else { return }

    if TPPUserAccount.sharedAccount().needsAuth, !TPPUserAccount.sharedAccount().hasCredentials() {
      TPPAccountSignInViewController.requestCredentials(completion: nil)
    } else {
      bookRegistry.sync()
      loadData()
    }
  }

  func filterBooks(query: String) {
    if query.isEmpty {
      loadData() // Reset to all books
    } else {
      DispatchQueue.global(qos: .userInitiated).async { [weak self] in
        guard let self = self else { return }
        let filteredBooks = self.books.filter {
          $0.title.localizedCaseInsensitiveContains(query) || ($0.authors?.localizedCaseInsensitiveContains(query) ?? false)
        }
        DispatchQueue.main.async {
          self.books = filteredBooks
        }
      }
    }
  }

  func authenticateAndLoad(account: Account) {
    account.loadAuthenticationDocument { [weak self] success in
      guard let self = self, success else { return }

      DispatchQueue.main.async {
        if !TPPSettings.shared.settingsAccountIdsList.contains(account.uuid) {
          TPPSettings.shared.settingsAccountIdsList.append(account.uuid)
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
    books.sort { first, second in
      switch activeFacetSort {
      case .author:
        return "\(first.authors ?? "") \(first.title)" < "\(second.authors ?? "") \(second.title)"
      case .title:
        return "\(first.title) \(first.authors ?? "")" < "\(second.title) \(second.authors ?? "")"
      }
    }
  }

  private func updateFeed(_ account: Account) {
    AccountsManager.shared.currentAccount = account
    if let catalogNavController = TPPRootTabBarController.shared().viewControllers?.first as? TPPCatalogNavigationController {
      catalogNavController.updateFeedAndRegistryOnAccountChange()
    }
  }

  // MARK: - Notification Handling
  private func registerNotifications() {
    NotificationCenter.default.addObserver(self, selector: #selector(handleBookRegistryChange), name: .TPPBookRegistryDidChange, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(handleSyncEnd), name: .TPPSyncEnded, object: nil)
  }

  @objc private func handleBookRegistryChange() {
    loadData()
  }

  @objc private func handleSyncEnd() {
    loadData()
  }

  // MARK: - Combine Publishers
  private func registerPublishers() {
    facetViewModel.$activeSort
      .sink { [weak self] sort in
        guard let self = self else { return }
        self.activeFacetSort = sort
        self.sortData()
      }
      .store(in: &observers)

    facetViewModel.$showAccountScreen
      .sink { [weak self] show in
        self?.showAccountScreen = show
      }
      .store(in: &observers)
  }
}
