import Foundation

let currentAccountIdentifierKey = "TPPCurrentAccountIdentifier"

@objc protocol TPPCurrentLibraryAccountProvider: NSObjectProtocol {
  var currentAccount: Account? { get }
}

@objc protocol TPPLibraryAccountsProvider: TPPCurrentLibraryAccountProvider {
  var tppAccountUUID: String { get }
  var currentAccountId: String? { get }
  func account(_ uuid: String) -> Account?
}

/// Manages library accounts asynchronously with authentication & image loading
@objcMembers final class AccountsManager: NSObject, TPPLibraryAccountsProvider {

  static let shared = AccountsManager()
  class func sharedInstance() -> AccountsManager {
    shared
  }

  static let TPPAccountUUIDs = [
    "urn:uuid:065c0c11-0d0f-42a3-82e4-277b18786949", // NYPL proper
    "urn:uuid:edef2358-9f6a-4ce6-b64f-9b351ec68ac4", // Brooklyn
    "urn:uuid:56906f26-2c9a-4ae9-bd02-552557720b99"  // Simplified Instant Classics
  ]

  static let TPPNationalAccountUUIDs = [
    "urn:uuid:6b849570-070f-43b4-9dcc-7ebb4bca292e" // Palace Bookshelf
  ]

  let tppAccountUUID = AccountsManager.TPPAccountUUIDs[0]

  let ageCheck: TPPAgeCheckVerifying
  private var accountSet: String
  private var accountSets = [String: [Account]]()
  private let accountSetsLock = DispatchQueue(label: "com.tpp.accountSetsLock", attributes: .concurrent)

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

    DispatchQueue.global(qos: .background).async {
      self.loadCatalogs(completion: nil)
    }
  }

  private func performLocked<T>(_ action: () -> T) -> T {
    accountSetsLock.sync { action() }
  }

  // MARK: - Account Retrieval
  var currentAccount: Account? {
    get {
      guard let uuid = currentAccountId else { return nil }
      return account(uuid)
    }
    set {
      Log.debug(#file, "Setting currentAccount to <\(newValue?.name ?? "[N/A]")>")
      self.currentAccount?.hasUpdatedToken = false
      currentAccountId = newValue?.uuid
      TPPErrorLogger.setUserID(TPPUserAccount.sharedAccount().barcode)

      NotificationCenter.default.post(name: NSNotification.Name.TPPCurrentAccountDidChange, object: nil)
    }
  }

  private(set) var currentAccountId: String? {
    get { UserDefaults.standard.string(forKey: currentAccountIdentifierKey) }
    set {
      Log.debug(#file, "Setting currentAccountId to \(newValue ?? "N/A")>")
      UserDefaults.standard.set(newValue, forKey: currentAccountIdentifierKey)
    }
  }

  func account(_ uuid: String) -> Account? {
    return performLocked {
      for accounts in accountSets.values {
        if let account = accounts.first(where: { $0.uuid == uuid }) {
          return account
        }
      }
      return nil
    }
  }

  func accounts(_ key: String? = nil) -> [Account] {
    return performLocked {
      let k = key ?? self.accountSet
      return self.accountSets[k] ?? []
    }
  }

  /// Checks if accounts have been loaded
  var accountsHaveLoaded: Bool {
    performLocked {
      return !(accountSets[accountSet]?.isEmpty ?? true)
    }
  }

  // MARK: - Account Loading


  func loadCatalogs(completion: ((Bool) -> ())?) {
    Log.debug(#file, "Entering loadCatalog...")
    let targetUrl = TPPConfiguration.customUrl() ?? (TPPSettings.shared.useBetaLibraries ? TPPConfiguration.betaUrl : TPPConfiguration.prodUrl)
    let hash = targetUrl.absoluteString.md5().base64EncodedStringUrlSafe().trimmingCharacters(in: ["="])

    TPPNetworkExecutor(cachingStrategy: .fallback).GET(targetUrl, useTokenIfAvailable: false) { result in
      switch result {
      case .success(let data, _):
        self.loadAccountSetsAndAuthDoc(fromCatalogData: data, key: hash) { success in
          NotificationCenter.default.post(name: NSNotification.Name.TPPCatalogDidLoad, object: nil)
        }
      case .failure(let error, _):
        TPPErrorLogger.logError(
          withCode: .libraryListLoadFail,
          summary: "Unable to load libraries list",
          metadata: [
            NSUnderlyingErrorKey: error,
            "targetUrl": targetUrl
          ])
        completion?(false)
      }
    }
  }

  /// Clears cached accounts & authentication data
  func clearCache() {
    TPPNetworkExecutor.shared.clearCache()
    let cacheKeys = ["library_list_", "accounts_catalog_", "authentication_document_"]
    let cacheURLs = cacheKeys.compactMap { key -> URL? in
      guard let appSupportUrl = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false) else { return nil }
      return appSupportUrl.appendingPathComponent("\(key).json")
    }
    for cacheURL in cacheURLs {
      try? FileManager.default.removeItem(at: cacheURL)
    }
  }

  private func loadAccountSetsAndAuthDoc(fromCatalogData data: Data, key: String, completion: @escaping (Bool) -> ()) {
    do {
      let catalogsFeed = try OPDS2CatalogsFeed.fromData(data)
      let hadAccount = self.currentAccount != nil
      let accountSet = catalogsFeed.catalogs.map { Account(publication: $0) }

      accountSetsLock.async(flags: .barrier) { self.accountSets[key] = accountSet }

      if hadAccount != (self.currentAccount != nil) {
        self.currentAccount?.loadLogo()
        self.currentAccount?.loadAuthenticationDocument(using: TPPUserAccount.sharedAccount()) { _ in
          DispatchQueue.main.async {
            var mainFeed = URL(string: self.currentAccount?.catalogUrl ?? "")
            let resolveFn = {
              TPPSettings.shared.accountMainFeedURL = mainFeed
              UIApplication.shared.delegate?.window??.tintColor = TPPConfiguration.mainColor()
              NotificationCenter.default.post(name: NSNotification.Name.TPPCurrentAccountDidChange, object: nil)
              completion(true)
            }
            if self.currentAccount?.details?.needsAgeCheck ?? false {
              self.ageCheck.verifyCurrentAccountAgeRequirement(userAccountProvider: TPPUserAccount.sharedAccount(), currentLibraryAccountProvider: self) {
                mainFeed = self.currentAccount?.details?.defaultAuth?.coppaURL(isOfAge: $0)
                resolveFn()
              }
            } else {
              resolveFn()
            }
          }
        }
      } else {
        completion(true)
      }

      let group = DispatchGroup()
      for account in accountSet {
        group.enter()
        DispatchQueue.global(qos: .background).async {
          account.loadLogo()
          group.leave()
        }
      }
      group.notify(queue: .main) {
        completion(true)
      }
    } catch {
      TPPErrorLogger.logError(error, summary: "Error parsing catalog feed")
      completion(false)
    }
  }

  @objc private func updateAccountSetFromNotification(_ notif: NSNotification) {
    updateAccountSet(completion: nil)
  }

  func updateAccountSet(completion: ((Bool) -> ())?) {
    accountSetsLock.async(flags: .barrier) {
      self.accountSet = TPPConfiguration.customUrlHash() ?? (TPPSettings.shared.useBetaLibraries ? TPPConfiguration.betaUrlHash : TPPConfiguration.prodUrlHash)
    }
    if accounts().isEmpty || TPPConfiguration.customUrlHash() != nil {
      loadCatalogs(completion: completion)
    }
  }
}
