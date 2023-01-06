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

class MyBooksViewModel: ObservableObject {
  typealias DisplayStrings = Strings.MyBooksView

  var activeFacetSort: Facet {
    didSet {
      sortData()
    }
  }
  
  var facetViewModel: FacetViewModel {
    let facetModel = FacetViewModel(
      groupName: DisplayStrings.sortBy,
      facets: [.title, .author]
    )
    
    facetModel.$activeFacet.sink { activeFacet in
      self.activeFacetSort = activeFacet
    }
    .store(in: &observers)
    return facetModel
  }

  @Published var isRefreshing: Bool
  @Published var showInstructionsLabel: Bool
  
  private var observers = Set<AnyCancellable>()

  @Published var books: [TPPBook]
  
  init() {
    books = []
    activeFacetSort = Facet.author
    isRefreshing = true
    showInstructionsLabel = false

    registerForNotifications()
    loadData()
  }
  
  deinit {
    NotificationCenter.default.removeObserver(self)
  }
  
  private func loadData() {
    books = TPPBookRegistry.shared.myBooks
  }

  private func sortData() {
   switch activeFacetSort {
    case .author:
      books.sort {
        let aString = "\(String(describing: $0.authors)) \($0.title)"
        let bString = "\(String(describing: $1.authors)) \($1.title)"
        return aString.caseInsensitiveCompare(bString) == .orderedDescending
      }
    case .title:
      books.sort {
        let aString = "\($0.title) \(String(describing: $0.authors))"
        let bString = "\($1.title) \(String(describing: $1.authors))"
        return aString.caseInsensitiveCompare(bString) == .orderedDescending
      }
    }
  }
  
  private func registerForNotifications() {
    NotificationCenter.default.addObserver(self, selector: #selector(bookRegistryDidChange),
                                           name: .TPPBookRegistryDidChange,
                                           object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(bookRegistryStateDidChange),
                                           name: .TPPBookRegistryDidChange,
                                           object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(syncBegan),
                                           name: .TPPSyncBegan,
                                           object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(syncEnded),
                                           name: .TPPSyncEnded,
                                           object: nil)
  }

  @objc private func bookRegistryDidChange() {
    DispatchQueue.main.async {
      self.reloadData()
      self.showInstructionsLabel = self.books.count == 0 || TPPBookRegistry.shared.state == .unloaded
    }
  }
  
  @objc private func bookRegistryStateDidChange() {
    DispatchQueue.main.async {
      self.isRefreshing = false
    }
  }
  
  @objc private func syncBegan() {
    
  }
  
  @objc private func syncEnded() {
    DispatchQueue.main.async {
      self.isRefreshing = false
      self.reloadData()
    }
  }
  
  func reloadData() {
    defer {
      loadData()
    }
  
    if TPPUserAccount.sharedAccount().needsAuth && !TPPUserAccount.sharedAccount().hasCredentials() {
      isRefreshing = false
      TPPAccountSignInViewController.requestCredentials(completion: nil)
    } else {
      TPPBookRegistry.shared.sync()
    }
  }
  
  func refresh() {
    if AccountsManager.shared.currentAccount?.loansUrl != nil {
      reloadData()
    } else {
      isRefreshing = false
    }
  }
}
