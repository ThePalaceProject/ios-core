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

enum FacetSort: Int {
  case facetSortAuthor
  case facetSortTitle
}

class MyBooksViewModel: ObservableObject {
  typealias DisplayStrings = Strings.MyBooksView

  @Published var activeFacetSort: FacetSort
  @Published var isRefreshing: Bool
  @Published var showInstructionsLabel: Bool
  
  private var observers = Set<AnyCancellable>()

  @Published var books: [TPPBook]
  
  init() {
    books = []
    activeFacetSort = .facetSortAuthor
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

    switch activeFacetSort {
    case .facetSortAuthor:
      books = books.sorted {
        let aString = "\(String(describing: $0.authors)) \($0.title)"
        let bString = "\(String(describing: $1.authors)) \($1.title)"
        return aString.caseInsensitiveCompare(bString) == .orderedDescending
        }
    case .facetSortTitle:
      books = books.sorted {
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
  
  func facetViewModel() -> FacetViewModel {
    let facetModel = FacetViewModel(
      groupName: DisplayStrings.sortBy,
      facets: [Facet(title: DisplayStrings.title),
               Facet(title: DisplayStrings.author)]
    )
    
    facetModel.$activeFacet.sink { activeFacet in
      print("active facet \(activeFacet)")
    }
    .store(in: &observers)
    return facetModel
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

extension MyBooksViewModel: TPPFacetViewDataSource {
  func numberOfFacetGroups(in facetView: TPPFacetView!) -> UInt {
    1
  }
  
  func facetView(_ facetView: TPPFacetView!, numberOfFacetsInFacetGroupAt index: UInt) -> UInt {
    2
  }
  
  func facetView(_ facetView: TPPFacetView!, nameForFacetGroupAt index: UInt) -> String! {
    DisplayStrings.sortBy
  }
  
  func facetView(_ facetView: TPPFacetView!, nameForFacetAt indexPath: IndexPath!) -> String! {
    switch Group(rawValue: indexPath.first!)! {
    case .groupSortBy:
      switch FacetSort(rawValue: indexPath.index(of: 1)!)! {
      case .facetSortAuthor:
        return DisplayStrings.author
      case .facetSortTitle:
        return DisplayStrings.title
        return DisplayStrings.title
      }
    }
  }

  func facetView(_ facetView: TPPFacetView!, isActiveFacetForFacetGroupAt index: UInt) -> Bool {
    true
  }
  
  func facetView(_ facetView: TPPFacetView!, activeFacetIndexForFacetGroupAt index: UInt) -> UInt {
    switch Group(rawValue: Int(index))! {
    case .groupSortBy:
      return UInt(activeFacetSort.rawValue)
    }
  }
}

extension MyBooksViewModel: TPPFacetViewDelegate {
  func facetView(_ facetView: TPPFacetView!, didSelectFacetAt indexPath: IndexPath!) {
    defer {
      facetView.reloadData()
      loadData()
    }

    switch Group(rawValue: indexPath.first!)! {
    case .groupSortBy:
      switch FacetSort(rawValue: indexPath.index(of: 1)!)! {
      case .facetSortAuthor:
        activeFacetSort = .facetSortAuthor
      case .facetSortTitle:
        activeFacetSort = .facetSortTitle
      }
    }
  }
}

