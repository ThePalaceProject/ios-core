//
//  AccountManager.swift
//  Palace
//
//  Created by Maurice Carrier on 10/20/21.
//  Copyright © 2021 The Palace Project. All rights reserved.
//

import Combine

protocol AccountManager {
  var currentAccount: Account? { get set }
  var accounts: [Account] { get }
  var mainFeed: OPDS2CatalogsFeed? { get }
  var catalogs: [OPDS2CatalogsFeed] { get }
  var accountSet: String { get }
  var ageCheck: TPPAgeCheckVerifying { get }
  
  var networkManager: NetworkManager { get }
  
  var currentAccountPublisher: AnyPublisher<Account?, Never> { get }
  var accountsPublisher: AnyPublisher<[Account], Never> { get }
  var mainFeedPublisher: AnyPublisher<OPDS2CatalogsFeed?, Never> { get }
  var catalogPublisher: AnyPublisher<[OPDS2CatalogsFeed], Never> { get }

  func updateAccountSet()
  func clearCache()
}

class AppAccountManager: NSObject, AccountManager, TPPLibraryAccountsProvider {
  
  @Published var mainFeed: OPDS2CatalogsFeed?
  @Published var catalogs: [OPDS2CatalogsFeed] = []
  @Published var accounts: [Account] = []
  @Published var currentAccount: Account? {
    didSet {
      guard let account = currentAccount else { return }
      loadAuthDoc(account)
    }
  }
  
  private(set) var currentAccountId: String? {
    get {
      return UserDefaults.standard.string(forKey: currentAccountIdentifierKey)
    }
    set {

      if let uuid = newValue {
        currentAccount = account(uuid)
      }

      Log.debug(#file, "Setting currentAccountId to \(newValue ?? "N/A")>")
      UserDefaults.standard.set(newValue,
                                forKey: currentAccountIdentifierKey)
    }
  }

  var accountSet: String
  var accountSets = [String: [Account]]()
  var ageCheck: TPPAgeCheckVerifying
  
  var currentAccountPublisher: AnyPublisher<Account?, Never> { $currentAccount.eraseToAnyPublisher() }
  var accountsPublisher: AnyPublisher<[Account], Never> { $accounts.eraseToAnyPublisher() }
  var mainFeedPublisher: AnyPublisher<OPDS2CatalogsFeed?, Never> { $mainFeed.eraseToAnyPublisher() }
  var catalogPublisher: AnyPublisher<[OPDS2CatalogsFeed], Never> { $catalogs.eraseToAnyPublisher() }
  
  var networkManager: NetworkManager
  private var observers = Set<AnyCancellable>()

  static let TPPAccountUUIDs = [
    "urn:uuid:065c0c11-0d0f-42a3-82e4-277b18786949", //NYPL proper
    "urn:uuid:edef2358-9f6a-4ce6-b64f-9b351ec68ac4", //Brooklyn
    "urn:uuid:56906f26-2c9a-4ae9-bd02-552557720b99"  //Simplified Instant Classics
  ]
  
  static let TPPNationalAccountUUIDs = [
    "urn:uuid:6b849570-070f-43b4-9dcc-7ebb4bca292e", //DPLA
    "urn:uuid:f60b644e-4955-4996-a4e5-a192feb4e7f8", //Internet Archive
    "urn:uuid:5278562c-d642-4fda-ad7e-1613077cfb8d", //Open Textbook Library
  ]
  
  let tppAccountUUID = AccountsManager.TPPAccountUUIDs[0]
  
  init(networkManager: NetworkManager) {
    self.accountSet = TPPConfiguration.customUrlHash() ?? (TPPSettings.shared.useBetaLibraries ? TPPConfiguration.betaUrlHash : TPPConfiguration.prodUrlHash)

    self.ageCheck = TPPAgeCheck(ageCheckChoiceStorage: TPPSettings.shared)
    self.networkManager = networkManager
    super.init()

    self.loadCatalogs(
      url: TPPConfiguration.customUrl() ??
        (TPPSettings.shared.useBetaLibraries ? TPPConfiguration.betaUrl : TPPConfiguration.prodUrl)
    )
  }

  func loadCatalogs(url: URL) {
    Log.debug(#file, "Entering loadCatalog...")
    
    let hash = url.absoluteString.md5().base64EncodedStringUrlSafe()
    
    networkManager.fetchCatalog(url: url)
      .sink { [weak self] result in
        if case let .success(feed) = result {
          self?.accountSets[hash] = feed?.catalogs.compactMap { Account(publication: $0) }
        }
      }
      .store(in: &observers)
  }
  
  func loadAuthDoc(_ account: Account) {
    account.loadAuthenticationDocument(using: TPPUserAccount.sharedAccount()) { [weak self] success in
      self?.setMainFeed(account)
    }
  }
  
  private func setMainFeed(_ account: Account) {
    currentAccount = account
    var mainFeed = URL(string: currentAccount!.catalogUrl ?? "")
    
    if currentAccount!.details?.needsAgeCheck ?? false {
      ageCheck.verifyCurrentAccountAgeRequirement(userAccountProvider: TPPUserAccount.sharedAccount(), currentLibraryAccountProvider: self) { meetsAgeReq in
        mainFeed = self.currentAccount?.details?.defaultAuth?.coppaURL(isOfAge: meetsAgeReq)
        
        Log.debug(#function, "mainFeedURL=\(String(describing: mainFeed))")
        TPPSettings.shared.accountMainFeedURL = mainFeed
        UIApplication.shared.delegate?.window??.tintColor = TPPConfiguration.mainColor()
      }
    }
  }

  func updateAccountSet() {
    accountSet = TPPConfiguration.customUrlHash() ?? (TPPSettings.shared.useBetaLibraries ? TPPConfiguration.betaUrlHash : TPPConfiguration.prodUrlHash)
    
    if accounts.isEmpty || TPPConfiguration.customUrlHash() != nil, let url = URL(string: accountSet) {
      loadCatalogs(url: url)
    }
  }
  
  func account(_ uuid: String) -> Account? {
    // get accountSets dictionary first for thread-safety
    var accountSetsCopy = [String: [Account]]()
    var accountSetKey = ""
    
    accountSetsCopy = self.accountSets
    accountSetKey = self.accountSet
    
    // Check primary account set first
    if let accounts = accountSetsCopy[accountSetKey],
       let account = accounts.first(where: { $0.uuid == uuid }) {
      return account
    }
    
    // Check existing account lists
    for accountEntry in accountSetsCopy where accountEntry.key != accountSetKey {
      if let account = accountEntry.value.first(where: { $0.uuid == uuid }) {
        return account
      }
    }
    
    return nil
  }
  
  func clearCache() {
    networkManager.clearCache()
    do {
      let applicationSupportUrl = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
      let appSupportDirContents = try FileManager.default.contentsOfDirectory(at: applicationSupportUrl, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants, .skipsSubdirectoryDescendants])
      let libraryListCaches = appSupportDirContents.filter { (url) -> Bool in
        return url.lastPathComponent.starts(with: "library_list_") && url.pathExtension == "json"
      }
      let authDocCaches = appSupportDirContents.filter { (url) -> Bool in
        return url.lastPathComponent.starts(with: "authentication_document_") && url.pathExtension == "json"
      }
      
      let allCaches = libraryListCaches + authDocCaches
      for cache in allCaches {
        do {
          try FileManager.default.removeItem(at: cache)
        } catch {
          Log.error("ClearCache", "Unable to clear cache for: \(cache)")
        }
      }
    } catch {
      Log.error("ClearCache", "Unable to clear cache")
    }
  }
}

