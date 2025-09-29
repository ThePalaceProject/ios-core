//
//  MyBooksViewModel.swift
//  Palace
//
//  Created by Maurice Carrier on 12/23/22.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import Combine
import Foundation

// MARK: - Group

enum Group: Int {
  case groupSortBy
}

// MARK: - MyBooksViewModel

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

  // MARK: - Initialization

  override init() {
    activeFacetSort = .author
    facetViewModel = FacetViewModel(
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
    guard !isLoading else {
      return
    }
    isLoading = true

    let registryBooks = bookRegistry.myBooks
    let isConnected = Reachability.shared.isConnectedToNetwork()

    let newBooks = isConnected
      ? registryBooks
      : registryBooks.filter { !$0.isExpired }

    // Update published properties
    books = newBooks
    showInstructionsLabel = newBooks.isEmpty || bookRegistry.state == .unloaded
    sortData()
    isLoading = false
  }

  func reloadData() {
    guard !isLoading else {
      return
    }

    if TPPUserAccount.sharedAccount().needsAuth, !TPPUserAccount.sharedAccount().hasCredentials() {
      TPPAccountSignInViewController.requestCredentials(completion: nil)
    } else {
      bookRegistry.sync { [weak self] _, _ in
        self?.loadData()
      }
    }
  }

  @MainActor
  func filterBooks(query: String) async {
    if query.isEmpty {
      loadData()
    } else {
      let currentBooks = books
      let filteredBooks = await Task.detached(priority: .userInitiated) {
        currentBooks.filter {
          $0.title.localizedCaseInsensitiveContains(query) ||
            ($0.authors?.localizedCaseInsensitiveContains(query) ?? false)
        }
      }.value

      books = filteredBooks
    }
  }

  @objc func authenticateAndLoad(account: Account) {
    account.loadAuthenticationDocument { [weak self] success in
      guard let self = self, success else {
        return
      }

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
        "\(first.authors ?? "") \(first.title)" < "\(second.authors ?? "") \(second.title)"
      case .title:
        "\(first.title) \(first.authors ?? "")" < "\(second.title) \(second.authors ?? "")"
      }
    }
  }

  private func updateFeed(_ account: Account) {
    AccountsManager.shared.currentAccount = account
    // Notify the app that the account changed so Catalog and UI refresh appropriately
    NotificationCenter.default.post(name: .TPPCurrentAccountDidChange, object: nil)
  }

  // MARK: - Notification Handling

  private func registerNotifications() {
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleBookRegistryStateChange(_:)),
      name: .TPPBookRegistryStateDidChange,
      object: nil
    )

    // Debounce high-frequency updates from registry changes and sync end
    let registryChange = NotificationCenter.default.publisher(for: .TPPBookRegistryDidChange)
    let syncEnd = NotificationCenter.default.publisher(for: .TPPSyncEnded)

    registryChange
      .merge(with: syncEnd)
      .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
      .sink { [weak self] _ in
        self?.loadData()
      }
      .store(in: &observers)
  }

  @objc private func handleBookRegistryChange() {
    DispatchQueue.main.async { [weak self] in
      self?.loadData()
    }
  }

  @objc private func handleSyncEnd() {
    DispatchQueue.main.async { [weak self] in
      self?.loadData()
    }
  }

  @objc private func handleBookRegistryStateChange(_ notification: Notification) {
    guard
      let info = notification.userInfo as? [String: Any],
      let identifier = info["bookIdentifier"] as? String,
      let raw = info["state"] as? Int,
      let newState = TPPBookState(rawValue: raw)
    else {
      DispatchQueue.main.async { [weak self] in self?.loadData() }
      return
    }

    DispatchQueue.main.async { [weak self] in
      guard let self else {
        return
      }
      if newState == .unregistered {
        // Remove locally so it doesn't flash back in until next sync
        books.removeAll { $0.identifier == identifier }
      } else {
        loadData()
      }
    }
  }

  private func registerPublishers() {
    facetViewModel.$activeSort
      .sink { [weak self] sort in
        guard let self = self else {
          return
        }
        activeFacetSort = sort
        sortData()
      }
      .store(in: &observers)
  }
}
