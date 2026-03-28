import Foundation
import Combine

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

/// Actor that protects AccountsManager's shared mutable state.
/// Replaces the concurrent DispatchQueue + barrier reader/writer pattern.
private actor AccountsState {
    var accountSet: String
    var accountSets = [String: [Account]]()
    var loadingCompletionHandlers = [String: [(Bool) -> Void]]()

    init(accountSet: String) {
        self.accountSet = accountSet
    }

    // MARK: - Account Sets

    func getAccountSet() -> String { accountSet }
    func setAccountSet(_ value: String) { accountSet = value }

    func getAccounts(_ key: String?) -> [Account] {
        let k = key ?? accountSet
        return accountSets[k] ?? []
    }

    func setAccounts(_ accounts: [Account], for key: String) {
        accountSets[key] = accounts
    }

    func accountsHaveLoaded() -> Bool {
        !(accountSets[accountSet]?.isEmpty ?? true)
    }

    func accountsEmpty(for key: String) -> Bool {
        accountSets[key]?.isEmpty ?? true
    }

    func findAccount(_ uuid: String) -> Account? {
        accountSets.values
            .first { $0.contains(where: { $0.uuid == uuid }) }?
            .first(where: { $0.uuid == uuid })
    }

    // MARK: - Loading Handlers

    /// Returns true if a load is already in progress for this hash.
    func addLoadingHandler(for hash: String, _ handler: ((Bool) -> Void)?) -> Bool {
        let alreadyLoading = loadingCompletionHandlers[hash] != nil

        if alreadyLoading {
            if let h = handler {
                loadingCompletionHandlers[hash]?.append(h)
            }
            return true
        }

        // First request for this hash
        loadingCompletionHandlers[hash] = handler.map { [$0] } ?? []
        return false
    }

    func drainLoadingHandlers(for hash: String) -> [(Bool) -> Void] {
        let handlers = loadingCompletionHandlers[hash] ?? []
        loadingCompletionHandlers[hash] = nil
        return handlers
    }
}

/// Manages library accounts asynchronously with authentication & image loading
@objcMembers final class AccountsManager: NSObject, TPPLibraryAccountsProvider {

    static let shared = AccountsManager()
    static func sharedInstance() -> AccountsManager { shared }

    // MARK: - Combine Publishers

    /// Publishes when the current account changes (replaces `.TPPCurrentAccountDidChange` notification)
    private let currentAccountSubject = PassthroughSubject<Account?, Never>()

    /// Publisher for current account changes. Use instead of observing `.TPPCurrentAccountDidChange`.
    var currentAccountDidChange: AnyPublisher<Account?, Never> {
        currentAccountSubject
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }

    /// Publishes when catalog data finishes loading (replaces `.TPPCatalogDidLoad` notification)
    private let catalogDidLoadSubject = PassthroughSubject<Void, Never>()

    /// Publisher for catalog load events. Use instead of observing `.TPPCatalogDidLoad`.
    var catalogDidLoad: AnyPublisher<Void, Never> {
        catalogDidLoadSubject
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }

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
    private let state: AccountsState

