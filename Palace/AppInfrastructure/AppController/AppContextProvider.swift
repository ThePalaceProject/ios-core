//
//  AppContext.swift
//  Palace
//
//  Created by Maurice Carrier on 10/19/21.
//  Copyright © 2021 The Palace Project. All rights reserved.
//

import Foundation
import Combine

protocol AppContext {
  var accountPublisher: AnyPublisher<Account?, Never> { get }
  var catalogPublisher: AnyPublisher<OPDS2CatalogsFeed?, Never> { get }
}

class AppContextProvider {
  @Published var currentAccount: Account?
  @Published var currentCatalog: OPDS2CatalogsFeed?
}

extension AppContextProvider: AppContext {
  var accountPublisher: AnyPublisher<Account?, Never> { $currentAccount.eraseToAnyPublisher() }
  var catalogPublisher: AnyPublisher<OPDS2CatalogsFeed?, Never> { $currentCatalog.eraseToAnyPublisher() }
}
