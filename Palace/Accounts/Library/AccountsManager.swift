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
  class func sharedInstance() -> AccountsManager { shared }

  // MARK: – Config / state

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

  // Per‐catalog in‐flight tracking:
  private var loadingCompletionHandlers = [String: [(Bool) -> Void]]()
  private let loadingHandlersQueue = DispatchQueue(label: "com.tpp.loadingHandlers", attributes: .concurrent)

  private override init() {
    self.accountSet = TPPConfiguration.customUrlHash()
    ?? (TPPSettings.shared.useBetaLibraries
        ? TPPConfiguration.betaUrlHash
        : TPPConfiguration.prodUrlHash)
    self.ageCheck = TPPAgeCheck(ageCheckChoiceStorage: TPPSettings.shared)
    super.init()
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(updateAccountSetFromNotification(_:)),
      name: .TPPUseBetaDidChange,
      object: nil
    )

    DispatchQueue.global(qos: .background).async { [weak self] in
      self?.loadCatalogs(completion: nil)
    }
  }

  // MARK: – Thread‐safe accountSets access

  private func performRead<T>(_ block: () -> T) -> T {
    return accountSetsLock.sync {
      block()
    }
  }

  private func performWrite(_ block: @escaping () -> Void) {
    accountSetsLock.async(flags: .barrier) {
      block()
    }
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
      NotificationCenter.default.post(name: .TPPCurrentAccountDidChange, object: nil)
    }
  }

  private(set) var currentAccountId: String? {
    get { UserDefaults.standard.string(forKey: currentAccountIdentifierKey) }
    set {
      Log.debug(#file, "Setting currentAccountId to \(newValue ?? "N/A")")
      UserDefaults.standard.set(newValue, forKey: currentAccountIdentifierKey)
    }
  }

  func account(_ uuid: String) -> Account? {
    return performRead {
      accountSets.values
        .first { $0.contains(where: { $0.uuid == uuid }) }?
        .first(where: { $0.uuid == uuid })
    }
  }

  func accounts(_ key: String? = nil) -> [Account] {
    return performRead {
      let k = key ?? self.accountSet
      return self.accountSets[k] ?? []
    }
  }

  var accountsHaveLoaded: Bool {
    return performRead {
      !(self.accountSets[self.accountSet]?.isEmpty ?? true)
    }
  }

  // MARK: – Load logic

  /// Adds a completion handler for the given catalog hash,
  /// returns true if a load is already underway.
  private func addLoadingHandler(for hash: String, _ handler: ((Bool) -> Void)?) -> Bool {
    var alreadyLoading = false
    loadingHandlersQueue.sync {
      alreadyLoading = loadingCompletionHandlers[hash] != nil
    }

    guard !alreadyLoading else {
      if let h = handler {
        loadingHandlersQueue.async(flags: .barrier) { [weak self] in
          self?.loadingCompletionHandlers[hash]?.append(h)
        }
      }
      return true
    }

    // first request for this hash
    loadingHandlersQueue.async(flags: .barrier) {
      self.loadingCompletionHandlers[hash] = handler.map { [$0] } ?? []
    }
    return false
  }

  /// Calls & clears all handlers for the given hash
  private func callAndClearLoadingHandlers(for hash: String, _ success: Bool) {
    var handlers: [(Bool)->Void] = []
    loadingHandlersQueue.sync {
      handlers = loadingCompletionHandlers[hash] ?? []
    }
    loadingHandlersQueue.async(flags: .barrier) {
      self.loadingCompletionHandlers[hash] = nil
    }
    handlers.forEach { $0(success) }
  }

  /// Public entrypoint
  func loadCatalogs(completion: ((Bool) -> ())?) {
    let targetUrl = TPPConfiguration.customUrl()
    ?? (TPPSettings.shared.useBetaLibraries
        ? TPPConfiguration.betaUrl
        : TPPConfiguration.prodUrl)
    let hash = targetUrl.absoluteString
      .md5()
      .base64EncodedStringUrlSafe()
      .trimmingCharacters(in: ["="])

    // if already loaded for this hash, immediately call back
    if performRead({ self.accountSets[hash]?.isEmpty == false }) {
      completion?(true)
      return
    }

    // dedupe concurrent loads
    if addLoadingHandler(for: hash, completion) { return }

    Log.debug(#file, "Loading catalogs for hash \(hash)…")
    TPPNetworkExecutor(cachingStrategy: .fallback).GET(targetUrl, useTokenIfAvailable: false) { [weak self] result in
      guard let self = self else { return }
      switch result {
      case .success(let data, _):
        self.cacheAccountsCatalogData(data, hash: hash)
        self.loadAccountSetsAndAuthDoc(fromCatalogData: data, key: hash) { success in
          NotificationCenter.default.post(name: .TPPCatalogDidLoad, object: nil)
          self.callAndClearLoadingHandlers(for: hash, success)
        }

      case .failure:
        // fallback to disk
        if let data = self.readCachedAccountsCatalogData(hash: hash) {
          self.loadAccountSetsAndAuthDoc(fromCatalogData: data, key: hash) { success in
            NotificationCenter.default.post(name: .TPPCatalogDidLoad, object: nil)
            self.callAndClearLoadingHandlers(for: hash, success)
          }
        } else {
          // truly failed
          self.callAndClearLoadingHandlers(for: hash, false)
        }
      }
    }
  }

  // MARK: – Disk cache helpers

  private func accountsCatalogUrl(hash: String) -> URL? {
    guard let appSupport = try? FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true)
    else { return nil }
    return appSupport.appendingPathComponent("accounts_catalog_\(hash).json")
  }

  private func cacheAccountsCatalogData(_ data: Data, hash: String) {
    guard let url = accountsCatalogUrl(hash: hash) else { return }
    try? data.write(to: url)
  }

  private func readCachedAccountsCatalogData(hash: String) -> Data? {
    guard let url = accountsCatalogUrl(hash: hash) else { return nil }
    return try? Data(contentsOf: url)
  }

  // MARK: – Parsing & notifying

  private func loadAccountSetsAndAuthDoc(
    fromCatalogData data: Data,
    key hash: String,
    completion: @escaping (Bool) -> Void
  ) {
    do {
      let feed = try OPDS2CatalogsFeed.fromData(data)
      let hadAccount = self.currentAccount != nil
      let newAccounts = feed.catalogs.map { Account(publication: $0, imageCache: ImageCache.shared) }

      self.performWrite {
        self.accountSets[hash] = newAccounts
      }

      let group = DispatchGroup()

      if hadAccount != (self.currentAccount != nil), let current = self.currentAccount {
        group.enter()
        current.loadLogo()
        current.loadAuthenticationDocument(using: TPPUserAccount.sharedAccount()) { _ in
          if current.details?.needsAgeCheck ?? false {
            group.enter()
            self.ageCheck.verifyCurrentAccountAgeRequirement(
              userAccountProvider: TPPUserAccount.sharedAccount(),
              currentLibraryAccountProvider: self
            ) { _ in group.leave() }
          }
          group.leave()
        }
      }

      group.notify(queue: .main) {
        var mainFeed = URL(string: self.currentAccount?.catalogUrl ?? "")
        if let cur = self.currentAccount, cur.details?.needsAgeCheck ?? false {
          mainFeed = cur.details?.defaultAuth?.coppaURL(isOfAge: true)
        }
        TPPSettings.shared.accountMainFeedURL = mainFeed
        UIApplication.shared.delegate?.window??.tintColor = TPPConfiguration.mainColor()
        NotificationCenter.default.post(name: .TPPCurrentAccountDidChange, object: nil)
        completion(true)
      }

    } catch {
      TPPErrorLogger.logError(error, summary: "Error parsing catalog feed")
      completion(false)
    }
  }

  @objc private func updateAccountSetFromNotification(_ notif: Notification) {
    updateAccountSet(completion: nil)
  }

  func updateAccountSet(completion: ((Bool) -> Void)?) {
    let newHash = TPPConfiguration.customUrlHash()
    ?? (TPPSettings.shared.useBetaLibraries
        ? TPPConfiguration.betaUrlHash
        : TPPConfiguration.prodUrlHash)

    performWrite { self.accountSet = newHash }
    if performRead({ self.accountSets[newHash]?.isEmpty ?? true }) || TPPConfiguration.customUrlHash() != nil {
      loadCatalogs(completion: completion)
    } else {
      completion?(true)
    }
  }

  /// Clears all local catalog and authentication caches
  func clearCache() {
    // network cache
    TPPNetworkExecutor.shared.clearCache()
    // file caches
    let keys = ["library_list_", "accounts_catalog_", "authentication_document_"]
    let fm = FileManager.default
    if let appSupport = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false) {
      for key in keys {
        let url = appSupport.appendingPathComponent("\(key).json")
        try? fm.removeItem(at: url)
      }
    }
  }
}
