//
//  FacetViewModel.swift
//  Palace
//
//  Created by Maurice Carrier on 12/23/22.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Combine
import Foundation

// MARK: - Facet

enum Facet: String {
  case author
  case title

  var localizedString: String {
    switch self {
    case .author:
      Strings.FacetView.author
    case .title:
      Strings.FacetView.title
    }
  }
}

// MARK: - FacetViewModel

class FacetViewModel: ObservableObject {
  @Published var groupName: String
  @Published var facets: [Facet]
  @Published var activeSort: Facet
  @Published var currentAccount: Account?
  @Published var accountScreenURL: URL? = nil
  @Published var showAccountScreen = false
  @Published var logo: UIImage?

  var currentAccountURL: URL? {
    URL(string: currentAccount?.homePageUrl ?? "")
  }

  init(groupName: String, facets: [Facet]) {
    self.facets = facets
    self.groupName = groupName
    activeSort = facets.first!
    registerForNotifications()
    updateAccount()
  }

  private func registerForNotifications() {
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(updateAccount),
      name: .TPPCurrentAccountDidChange,
      object: nil
    )
  }

  @objc private func updateAccount() {
    currentAccount = AccountsManager.shared.currentAccount
    currentAccount?.logoDelegate = self
    accountScreenURL = currentAccountURL
    logo = currentAccount?.logo
  }
}

// MARK: AccountLogoDelegate

extension FacetViewModel: AccountLogoDelegate {
  func logoDidUpdate(in _: Account, to newLogo: UIImage) {
    logo = newLogo
  }
}
