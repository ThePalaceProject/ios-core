import Foundation

let currentAccountIdentifierKey = "TPPCurrentAccountIdentifier"

// MARK: - Cache Metadata

/// Metadata for tracking cache freshness in stale-while-revalidate pattern
struct CatalogCacheMetadata: Codable {
  let timestamp: Date
  let hash: String
  
  /// Cache is stale after 5 minutes (should refresh in background)
  private static let staleTTL: TimeInterval = 300
  
  /// Cache expires after 24 hours (must not be used)
  private static let maxAge: TimeInterval = 86400
  
  /// Returns true if cache is stale (older than 5 minutes)
  /// Stale data can still be used, but should trigger background refresh
  var isStale: Bool {
    Date().timeIntervalSince(timestamp) > Self.staleTTL
  }
  
  /// Returns true if cache is expired (older than 24 hours)
  /// Expired data should not be used at all
  var isExpired: Bool {
    Date().timeIntervalSince(timestamp) > Self.maxAge
  }
}

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
      let previousAccountId = currentAccountId
      let newAccountId = newValue?.uuid
      
      Log.debug(#file, "Setting currentAccount to <\(newValue?.name ?? "[N/A]")>")
      Log.debug(#file, "Previous account: \(previousAccountId ?? "nil") → New account: \(newAccountId ?? "nil")")
      
      if previousAccountId != newAccountId, previousAccountId != nil {
        Log.info(#file, "🔄 Account switch detected - cleaning up active content")
        cleanupActiveContentBeforeAccountSwitch(from: previousAccountId, to: newAccountId)
      }
      
      self.currentAccount?.hasUpdatedToken = false
      currentAccountId = newValue?.uuid
      TPPErrorLogger.setUserID(TPPUserAccount.sharedAccount().barcode)
      NotificationCenter.default.post(name: .TPPCurrentAccountDidChange, object: nil)
    }
  }
  
  /// Cleans up active audiobook playback and other content before switching accounts
  private func cleanupActiveContentBeforeAccountSwitch(from previousId: String?, to newId: String?) {
    Task { @MainActor in
      // Clear any active audiobook playback
      if let coordinator = NavigationCoordinatorHub.shared.coordinator {
        let pathCount = coordinator.path.count
        Log.debug(#file, "  Navigation path has \(pathCount) items")
        
        // If there's anything in the navigation stack, pop to root to clean up any active content
        // This prevents audiobooks or other content from continuing to play with the wrong account context
        if pathCount > 0 {
          Log.info(#file, "  🔄 Popping to root to clean up active content before account switch")
          coordinator.popToRoot()
          
          // Give the UI a moment to clean up
          try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
        }
      }
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

  /// Public entrypoint - implements stale-while-revalidate pattern
  /// 1. If data is in memory, return immediately (refresh in background if stale)
  /// 2. If data is on disk and not expired, load it immediately and refresh in background
  /// 3. If no cache or expired, fetch from network
  func loadCatalogs(completion: ((Bool) -> ())?) {
    let targetUrl = TPPConfiguration.customUrl()
    ?? (TPPSettings.shared.useBetaLibraries
        ? TPPConfiguration.betaUrl
        : TPPConfiguration.prodUrl)
    let hash = targetUrl.absoluteString
      .md5()
      .base64EncodedStringUrlSafe()
      .trimmingCharacters(in: ["="])

    // 1. If already loaded in memory, return immediately
    if performRead({ self.accountSets[hash]?.isEmpty == false }) {
      completion?(true)
      // Still refresh in background if stale
      if isCacheStale(hash: hash) {
        refreshInBackground(targetUrl: targetUrl, hash: hash)
      }
      return
    }

    // 2. Try disk cache first (stale-while-revalidate)
    if hasCachedCatalogData(hash: hash),
       let cachedData = readCachedAccountsCatalogData(hash: hash) {
      Log.info(#file, "Loading catalogs from cache (stale-while-revalidate)")
      
      // dedupe concurrent loads for initial cache load
      if addLoadingHandler(for: hash, completion) { return }
      
      loadAccountSetsAndAuthDoc(fromCatalogData: cachedData, key: hash) { [weak self] success in
        NotificationCenter.default.post(name: .TPPCatalogDidLoad, object: nil)
        self?.callAndClearLoadingHandlers(for: hash, success)
      }
      
      // Always refresh in background when loading from cache
      refreshInBackground(targetUrl: targetUrl, hash: hash)
      return
    }

    // 3. No cache or expired - must fetch from network
    Log.debug(#file, "Loading catalogs from network for hash \(hash)…")
    
    // dedupe concurrent loads
    if addLoadingHandler(for: hash, completion) { return }
    
    fetchFromNetwork(targetUrl: targetUrl, hash: hash)
  }
  
  /// Fetches catalog data from network (used for initial load when no cache)
  private func fetchFromNetwork(targetUrl: URL, hash: String) {
    TPPNetworkExecutor.shared.GET(targetUrl, useTokenIfAvailable: false) { [weak self] result in
      guard let self = self else { return }
      switch result {
      case .success(let data, _):
        self.cacheAccountsCatalogData(data, hash: hash)
        self.loadAccountSetsAndAuthDoc(fromCatalogData: data, key: hash) { success in
          NotificationCenter.default.post(name: .TPPCatalogDidLoad, object: nil)
          self.callAndClearLoadingHandlers(for: hash, success)
        }

      case .failure(let error, _):
        Log.error(#file, "Failed to load catalogs from network: \(error.localizedDescription)")
        // fallback to disk (even expired data is better than nothing for network failure)
        if let data = self.readCachedAccountsCatalogData(hash: hash) {
          Log.info(#file, "Using cached catalog data as fallback after network failure")
          self.loadAccountSetsAndAuthDoc(fromCatalogData: data, key: hash) { success in
            NotificationCenter.default.post(name: .TPPCatalogDidLoad, object: nil)
            self.callAndClearLoadingHandlers(for: hash, success)
          }
        } else {
          Log.error(#file, "No cached catalog data available, catalog load failed completely")
          self.callAndClearLoadingHandlers(for: hash, false)
        }
      }
    }
  }
  
  /// Refreshes catalog data in background without blocking the UI
  private func refreshInBackground(targetUrl: URL, hash: String) {
    DispatchQueue.global(qos: .utility).async { [weak self] in
      Log.debug(#file, "Starting background refresh for catalog hash \(hash)")
      
      TPPNetworkExecutor.shared.GET(targetUrl, useTokenIfAvailable: false) { [weak self] result in
        guard let self = self else { return }
        
        switch result {
        case .success(let data, _):
          Log.info(#file, "Background refresh successful for hash \(hash)")
          self.cacheAccountsCatalogData(data, hash: hash)
          self.loadAccountSetsAndAuthDoc(fromCatalogData: data, key: hash) { _ in
            // Notify UI that fresh data is available
            NotificationCenter.default.post(name: .TPPCatalogDidLoad, object: nil)
          }
          
        case .failure(let error, _):
          Log.debug(#file, "Background refresh failed for hash \(hash): \(error.localizedDescription). Using cached data.")
          // Silent failure - we already have cached data displayed
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
  
  private func cacheMetadataUrl(hash: String) -> URL? {
    guard let appSupport = try? FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true)
    else { return nil }
    return appSupport.appendingPathComponent("accounts_catalog_metadata_\(hash).json")
  }

  private func cacheAccountsCatalogData(_ data: Data, hash: String) {
    // Save catalog data
    guard let url = accountsCatalogUrl(hash: hash) else { return }
    try? data.write(to: url)
    
    // Save metadata with current timestamp
    let metadata = CatalogCacheMetadata(timestamp: Date(), hash: hash)
    if let metadataUrl = cacheMetadataUrl(hash: hash),
       let metadataData = try? JSONEncoder().encode(metadata) {
      try? metadataData.write(to: metadataUrl)
    }
  }

  private func readCachedAccountsCatalogData(hash: String) -> Data? {
    guard let url = accountsCatalogUrl(hash: hash) else { return nil }
    return try? Data(contentsOf: url)
  }
  
  /// Reads cache metadata for the given hash
  private func readCacheMetadata(hash: String) -> CatalogCacheMetadata? {
    guard let url = cacheMetadataUrl(hash: hash),
          let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(CatalogCacheMetadata.self, from: data)
  }
  
  /// Returns true if cached data exists and is not expired (can be stale but usable)
  private func hasCachedCatalogData(hash: String) -> Bool {
    guard readCachedAccountsCatalogData(hash: hash) != nil else { return false }
    guard let metadata = readCacheMetadata(hash: hash) else {
      // Data exists but no metadata - treat as usable but stale
      return true
    }
    return !metadata.isExpired
  }
  
  /// Returns true if cache exists and is stale (needs background refresh)
  private func isCacheStale(hash: String) -> Bool {
    guard let metadata = readCacheMetadata(hash: hash) else {
      // No metadata means we should refresh
      return true
    }
    return metadata.isStale
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
