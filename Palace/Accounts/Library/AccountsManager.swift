import Foundation

let currentAccountIdentifierKey  = "TPPCurrentAccountIdentifier"

@objc protocol TPPCurrentLibraryAccountProvider: NSObjectProtocol {
  var currentAccount: Account? {get}
}

@objc protocol TPPLibraryAccountsProvider: TPPCurrentLibraryAccountProvider {
  var tppAccountUUID: String {get}
  var currentAccountId: String? {get}
  func account(_ uuid: String) -> Account?
}

/// Manage the library accounts for the app.
/// Initialized with JSON.
@objcMembers final class AccountsManager: NSObject, TPPLibraryAccountsProvider
{
  static let TPPAccountUUIDs = [
    "urn:uuid:065c0c11-0d0f-42a3-82e4-277b18786949", //NYPL proper
    "urn:uuid:edef2358-9f6a-4ce6-b64f-9b351ec68ac4", //Brooklyn
    "urn:uuid:56906f26-2c9a-4ae9-bd02-552557720b99"  //Simplified Instant Classics
  ]

  static let TPPNationalAccountUUIDs = [
    "urn:uuid:6b849570-070f-43b4-9dcc-7ebb4bca292e" // Palace Bookshelf
  ]

  let tppAccountUUID = AccountsManager.TPPAccountUUIDs[0]

  static let shared = AccountsManager()
  
  let ageCheck: TPPAgeCheckVerifying

  // For Objective-C classes
  class func sharedInstance() -> AccountsManager {
    return shared
  }

  private var accountSet: String

  private var accountSets = [String: [Account]]()
  
  private let accountSetsLock = NSRecursiveLock()
  
  /// Performs a closure within a lock using `accountSetsLock`
  /// - Parameter action: the action inside the locked
  private func performLocked(_ action: () -> Void) {
    accountSetsLock.lock()
    defer {
      accountSetsLock.unlock()
    }
    action()
  }

  var accountsHaveLoaded: Bool {
    var accounts: [Account]?
  
    performLocked {
      accounts = accountSets[accountSet]
    }

    if let accounts = accounts {
      return !accounts.isEmpty
    }
    return false
  }

  private var loadingCompletionHandlers = [String: [(Bool) -> ()]]()

