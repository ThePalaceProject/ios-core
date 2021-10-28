//
//  AppController.swift
//  Palace
//
//  Created by Maurice Carrier on 10/19/21.
//  Copyright © 2021 The Palace Project. All rights reserved.
//

import UIKit
import Combine

@objc class AppController: NSObject, WithContext {

  var context: AppContext { appContextProvider }
  let eventInput: AppEventSubject = AppEventSubject()

  private let appContextProvider: AppContextProvider
  private let networkManager: NetworkManager
  private let accountManager: AccountManager
  private let eventHandler: AppEventHandler

  private var observers = Set<AnyCancellable>()
  private var dataObservers = Set<AnyCancellable>()
  
  @objc static let shared = AppController()

  override convenience init() {
    let networkManager = AppNetworkManager()
    let accountManager = AppAccountManager(networkManager: networkManager)
    
    self.init(
      appContextProvider: AppContextProvider(),
      networkManager: networkManager,
      accountManager: accountManager
    )
  }
  
  init(
    appContextProvider: AppContextProvider,
    networkManager: NetworkManager,
    accountManager: AccountManager
  ) {
    self.appContextProvider = appContextProvider
    self.networkManager = networkManager
    self.accountManager = accountManager

    self.eventHandler = AppEventHandler(
      appContextProvider: self.appContextProvider,
      networkManager: self.networkManager,
      accountManager: self.accountManager
    )

    super.init()

    subscribeToAccountManager()
    subscribeToEvents()
  }

  private func subscribeToAccountManager() {
    accountManager.currentAccountPublisher
      .assign(to: \.currentAccount, onWeak: appContextProvider)
      .store(in: &observers)

    accountManager.mainFeedPublisher
      .assign(to: \.currentCatalog, onWeak: appContextProvider)
      .store(in: &observers)
  }

  private func subscribeToEvents() {
    eventInput
      .sink { [weak self] event in
        guard let self = self else { return }
        
        self.eventHandler.handle(event)
      }
      .store(in: &observers)
  }
}

