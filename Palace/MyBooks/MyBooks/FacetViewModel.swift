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

    private var cancellables = Set<AnyCancellable>()

    var currentAccountURL: URL? {
        URL(string: currentAccount?.homePageUrl ?? "")
    }

    init(groupName: String, facets: [Facet]) {
        self.facets = facets
        self.groupName = groupName
        activeSort = facets.first ?? .title
        setupAccountObserver()
        updateAccount()
    }

    private func setupAccountObserver() {
        AccountsManager.shared.currentAccountDidChange
            .sink { [weak self] _ in
                self?.updateAccount()
            }
            .store(in: &cancellables)
    }

    private func updateAccount() {
        currentAccount = AccountsManager.shared.currentAccount
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