    private override init() {
        let initialAccountSet = TPPConfiguration.customUrlHash()
            ?? (TPPSettings.shared.useBetaLibraries
                    ? TPPConfiguration.betaUrlHash
                    : TPPConfiguration.prodUrlHash)
        self.state = AccountsState(accountSet: initialAccountSet)
        self.ageCheck = TPPAgeCheck(ageCheckChoiceStorage: TPPSettings.shared)
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateAccountSetFromNotification(_:)),
            name: .TPPUseBetaDidChange,
            object: nil
        )

        Task { [weak self] in
            self?.loadCatalogs(completion: nil)
        }
    }

    // MARK: – Thread‐safe accountSets access (actor-backed)

    /// Synchronous read for backward compatibility. Uses semaphore to block
    /// the calling thread while the actor processes the request.
    /// Prefer the async variants for new code.
    private func performRead<T>(_ block: @escaping (AccountsState) async -> T) -> T {
        // Fast path: if we're already in a Task context, this will work.
        // For synchronous callers, we use a semaphore to bridge.
        let semaphore = DispatchSemaphore(value: 0)
        var result: T!
        Task {
            result = await block(self.state)
            semaphore.signal()
        }
        semaphore.wait()
        return result
    }

    /// Fire-and-forget write for backward compatibility.
    private func performWrite(_ block: @escaping (AccountsState) async -> Void) {
        Task {
            await block(self.state)
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
            currentAccountSubject.send(newValue)
            NotificationCenter.default.post(name: .TPPCurrentAccountDidChange, object: nil)
        }
    }

    /// Cleans up active audiobook playback, in-flight network requests, and other
    /// content before switching accounts to prevent cross-account credential leaks.
    private func cleanupActiveContentBeforeAccountSwitch(from previousId: String?, to newId: String?) {
        TPPNetworkExecutor.shared.cancelNonEssentialTasks()

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
        return performRead { state in
            await state.findAccount(uuid)
        }
    }

    func accounts(_ key: String? = nil) -> [Account] {
        return performRead { state in
            await state.getAccounts(key)
        }
    }

    var accountsHaveLoaded: Bool {
        return performRead { state in
            await state.accountsHaveLoaded()
        }
    }

    // MARK: – Load logic

    /// Adds a completion handler for the given catalog hash,
    /// returns true if a load is already underway.
    private func addLoadingHandler(for hash: String, _ handler: ((Bool) -> Void)?) -> Bool {
        return performRead { state in
            await state.addLoadingHandler(for: hash, handler)
        }
    }

    /// Calls & clears all handlers for the given hash
    private func callAndClearLoadingHandlers(for hash: String, _ success: Bool) {
        Task {
            let handlers = await self.state.drainLoadingHandlers(for: hash)
            handlers.forEach { $0(success) }
        }
    }

    /// Public entrypoint - implements stale-while-revalidate pattern
    /// 1. If data is in memory, return immediately (refresh in background if stale)
    /// 2. If data is on disk and not expired, load it immediately and refresh in background
    /// 3. If no cache or expired, fetch from network
    func loadCatalogs(completion: ((Bool) -> Void)?) {
        let targetUrl = TPPConfiguration.customUrl()
            ?? (TPPSettings.shared.useBetaLibraries
                    ? TPPConfiguration.betaUrl
                    : TPPConfiguration.prodUrl)
        let hash = targetUrl.absoluteString
            .md5()
            .base64EncodedStringUrlSafe()
            .trimmingCharacters(in: ["="])

        // 1. If already loaded in memory, return immediately
        if performRead({ state in await !state.accountsEmpty(for: hash) }) {
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
                self?.catalogDidLoadSubject.send()
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
                    self.catalogDidLoadSubject.send()
                    NotificationCenter.default.post(name: .TPPCatalogDidLoad, object: nil)
                    self.callAndClearLoadingHandlers(for: hash, success)
                }

            case .failure(let error, _):
                Log.error(#file, "Failed to load catalogs from network: \(error.localizedDescription)")
                // fallback to disk (even expired data is better than nothing for network failure)
                if let data = self.readCachedAccountsCatalogData(hash: hash) {
                    Log.info(#file, "Using cached catalog data as fallback after network failure")
                    self.loadAccountSetsAndAuthDoc(fromCatalogData: data, key: hash) { success in
                        self.catalogDidLoadSubject.send()
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
        Task.detached(priority: .utility) { [weak self] in
            Log.debug(#file, "Starting background refresh for catalog hash \(hash)")

            TPPNetworkExecutor.shared.GET(targetUrl, useTokenIfAvailable: false) { [weak self] result in
                guard let self = self else { return }

                switch result {
                case .success(let data, _):
                    Log.info(#file, "Background refresh successful for hash \(hash)")
                    self.cacheAccountsCatalogData(data, hash: hash)
                    self.loadAccountSetsAndAuthDoc(fromCatalogData: data, key: hash) { _ in
                        // Notify UI that fresh data is available
                        self.catalogDidLoadSubject.send()
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
            let oldAccounts = self.accounts(hash)
            let newAccounts = feed.catalogs.map { Account(publication: $0, imageCache: ImageCache.shared) }

            // Carry over authenticationDocument (and thus details) from old
            // accounts so a background refresh doesn't nil-out details while
            // the user is actively using the app.
            for newAccount in newAccounts {
                if let old = oldAccounts.first(where: { $0.uuid == newAccount.uuid }),
                   let authDoc = old.authenticationDocument {
                    newAccount.authenticationDocument = authDoc
                }
            }

            self.performWrite { state in
                await state.setAccounts(newAccounts, for: hash)
            }

            let group = DispatchGroup()

            let accountExistenceChanged = hadAccount != (self.currentAccount != nil)
            let currentAccountMissingDetails = self.currentAccount != nil && self.currentAccount?.details == nil

            if accountExistenceChanged || currentAccountMissingDetails, let current = self.currentAccount {
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
                self.currentAccountSubject.send(self.currentAccount)
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

        performWrite { state in await state.setAccountSet(newHash) }
        if performRead({ state in await state.accountsEmpty(for: newHash) }) || TPPConfiguration.customUrlHash() != nil {
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
