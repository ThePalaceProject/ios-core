import Foundation

let currentAccountIdentifierKey = "TPPCurrentAccountIdentifier"

// MARK: - Cache Metadata

/// Metadata for tracking cache freshness in stale-while-revalidate pattern
struct CatalogCacheMetadata: Codable {
    let timestamp: Date
    let hash: String

    /// Default stale TTL: 6 hours (half the server's typical Cache-Control
    /// max-age of 12hr). Overridden dynamically by `staleTTL(serverMaxAge:)`.
    private static let defaultStaleTTL: TimeInterval = 21600

    /// Cache expires after 24 hours (must not be used)
    private static let maxAge: TimeInterval = 86400

    /// Returns the stale TTL, dynamically adjusted from the server's
    /// Cache-Control max-age if available. Uses half the server's value
    /// with a floor of 5 minutes and a ceiling of 12 hours.
    static func staleTTL(serverMaxAge: TimeInterval?) -> TimeInterval {
        guard let serverMax = serverMaxAge, serverMax > 0 else {
            return defaultStaleTTL
        }
        let half = serverMax / 2
        return min(max(half, 300), 43200) // clamp to [5min, 12hr]
    }

    /// Returns true if cache is stale given the server's max-age hint.
    func isStale(serverMaxAge: TimeInterval?) -> Bool {
        Date().timeIntervalSince(timestamp) > Self.staleTTL(serverMaxAge: serverMaxAge)
    }

    /// Returns true if cache is stale using the default TTL (no server hint).
    var isStale: Bool {
        isStale(serverMaxAge: nil)
    }

    /// Returns true if cache is expired (older than 24 hours)
    var isExpired: Bool {
        Date().timeIntervalSince(timestamp) > Self.maxAge
    }
}

@objc protocol TPPCurrentLibraryAccountProvider: NSObjectProtocol {
    var currentAccount: Account? { get }
}

/// Resolves per-library `TPPUserAccount` instances. Prefer this over
/// `TPPUserAccount.sharedAccount(libraryUUID:)` — instances returned by
/// this protocol have immutable keychain keys and are not subject to the
/// TOCTOU race in the singleton's mutable `libraryUUID` pattern.
@objc protocol TPPUserAccountResolving: NSObjectProtocol {
    func userAccount(for libraryUUID: String) -> TPPUserAccount
    var currentUserAccount: TPPUserAccount { get }
}

@objc protocol TPPLibraryAccountsProvider: TPPCurrentLibraryAccountProvider {
    var tppAccountUUID: String { get }
    var currentAccountId: String? { get }
    func account(_ uuid: String) -> Account?
}

/// Manages library accounts asynchronously with authentication & image loading
@objcMembers final class AccountsManager: NSObject, TPPLibraryAccountsProvider, TPPUserAccountResolving {

    static let shared = AccountsManager()
    static func sharedInstance() -> AccountsManager { shared }

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

    /// True during an account switch — suppresses sign-in modal presentation
    /// to prevent the intermittent login prompt (F-032).
    private(set) var isAccountSwitching = false

    let ageCheck: TPPAgeCheckVerifying
    private let settings: TPPSettings
    private let networkExecutor: TPPNetworkExecutor
    private var accountSet: String
    private var accountSets = [String: [Account]]()
    private let accountSetsLock = DispatchQueue(label: "com.tpp.accountSetsLock", attributes: .concurrent)

    private let catalogPreloader = CatalogPreloader()

    // Per‐catalog in‐flight tracking:
    private var loadingCompletionHandlers = [String: [(Bool) -> Void]]()
    private let loadingHandlersQueue = DispatchQueue(label: "com.tpp.loadingHandlers", attributes: .concurrent)

