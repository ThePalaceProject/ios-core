//
//  AppController+EventHandler.swift
//  Palace
//
//  Created by Maurice Carrier on 10/19/21.
//  Copyright © 2021 The Palace Project. All rights reserved.
//

import Combine

extension AppController {
  class AppEventHandler {
    private let appContextProvider: AppContextProvider
    private let networkManager: NetworkManager
    private var accountManager: AccountManager
    
    init(
      appContextProvider: AppContextProvider,
      networkManager: NetworkManager,
      accountManager: AccountManager
    ) {
      self.appContextProvider = appContextProvider
      self.networkManager = networkManager
      self.accountManager = accountManager
    }
    
    func handle(_ event: AppEvent) {
      switch event {
      case let .setCurrentAccount(account):
        accountManager.currentAccount = account
      case .updateAccountSet:
        accountManager.updateAccountSet()
      case let .loadCatalog(catalog):
        return
      }
    }
  }
}
