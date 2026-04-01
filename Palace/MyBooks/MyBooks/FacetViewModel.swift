//
//  FacetViewModel.swift
//  Palace
//
//  Created by Maurice Carrier on 12/23/22.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Foundation
import Combine

enum Facet: String {
    case author
    case title

    var localizedString: String {
        switch self {
        case .author:
            return Strings.FacetView.author
        case .title:
            return Strings.FacetView.title
        }
    }
}

class FacetViewModel: ObservableObject {
    @Published var groupName: String
    @Published var facets: [Facet]
    @Published var activeSort: Facet
    @Published var currentAccount: Account?
    @Published var accountScreenURL: URL?
    @Published var showAccountScreen = false
    @Published var logo: UIImage?

    var currentAccountURL: URL? {
        URL(string: currentAccount?.homePageUrl ?? "")
    }

    private let accountsManager: AccountsManager

    init(groupName: String, facets: [Facet], accountsManager: AccountsManager = AccountsManager.shared) {
        self.facets = facets
        self.groupName = groupName
        self.accountsManager = accountsManager
        activeSort = facets.first ?? .title
        registerForNotifications()
        updateAccount()
    }

    private func registerForNotifications() {
        NotificationCenter.default.addObserver(self, selector: #selector(updateAccount),
                                               name: .TPPCurrentAccountDidChange,
                                               object: nil)
    }

    @objc private func updateAccount() {
        currentAccount = accountsManager.currentAccount
        currentAccount?.logoDelegate = self
        accountScreenURL = currentAccountURL
        logo = currentAccount?.logo
    }
}

extension FacetViewModel: AccountLogoDelegate {
    func logoDidUpdate(in account: Account, to newLogo: UIImage) {
        self.logo = newLogo
    }
}