    private override init() {
        self.settings = .shared
        self.networkExecutor = .shared
        self.accountSet = TPPConfiguration.customUrlHash()
            ?? (settings.useBetaLibraries
                    ? TPPConfiguration.betaUrlHash
                    : TPPConfiguration.prodUrlHash)
        self.ageCheck = TPPAgeCheck(ageCheckChoiceStorage: settings)
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
                isAccountSwitching = true
                cleanupActiveContentBeforeAccountSwitch(from: previousAccountId, to: newAccountId)
                // Evict decoded cover images — the new library has different covers.
                // Keeps compressed JPEG cache on disk for fast re-decode if user switches back.
                ImageCache.shared.evictAllDecodedImages()
            }

            self.currentAccount?.hasUpdatedToken = false
            currentAccountId = newValue?.uuid
            TPPErrorLogger.setUserID(self.currentUserAccount.barcode)
            isAccountSwitching = false
            NotificationCenter.default.post(name: .TPPCurrentAccountDidChange, object: nil)
        }
    }

    /// Cleans up active audiobook playback, in-flight network requests, and other
    /// content before switching accounts to prevent cross-account credential leaks.
    private func cleanupActiveContentBeforeAccountSwitch(from previousId: String?, to newId: String?) {
        networkExecutor.cancelNonEssentialTasks()

        Task { @MainActor in
            if let coordinator = NavigationCoordinatorHub.shared.coordinator {
                let pathCount = coordinator.path.count
                Log.debug(#file, "  Navigation path has \(pathCount) items")

                if pathCount > 0 {
                    Log.info(#file, "  🔄 Popping to root to clean up active content before account switch")
                    coordinator.popToRoot()

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

    // MARK: - Per-Account User Credentials

    /// Cache of per-library `TPPUserAccount` instances. Each instance has
    /// immutable keychain keys, eliminating the TOCTOU race that the
    /// singleton's mutable `libraryUUID` pattern was subject to.
    private var userAccounts = [String: TPPUserAccount]()
    private let userAccountsLock = NSLock()

    /// Returns a library-scoped `TPPUserAccount` instance. Creates and
    /// caches a new one on first access for a given UUID.
    func userAccount(for libraryUUID: String) -> TPPUserAccount {
        userAccountsLock.lock()
        defer { userAccountsLock.unlock() }
        if let existing = userAccounts[libraryUUID] {
            return existing
        }
        let account = TPPUserAccount(libraryUUID: libraryUUID)
        userAccounts[libraryUUID] = account
        return account
    }

    /// Convenience for the current library's user account.
    var currentUserAccount: TPPUserAccount {
        guard let id = currentAccountId else {
            // Fallback to legacy singleton when no account is selected
            return TPPUserAccount.sharedAccount()
        }
        return userAccount(for: id)
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
        var handlers: [(Bool) -> Void] = []
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
    func loadCatalogs(completion: ((Bool) -> Void)?) {
        let targetUrl = TPPConfiguration.customUrl()
            ?? (settings.useBetaLibraries
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

    /// Fetches catalog data using the first-page fast path:
    /// 1. Fetch first page (~35KB, ~260ms) → display immediately
    /// 2. Paginate remaining pages in background → update cache when done
    /// Falls back to a direct GET if even the first page fails.
    private func fetchFromNetwork(targetUrl: URL, hash: String) {
        Task(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            Log.debug(#file, "Fetching catalogs via first-page fast path for hash \(hash)")

            let crawler = LibraryRegistryCrawler(fetcher: URLSessionCrawlerFetcher(), hash: hash)

            // Step 1: Fetch first page for immediate display
            let firstPageResult = await crawler.crawlFirstPage(baseURL: targetUrl)

            switch firstPageResult {
            case .success(let firstPageData):
                // Display first page immediately
                self.cacheAccountsCatalogData(firstPageData, hash: hash)
                self.loadAccountSetsAndAuthDoc(fromCatalogData: firstPageData, key: hash) { success in
                    NotificationCenter.default.post(name: .TPPCatalogDidLoad, object: nil)
                    self.callAndClearLoadingHandlers(for: hash, success)
                }

                // Step 2: Paginate remaining pages in background
                Task(priority: .utility) { [weak self] in
                    guard let self = self else { return }
                    guard let firstPage = try? OPDS2CatalogsFeed.fromData(firstPageData),
                          firstPage.nextPageURL != nil else {
                        // Only one page — already displayed everything
                        self.triggerCatalogPreload()
                        return
                    }

                    Log.debug(#file, "Crawling remaining pages in background for hash \(hash)")
                    let remainingResult = await crawler.crawlRemainingPages(
                        firstPage: firstPage,
                        baseURL: targetUrl,
                        existingPublications: firstPage.catalogs,
                        feedMetadata: firstPage.metadata
                    )

                    if case .success(let fullData) = remainingResult {
                        self.cacheAccountsCatalogData(fullData, hash: hash)
                        self.loadAccountSetsAndAuthDoc(fromCatalogData: fullData, key: hash) { _ in
                            NotificationCenter.default.post(name: .TPPCatalogDidLoad, object: nil)
                        }
                    }
                    self.triggerCatalogPreload()
                }

            case .noChanges:
                self.callAndClearLoadingHandlers(for: hash, true)

            case .failure:
                Log.info(#file, "First page crawl failed, falling back to direct GET")
                self.fallbackFetchFromNetwork(targetUrl: targetUrl, hash: hash)
            }
        }
    }

    /// Fallback direct GET when crawler fails on first launch.
    private func fallbackFetchFromNetwork(targetUrl: URL, hash: String) {
        networkExecutor.GET(targetUrl, useTokenIfAvailable: false) { [weak self] result in
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

    /// Refreshes catalog data in background using the incremental crawler.
    /// Falls back to a direct GET if the crawlable endpoint fails.
    private func refreshInBackground(targetUrl: URL, hash: String) {
        Task(priority: .utility) { [weak self] in
            guard let self = self else { return }
            Log.debug(#file, "Starting background refresh (crawl) for catalog hash \(hash)")

            // Parse existing cached publications for merge
            let existingPubs: [OPDS2Publication]
            let existingMetadata: OPDS2CatalogsFeed.Metadata?
            if let cachedData = self.readCachedAccountsCatalogData(hash: hash),
               let feed = try? OPDS2CatalogsFeed.fromData(cachedData) {
                existingPubs = feed.catalogs
                existingMetadata = feed.metadata
            } else {
                existingPubs = []
                existingMetadata = nil
            }

            let crawler = LibraryRegistryCrawler(fetcher: URLSessionCrawlerFetcher(), hash: hash)
            let result = await crawler.crawl(
                baseURL: targetUrl,
                existingPublications: existingPubs,
                feedMetadata: existingMetadata
            )

            switch result {
            case .success(let data):
                Log.info(#file, "Background crawl successful for hash \(hash)")
                self.cacheAccountsCatalogData(data, hash: hash)
                self.loadAccountSetsAndAuthDoc(fromCatalogData: data, key: hash) { [weak self] _ in
                    NotificationCenter.default.post(name: .TPPCatalogDidLoad, object: nil)
                    // Preload catalogs for active accounts
                    self?.triggerCatalogPreload()
                }

            case .noChanges:
                Log.debug(#file, "Background crawl found no changes for hash \(hash)")
                // Still preload catalogs — they may not be cached yet
                self.triggerCatalogPreload()

            case .failure(let error):
                Log.debug(#file, "Background crawl failed for hash \(hash): \(error.localizedDescription)")
                // Fallback: try direct GET (old behavior)
                self.fallbackDirectRefresh(targetUrl: targetUrl, hash: hash)
            }
        }
    }

    /// Fallback to direct GET when crawlable endpoint fails.
    private func fallbackDirectRefresh(targetUrl: URL, hash: String) {
        networkExecutor.GET(targetUrl, useTokenIfAvailable: false) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let data, _):
                Log.info(#file, "Fallback direct refresh successful for hash \(hash)")
                self.cacheAccountsCatalogData(data, hash: hash)
                self.loadAccountSetsAndAuthDoc(fromCatalogData: data, key: hash) { _ in
                    NotificationCenter.default.post(name: .TPPCatalogDidLoad, object: nil)
                }
            case .failure(let error, _):
                Log.debug(#file, "Fallback direct refresh also failed for hash \(hash): \(error.localizedDescription)")
            }
        }
    }

    /// Triggers catalog feed preloading for active accounts.
    private func triggerCatalogPreload() {
        Task(priority: .utility) { [weak self] in
            guard let self = self else { return }
            await self.catalogPreloader.preloadCatalogs(
                currentAccount: self.currentAccount,
                recentAccountUUIDs: self.settings.settingsAccountIdsList,
                accountProvider: { self.account($0) }
            )
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
        // Use server's Cache-Control max-age if available from crawl state
        let serverMaxAge = readCrawlState(hash: hash)?.serverMaxAge
        return metadata.isStale(serverMaxAge: serverMaxAge)
    }

    /// Reads crawl state for the given hash (used for dynamic TTL adjustment)
    private func readCrawlState(hash: String) -> CrawlState? {
        guard let appSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else { return nil }
        let url = appSupport.appendingPathComponent("crawl_state_\(hash).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CrawlState.self, from: data)
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
            let oldAccounts = self.accounts(hash)
            let newAccounts = feed.catalogs.map { Account(publication: $0, imageCache: ImageCache.shared) }

            // Carry over authenticationDocument (and thus details) from old
            // accounts so a background refresh doesn't nil-out details while
            // the user is actively using the app. Also invalidate logo cache
            // entries when the thumbnail URL has changed.
            for newAccount in newAccounts {
                if let old = oldAccounts.first(where: { $0.uuid == newAccount.uuid }) {
                    if let authDoc = old.authenticationDocument {
                        newAccount.authenticationDocument = authDoc
                    }
                    // Evict cached logo if the thumbnail URL changed
                    if old.logoUrl != newAccount.logoUrl {
                        ImageCache.shared.remove(for: newAccount.uuid)
                    }
                }
            }

            self.performWrite {
                self.accountSets[hash] = newAccounts
            }

            let group = DispatchGroup()

            let accountExistenceChanged = hadAccount != (self.currentAccount != nil)
            let currentAccountMissingDetails = self.currentAccount != nil && self.currentAccount?.details == nil

            if accountExistenceChanged || currentAccountMissingDetails, let current = self.currentAccount {
                group.enter()
                current.loadLogo()
                current.loadAuthenticationDocument(using: self.currentUserAccount) { _ in
                    if current.details?.needsAgeCheck ?? false {
                        group.enter()
                        self.ageCheck.verifyCurrentAccountAgeRequirement(
                            userAccountProvider: self.currentUserAccount,
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
                self.settings.accountMainFeedURL = mainFeed
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
            ?? (settings.useBetaLibraries
                    ? TPPConfiguration.betaUrlHash
                    : TPPConfiguration.prodUrlHash)

        performWrite { self.accountSet = newHash }
        if performRead({ self.accountSets[newHash]?.isEmpty ?? true }) || TPPConfiguration.customUrlHash() != nil {
            loadCatalogs(completion: completion)
        } else {
            completion?(true)
        }
    }

    /// Clears all local catalog, crawl state, and authentication caches
    func clearCache() {
        // network cache
        networkExecutor.clearCache()
        // file caches — delete all files matching known prefixes
        let prefixes = [
            "library_list_",
            "accounts_catalog_",
            "accounts_catalog_metadata_",
            "authentication_document_",
            "crawl_state_",
        ]
        let fm = FileManager.default
        guard let appSupport = try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else { return }

        guard let files = try? fm.contentsOfDirectory(
            at: appSupport,
            includingPropertiesForKeys: nil
        ) else { return }

        for file in files {
            let name = file.lastPathComponent
            if prefixes.contains(where: { name.hasPrefix($0) }) {
                try? fm.removeItem(at: file)
            }
        }
    }
}