  var currentAccount: Account? {
    get {
      guard let uuid = currentAccountId else {
        return nil
      }

      return account(uuid)
    }
    set {
      Log.debug(#file, "Setting currentAccount to <\(newValue?.name ?? "[name N/A]") LibUUID=\(newValue?.uuid ?? "[UUID N/A]")>")
      currentAccountId = newValue?.uuid
      TPPErrorLogger.setUserID(TPPUserAccount.sharedAccount().barcode)
      NotificationCenter.default.post(name: NSNotification.Name.TPPCurrentAccountDidChange,
                                      object: nil)
    }
  }

  private(set) var currentAccountId: String? {
    get {
      return UserDefaults.standard.string(forKey: currentAccountIdentifierKey)
    }
    set {
      Log.debug(#file, "Setting currentAccountId to \(newValue ?? "N/A")>")
      UserDefaults.standard.set(newValue,
                                forKey: currentAccountIdentifierKey)
    }
  }

  private override init() {
    self.accountSet = TPPConfiguration.customUrlHash() ?? (TPPSettings.shared.useBetaLibraries ? TPPConfiguration.betaUrlHash : TPPConfiguration.prodUrlHash)
    self.ageCheck = TPPAgeCheck(ageCheckChoiceStorage: TPPSettings.shared)
    
    super.init()

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(updateAccountSetFromNotification(_:)),
      name: NSNotification.Name.TPPUseBetaDidChange,
      object: nil
    )

    // It needs to be done asynchronously, so that init returns prior to calling it
    // Otherwise it would try to access itself before intialization is finished
    // Network executor will try to access shared accounts manager, as it needs it to get headers data
    // Think of this async block as you would about viewDidLoad which is
    // triggered after a view is loaded.
    OperationQueue.current?.underlyingQueue?.async {
      // on OE this ends up loading the OPDS2_Catalog_feed.json file stored
      // in the app bundle
      self.loadCatalogs(completion: nil)
    }
  }

  let completionHandlerAccessQueue = DispatchQueue(label: "libraryListCompletionHandlerAccessQueue")

  /// Adds `handler` to the list of completion handlers for `key`.
  ///
  /// - Returns: `true` if loading was happening already.
  private func addLoadingCompletionHandler(key: String,
                                           _ handler: ((Bool) -> ())?) -> Bool {
    var wasEmpty = false
    completionHandlerAccessQueue.sync {
      if loadingCompletionHandlers[key] == nil {
        loadingCompletionHandlers[key] = [(Bool)->()]()
      }
      wasEmpty = loadingCompletionHandlers[key]!.isEmpty
      // On the previous implementation, we do not add the handler to the list if it is nil.
      // If the first handler is nil, the second handler would find the list empty and continue loading
      // And the same loading request would happen more than once, adding a empty completion block void such situation
      let h: ((Bool) -> ()) = handler ?? { _ in }
      loadingCompletionHandlers[key]!.append(h)
    }
    return !wasEmpty
  }

  /**
   Resolves any complation handlers that may have been queued waiting for a registry fetch
   and clears the queue.
   @param key the key for the completion handler list, since there are multiple
   @param success success indicator to pass on to each handler
   */
  private func callAndClearLoadingCompletionHandlers(key: String, _ success: Bool) {
    var handlers = [(Bool) -> ()]()
    completionHandlerAccessQueue.sync {
      if let h = loadingCompletionHandlers[key] {
        handlers = h
        loadingCompletionHandlers[key] = []
      }
    }
    for handler in handlers {
      handler(success)
    }
  }

  /**
   Take the library list data (either from cache or the internet), load it into
   self.accounts, and load the auth document for the current account if
   necessary.
   - parameter data: The library catalog list data obtained from fetching either
   `NYPLConfiguration.prodUrl` or `NYPLConfiguration.betaUrl`. This is parsed
   assuming it's in the OPDS2 format.
   - parameter key: The key to enter the `accountSets` dictionary with.
   - parameter completion: Always invoked at the end no matter what, providing
   `true` in case of success and `false` otherwise. No guarantees are being made
   about whether this will be called on the main thread or not.
   */
  private func loadAccountSetsAndAuthDoc(fromCatalogData data: Data,
                                         key: String,
                                         completion: @escaping (Bool) -> ()) {
    do {
      let catalogsFeed = try OPDS2CatalogsFeed.fromData(data)
      let hadAccount = self.currentAccount != nil
      let accountSet = catalogsFeed.catalogs.map { Account(publication: $0) }

      performLocked {
        accountSets[key] = accountSet
      }

      // note: `currentAccount` computed property feeds off of `accountSets`, so
      // changing the `accountsSets` dictionary will also change `currentAccount`
      Log.debug(#function, "hadAccount=\(hadAccount) currentAccountID=\(currentAccountId ?? "N/A") currentAcct=\(String(describing: currentAccount))")
      if hadAccount != (self.currentAccount != nil) {
        self.currentAccount?.loadAuthenticationDocument(using: TPPUserAccount.sharedAccount(), completion: { success in
          DispatchQueue.main.async {
            var mainFeed = URL(string: self.currentAccount?.catalogUrl ?? "")
            let resolveFn = {
              Log.debug(#function, "mainFeedURL=\(String(describing: mainFeed))")
              TPPSettings.shared.accountMainFeedURL = mainFeed
              UIApplication.shared.delegate?.window??.tintColor = TPPConfiguration.mainColor()
              NotificationCenter.default.post(name: NSNotification.Name.TPPCurrentAccountDidChange, object: nil)
              completion(true)
            }

            // TODO: Test if this is still necessary
            // In past, there was a support for only 1 authenticationmethod, so there was no issue from which of them to pick needsAgeCheck value
            // currently we do support multiple auth methods, and age check is dependant on which of them does user select
            // there is a logic in NYPLUserAcccount authDefinition setter to perform an age check, but it wasn't tested
            // most probably you can delete this check from here
            if self.currentAccount?.details?.needsAgeCheck ?? false {
              self.ageCheck.verifyCurrentAccountAgeRequirement(userAccountProvider: TPPUserAccount.sharedAccount(),
                                                               currentLibraryAccountProvider: self) { meetsAgeRequirement in
                DispatchQueue.main.async {
                  mainFeed = self.currentAccount?.details?.defaultAuth?.coppaURL(isOfAge: meetsAgeRequirement)
                  resolveFn()
                }
              }
            } else {
              resolveFn()
            }
          }
        })
      } else {
        // we pass `true` because at this point we know the catalogs loaded
        // successfully
        completion(true)
      }
    } catch (let error) {
      TPPErrorLogger.logError(error,
                               summary: "Error while parsing catalog feed")
      completion(false)
    }
  }

  /// Loads library catalogs from the network or cache if available.
  ///
  /// After loading the library accounts, the authentication document
  /// for the current library will be loaded in sequence.
  ///
  /// - Parameter completion: Always invoked at the end of the load process.
  /// No guarantees are being made about whether this is called on the main
  /// thread or not.
  func loadCatalogs(completion: ((Bool) -> ())?) {
    Log.debug(#file, "Entering loadCatalog...")
    let targetUrl = TPPConfiguration.customUrl() ?? (TPPSettings.shared.useBetaLibraries ? TPPConfiguration.betaUrl : TPPConfiguration.prodUrl)
    let hash = targetUrl.absoluteString.md5().base64EncodedStringUrlSafe()
      .trimmingCharacters(in: ["="])

    let wasAlreadyLoading = addLoadingCompletionHandler(key: hash, completion)
    guard !wasAlreadyLoading else { return }

    TPPNetworkExecutor(cachingStrategy: .fallback).GET(targetUrl, useTokenIfAvailable: true) { result in
      switch result {
      case .success(let data, _):
        self.loadAccountSetsAndAuthDoc(fromCatalogData: data, key: hash) { success in
          self.callAndClearLoadingCompletionHandlers(key: hash, success)
          NotificationCenter.default.post(name: NSNotification.Name.TPPCatalogDidLoad, object: nil)
          self.cacheAccountsCatalogData(data, hash: hash)
        }
      case .failure(let error, _):
        // Try file cache
        self.readCachedAccountsCatalogData(urlHash: hash) { data in
          if let data = data {
            self.loadAccountSetsAndAuthDoc(fromCatalogData: data, key: hash) { success in
              self.callAndClearLoadingCompletionHandlers(key: hash, success)
              NotificationCenter.default.post(name: NSNotification.Name.TPPCatalogDidLoad, object: nil)
            }
          } else {
            TPPErrorLogger.logError(
              withCode: .libraryListLoadFail,
              summary: "Unable to load libraries list",
              metadata: [
                NSUnderlyingErrorKey: error,
                "targetUrl": targetUrl
            ])
            self.callAndClearLoadingCompletionHandlers(key: hash, false)
          }
        }
      }
    }
  }

  func account(_ uuid: String) -> Account? {
    // get accountSets dictionary first for thread-safety
    var accountSetsCopy = [String: [Account]]()
    var accountSetKey = ""

    performLocked {
      accountSetsCopy = self.accountSets
      accountSetKey = self.accountSet
    }

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

  func accounts(_ key: String? = nil) -> [Account] {
    var accounts: [Account]? = []

    performLocked {
      let k = key ?? self.accountSet
      accounts = self.accountSets[k]
    }

    return accounts ?? []
  }

  @objc private func updateAccountSetFromNotification(_ notif: NSNotification) {
    updateAccountSet(completion: nil)
  }

  func updateAccountSet(completion: ((Bool) -> ())?) {

    performLocked {
      self.accountSet = TPPConfiguration.customUrlHash() ?? (TPPSettings.shared.useBetaLibraries ? TPPConfiguration.betaUrlHash : TPPConfiguration.prodUrlHash)
    }
    
    if self.accounts().isEmpty || TPPConfiguration.customUrlHash() != nil {
      loadCatalogs(completion: completion)
    } 
  }

  func clearCache() {
    TPPNetworkExecutor.shared.clearCache()
    do {
      let applicationSupportUrl = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
      let appSupportDirContents = try FileManager.default.contentsOfDirectory(at: applicationSupportUrl, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants, .skipsSubdirectoryDescendants])
      let libraryListCaches = appSupportDirContents.filter { (url) -> Bool in
        return url.lastPathComponent.starts(with: "library_list_") && url.pathExtension == "json"
      }
      let accountsCatalogCaches = appSupportDirContents.filter { (url) -> Bool in
        return url.lastPathComponent.starts(with: "accounts_catalog_") && url.pathExtension == "json"
      }
      let authDocCaches = appSupportDirContents.filter { (url) -> Bool in
        return url.lastPathComponent.starts(with: "authentication_document_") && url.pathExtension == "json"
      }
      
      let allCaches = libraryListCaches + authDocCaches + accountsCatalogCaches
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
  
  /// Returns cached catalog data file URL
  /// - Parameter urlHash: target URL hash
  /// - Returns: Cached accounts catalog data file URL
  private func accountsCatalogUrl(urlHash: String) -> URL? {
    guard let applicationSupportUrl = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false) else {
      return nil
    }
    return applicationSupportUrl.appendingPathComponent("accounts_catalog_\(urlHash).json")
  }
  
  /// Write accounts catalog data
  /// - Parameters:
  ///   - data: Accounts catalog data
  ///   - hash: targetUrl hash
  private func cacheAccountsCatalogData(_ data: Data, hash: String) {
    if let cacheUrl = accountsCatalogUrl(urlHash: hash) {
      do {
        try data.write(to: cacheUrl)
      } catch {
        Log.error("AccountsCatalogCache", error.localizedDescription)
      }
    }
  }
  
  /// Read accounts catalog data
  /// - Parameters:
  ///   - urlHash: targetUrl hash
  ///   - completion: completion with accounts catalog data
  private func readCachedAccountsCatalogData(urlHash: String, completion: (Data?) -> Void) {
    guard let cacheUrl = accountsCatalogUrl(urlHash: urlHash), let data = try? Data(contentsOf: cacheUrl) else {
      Log.error("AccountsCatalogCache", "Unable to read accounts catalog cache")
      completion(nil)
      return
    }
    completion(data)
  }
  
}
