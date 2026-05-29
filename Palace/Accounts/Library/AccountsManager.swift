import Foundation
import PalaceLogging
import PalaceCatalog

let currentAccountIdentifierKey = "TPPCurrentAccountIdentifier"

// MARK: - Cache Metadata

/// Metadata for tracking cache freshness in stale-while-revalidate pattern
struct CatalogCacheMetadata: Codable {
    let timestamp: Date
    let hash: String
    /// `true` when this cache entry was populated from the build-time
    /// bundled snapshot (`Palace/Accounts/Library/bundled_registry.json`),
    /// `false` for entries written from a network response. Bundled-origin
    /// caches return `true` from `isStale(serverMaxAge:now:)` regardless
    /// of timestamp so the refresh trigger keeps firing on every
    /// `loadCatalogs` call until a real network response overwrites the
    /// metadata with `isBundled = false`. Decodes as `false` for legacy
    /// metadata files written before this field existed.
    let isBundled: Bool

    init(timestamp: Date, hash: String, isBundled: Bool = false) {
        self.timestamp = timestamp
        self.hash = hash
        self.isBundled = isBundled
    }

    private enum CodingKeys: String, CodingKey {
        case timestamp, hash, isBundled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.timestamp = try container.decode(Date.self, forKey: .timestamp)
        self.hash = try container.decode(String.self, forKey: .hash)
        self.isBundled = try container.decodeIfPresent(Bool.self, forKey: .isBundled) ?? false
    }

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
        isStale(serverMaxAge: serverMaxAge, now: Date())
    }

    func isStale(serverMaxAge: TimeInterval?, now: Date) -> Bool {
        // Bundled-origin caches are always stale for refresh purposes
        // regardless of timestamp. The bundled bytes are usable for
        // immediate display but not authoritative, so refresh has to
        // keep firing until a real network response overwrites with
        // `isBundled = false`.
        if isBundled { return true }
        return now.timeIntervalSince(timestamp) > Self.staleTTL(serverMaxAge: serverMaxAge)
    }

    /// Returns true if cache is stale using the default TTL (no server hint).
    var isStale: Bool {
        isStale(serverMaxAge: nil)
    }

    /// Returns true if cache is expired (older than 24 hours)
    var isExpired: Bool {
        isExpired(now: Date())
    }

    func isExpired(now: Date) -> Bool {
        now.timeIntervalSince(timestamp) > Self.maxAge
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

@objc protocol TPPLibraryAccountsProvider: TPPCurrentLibraryAccountProvider, TPPUserAccountResolving {
    var tppAccountUUID: String { get }
    var currentAccountId: String? { get }
    func account(_ uuid: String) -> Account?
}

/// Manages library accounts asynchronously with authentication & image loading
@objcMembers final class AccountsManager: NSObject, TPPLibraryAccountsProvider, TPPUserAccountResolving {

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
    /// Lazy-resolved from AppContainer to break the singleton init cycle:
    /// AccountsManager is constructed inline by AppContainer._cached's
    /// initializer, so we cannot read AppContainer.production() during this
    /// class's init. The lazy var is first accessed *after* AppContainer
    /// finishes constructing, so the cached instance is ready.
    private lazy var networkExecutor: TPPNetworkExecutor = AppContainer.production().networkExecutor
    private var accountSet: String
    private var accountSets = [String: [Account]]()
    private let accountSetsLock = DispatchQueue(label: "com.tpp.accountSetsLock", attributes: .concurrent)

    private let catalogPreloader = CatalogPreloader()

    // Per‐catalog in‐flight tracking:
    private var loadingCompletionHandlers = [String: [(Bool) -> Void]]()
    private let loadingHandlersQueue = DispatchQueue(label: "com.tpp.loadingHandlers", attributes: .concurrent)

    /// Per-UUID single-flight guard for `authentication_document` fetches.
    /// Without this, two concurrent consumers calling `awaitReady()` on the
    /// same Account would each cause `current.loadAuthenticationDocument` to
    /// fire a duplicate HTTP request. The state machine's broadcast
    /// (`CurrentValueSubject`) handles multi-consumer observation; this set
    /// just prevents the duplicate network request. See ADR
    /// docs/architecture/account-state-machine.md Open Q #1.
    private var inflightAuthDocFetches = Set<String>()
    private let inflightAuthDocLock = NSLock()

    #if DEBUG
    /// Test-only opt-out from the post-init background `loadCatalogs` spawn.
    /// When `true`, `AccountsManager.init()` skips the
    /// `DispatchQueue.global(qos: .background).async { loadCatalogs(...) }`
    /// dispatch — eliminating the cross-test race where lingering background
    /// work from a previously-constructed AccountsManager instance writes
    /// through to `accountSets` / `AccountStateStore.shared` mid-test.
    ///
    /// Production callers never set this. The suite-level `setUp` of any
    /// XCTestCase that constructs multiple `AccountsManager()` instances
    /// should set it to `true` in `setUp` and reset to `false` in `tearDown`
    /// to keep the flag flip scoped. NOT compiled into release builds.
    ///
    /// See `feedback_wiring_suite_test_isolation.md` for the underlying race.
    internal static var deferInitialLoadCatalogsForTesting: Bool = false

    /// Test-only handle to the post-init background `loadCatalogs` task so
    /// `cancelBackgroundWork()` can issue cooperative cancellation. Only ever
    /// non-nil under DEBUG builds AND when `deferInitialLoadCatalogsForTesting`
    /// was `false` at init time. Production reads this field implicitly via
    /// `cancelBackgroundWork()` (called by `AppContainer._resetForTesting()`);
    /// production does NOT pay the storage cost in release builds because the
    /// whole field is `#if DEBUG`-gated.
    ///
    /// swarm_4b64e4e0 Fix 2 — closes the H1 finding from swarm_f88ae9e3 A.
    private var backgroundFetchTask: Task<Void, Never>?
    #endif

    /// Initializer is `internal` rather than `private` so `AppContainer` can
    /// construct the single live instance directly. Outside of `AppContainer`
    /// (and tests that need an isolated instance), do not call this directly
    /// — read `appContainer.accountsManager` instead.
    override init() {
        self.settings = TPPSettings()
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

        // Synchronously pre-populate accountSets from the on-disk cache before
        // returning. Without this, AppContainer.production() returns while
        // loadCatalogs() is still running on a background queue, so any UI
        // mounted in that window — including Settings -> Libraries and the
        // sign-in modal — calls account(uuid) against an empty dict and renders
        // an empty list. The async refresh below still runs to pick up any
        // server-side registry changes.
        preloadAccountsFromDiskCacheSync()

        #if DEBUG
        if Self.deferInitialLoadCatalogsForTesting {
            // Test-only path: skip the background dispatch. The wiring suite
            // (and any future XCTestCase constructing multiple instances)
            // sets this flag to eliminate the cross-test race where lingering
            // background work writes through state mid-test. Tests that need
            // `loadCatalogs` semantics call `manager.loadCatalogs(...)`
            // explicitly. Production never takes this branch.
            return
        }
        // DEBUG-only arm: use `Task.detached` so the background work is
        // cancellable from `cancelBackgroundWork()` (called by
        // `AppContainer._resetForTesting()`). Production continues to use
        // `DispatchQueue.global(qos: .background).async` — byte-identical to
        // the prior behaviour. swarm_4b64e4e0 Fix 2.
        backgroundFetchTask = Task.detached(priority: .background) { [weak self] in
            self?.loadCatalogs(completion: nil)
        }
        #else
        DispatchQueue.global(qos: .background).async { [weak self] in
            self?.loadCatalogs(completion: nil)
        }
        #endif
    }

    /// Hydrate `accountSets[accountSet]` from the on-disk OPDS2 catalog cache
    /// without dispatching to a background queue. Safe to call from `init()`
    /// because the cache read is local I/O measured in single-digit ms.
    ///
    /// Exposed `internal` so contract-snapshot tests can drive the preload
    /// path directly after seeding the on-disk cache.
    internal func preloadAccountsFromDiskCacheSync() {
        let hash = self.accountSet
        guard hasCachedCatalogData(hash: hash),
              let cachedData = readCachedAccountsCatalogData(hash: hash) else {
            return
        }
        do {
            let feed = try OPDS2CatalogsFeed.fromData(cachedData)
            let accounts = feed.catalogs.map {
                Account(publication: $0, imageCache: ImageCache.shared)
            }
            performWrite { self.accountSets[hash] = accounts }
            // Account state-machine wiring (3.2.0): Phase 1 — drive every
            // preloaded account into `.basicInfoLoaded`. Display-only
            // consumers (Settings/Libraries) can render the row immediately;
            // critical-path readers `awaitReady()` continue blocking until
            // the auth-doc transition completes below.
            for account in accounts {
                account._setState(.basicInfoLoaded)
            }
            Log.info(#file, "Pre-loaded \(accounts.count) accounts from disk cache (sync, hash=\(hash))")
        } catch {
            // Best-effort. If the cached blob is corrupt or schema-shifted,
            // we silently fall through to the async network refresh.
            Log.warn(#file, "Sync disk-cache pre-load failed: \(error). Will refresh from network async.")
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
                ImageCache.shared.evictDecodedImages()
            }

            self.currentAccount?.hasUpdatedToken = false
            currentAccountId = newValue?.uuid

            // Account state-machine wiring (3.2.0): Phase 1 — when the user
            // switches libraries, terminate any lingering `awaitReady()`
            // callers on the *prior* account with a definitive answer.
            // `.detailsEvicted(.libraryDeselected)` is the chosen terminal:
            //   - `.notLoaded` would leave awaiters hanging until reselect.
            //   - `.detailsFailed(.accountNotFound)` was the original
            //     terminal (PR #961) and confused this eviction marker with
            //     a real HTTP-404 load failure — `driveCurrentAccountAuthDoc
            //     IfNeeded` had to special-case the conflation. PR #1021
            //     (Module A, swarm_51f248d5) split the case so the two
            //     meanings stop sharing storage; the driver READ matches on
            //     `.detailsEvicted(.libraryDeselected)` directly.
            // Awaiters on this terminal throw `AccountLoadError.evicted`
            // (distinct from `.accountNotFound`) so consumers can decide
            // whether to retry, re-resolve, or simply discard the request.
            // Re-entering the same UUID later overwrites the marker through
            // the `.basicInfoLoaded` path on the next preload/loadCatalogs.
            if let prev = previousAccountId, prev != newAccountId {
                AccountStateStore.shared.setState(
                    .detailsEvicted(.libraryDeselected(uuid: prev)),
                    for: prev
                )
            }

            // Account state-machine wiring (3.2.0): drive the NEW
            // currentAccount past `.basicInfoLoaded` after the switch.
            // Sibling of the `loadCatalogs` warm-path driver (PR #975) —
            // same disease class, different trigger. Without this, every
            // `awaitReady()` caller (audiobook open, token refresh,
            // bookmark sync, CarPlay auth) hangs forever the first time
            // the user opens content on the newly-selected library.
            // Single-flight guard inside `fetchAuthDocumentWithStateMachine`
            // dedupes against any concurrent fetch from refresh-in-background.
            driveCurrentAccountAuthDocIfNeeded()

            TPPErrorLogger.setUserID(self.currentUserAccount.barcode)
            // isAccountSwitching is reset asynchronously by cleanupActiveContentBeforeAccountSwitch
            // after navigation cleanup completes — NOT here, to avoid premature reset (F-032).
            if Self.shouldFinishSwitchingImmediately(previousAccountId: previousAccountId, newAccountId: newAccountId) {
                isAccountSwitching = false
            }
            NotificationCenter.default.post(name: .TPPCurrentAccountDidChange, object: nil)
        }
    }

    /// Cleans up active audiobook playback, in-flight network requests, and other
    /// content before switching accounts to prevent cross-account credential leaks.
    private func cleanupActiveContentBeforeAccountSwitch(from previousId: String?, to newId: String?) {
        networkExecutor.cancelNonEssentialTasks()
        MyBooksDownloadCenter.clearAllBorrowReauthState()

        Task { @MainActor [weak self] in
            if let coordinator = AppContainer.production().navigationCoordinatorHub.coordinator {
                let pathCount = coordinator.path.count
                Log.debug(#file, "  Navigation path has \(pathCount) items")

                if Self.shouldPopToRoot(navigationPathCount: pathCount) {
                    Log.info(#file, "  🔄 Popping to root to clean up active content before account switch")
                    coordinator.popToRoot()

                    try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
                }
            }
            // Reset flag AFTER async cleanup completes — not in the setter (F-032)
            self?.isAccountSwitching = false
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

    #if DEBUG
    /// Test-only: seed an Account into `accountSets[currentHash]` and set
    /// `currentAccountId` to its UUID, so `AppContainer.production()
    /// .accountsManager.currentAccount` returns it. Used by Bucket A
    /// integration tests that need to exercise production-stack code
    /// paths reading `currentAccount` (e.g.
    /// `AppContainer.production().audiobookSession.openAudiobook`,
    /// `CarPlayAuthHelper.isAuthenticated`,
    /// `TPPBookRegistry.syncAsync`, `BookRegistrySync.sync`) without
    /// requiring a real OPDS2 catalog fixture load. Closes the 4 XCTSkip
    /// blocks the swarm Phase 1 implementers flagged.
    ///
    /// Returns a teardown closure that removes the seeded account and
    /// restores the prior `currentAccountIdentifierKey`. Callers should
    /// defer-call it to keep the production singleton uncontaminated.
    ///
    /// NOT exposed in production builds.
    @discardableResult
    func _seedAccountForTesting(_ account: Account) -> () -> Void {
        let seedKey = self.accountSet
        performWrite {
            var seeded = self.accountSets[seedKey] ?? []
            seeded.removeAll { $0.uuid == account.uuid }
            seeded.append(account)
            self.accountSets[seedKey] = seeded
        }
        let previousId = UserDefaults.standard.string(forKey: currentAccountIdentifierKey)
        UserDefaults.standard.set(account.uuid, forKey: currentAccountIdentifierKey)
        return {
            self.performWrite {
                self.accountSets[seedKey]?.removeAll { $0.uuid == account.uuid }
            }
            if let prev = previousId {
                UserDefaults.standard.set(prev, forKey: currentAccountIdentifierKey)
            } else {
                UserDefaults.standard.removeObject(forKey: currentAccountIdentifierKey)
            }
        }
    }
    #endif

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

    /// Last account returned from `currentUserAccount`. Used to ride out the
    /// brief windows where `currentAccountId` is nil during an account switch
    /// — without this, consumers observe a transiently-unauthenticated state
    /// on an account that IS signed in, and fire spurious sign-in modals.
    private var lastKnownCurrentUserAccount: TPPUserAccount?

    /// Sentinel UUID for the "no account selected" placeholder. Not a real
    /// library UUID — keychain reads for this instance return nil, so
    /// hasCredentials() deterministically returns false.
    private static let noAccountSentinelUUID = "__no_account_selected__"

    /// Placeholder returned by `currentUserAccount` only on a truly fresh
    /// install before any account has ever been selected. Lazily created so
    /// app launch doesn't pay for a keychain-probed instance.
    private lazy var noAccountPlaceholder: TPPUserAccount = TPPUserAccount(
        libraryUUID: AccountsManager.noAccountSentinelUUID
    )

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
    ///
    /// Thread-safety note: `currentAccountId` can transiently be nil during an
    /// account switch (the old id is cleared before the new id is assigned).
    /// If we blindly fell back to a fresh/empty instance in that window,
    /// consumers like MyBooksDownloadCenter would observe `hasCredentials ==
    /// false` on an account that IS signed in and fire a spurious login modal.
    /// We cache the last-resolved account and return it during the nil window
    /// instead. The placeholder path only fires on a true fresh-install state
    /// where no account has ever been selected.
    var currentUserAccount: TPPUserAccount {
        if let id = currentAccountId {
            let account = userAccount(for: id)
            userAccountsLock.lock()
            lastKnownCurrentUserAccount = account
            userAccountsLock.unlock()
            return account
        }
        userAccountsLock.lock()
        let last = lastKnownCurrentUserAccount
        userAccountsLock.unlock()
        return last ?? noAccountPlaceholder
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
            // State-machine wiring (3.2.0): the cold path drives the
            // current account's LoadState past `.basicInfoLoaded` via
            // `loadAccountSetsAndAuthDoc → fetchAuthDocumentWithStateMachine`.
            // The warm path historically returned here without firing the
            // auth-doc transition, leaving every `awaitReady()` caller
            // (audiobook open, token refresh, bookmark sync, CarPlay auth)
            // blocked forever on cold-launch for already-signed-in users
            // whose accounts were populated by `preloadAccountsFromDiskCacheSync`.
            // Restore the invariant: any account in `accountSets[hash]`
            // must reach a terminal LoadState. The single-flight guard
            // inside `fetchAuthDocumentWithStateMachine` dedupes against
            // any concurrent invocation from refreshInBackground or a
            // library switch.
            driveCurrentAccountAuthDocIfNeeded()
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
            Log.info(#file, "Loading catalogs from cache (stale-while-revalidate), hash=\(hash), dataSize=\(cachedData.count)")

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

        // 2.5. No disk cache — try the build-time bundled snapshot for
        // immediate library-picker display (PP-4258). The network fetch
        // still runs to pick up anything that changed since the snapshot
        // was cut, so this is purely a fast-path for cold first launch.
        if let bundledData = BundledRegistrySnapshot.load() {
            Log.info(#file, "First launch — loading bundled registry snapshot for hash \(hash), dataSize=\(bundledData.count)")
            // isBundled=true keeps the cache flagged as non-authoritative so
            // every subsequent loadCatalogs call still triggers refresh until
            // a real network response overwrites the metadata.
            cacheAccountsCatalogData(bundledData, hash: hash, isBundled: true)
            loadAccountSetsAndAuthDoc(fromCatalogData: bundledData, key: hash) { _ in
                NotificationCenter.default.post(name: .TPPCatalogDidLoad, object: nil)
            }
            // Fall through to the network fetch — the caller's completion
            // fires when the fresh data arrives, not on the bundled load.
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
            // Cooperative cancellation observation (swarm_4b64e4e0 Fix 2):
            // if `cancelBackgroundWork()` was called while we were awaiting
            // `crawlFirstPage`, drop the result on the floor instead of
            // writing through to `accountSets` / `cacheAccountsCatalogData`.
            // Without this, a test that `_resetForTesting()`s the AppContainer
            // mid-fetch still sees the prior `AccountsManager`'s response
            // land in its caches a few ms later.
            if Task.isCancelled { return }

            switch firstPageResult {
            case .success(let firstPageData, let firstPage):
                // Display first page immediately
                self.cacheAccountsCatalogData(firstPageData, hash: hash)
                self.loadAccountSetsAndAuthDoc(fromCatalogData: firstPageData, key: hash) { success in
                    NotificationCenter.default.post(name: .TPPCatalogDidLoad, object: nil)
                    self.callAndClearLoadingHandlers(for: hash, success)
                }

                // Step 2: Paginate remaining pages in background
                // Use the parsed firstPage (not re-parsed data) to check nextPageURL,
                // because serializeAsCatalogsFeed drops pagination links.
                guard firstPage.nextPageURL != nil else {
                    Log.info(#file, "Single-page registry response (\(firstPage.catalogs.count) libraries) — no pagination needed")
                    self.triggerCatalogPreload()
                    break
                }

                Log.info(#file, "Registry has more pages (first page: \(firstPage.catalogs.count) of \(firstPage.metadata.numberOfItems ?? -1)) — paginating in background")
                Task(priority: .utility) { [weak self] in
                    guard let self = self else { return }

                    let remainingResult = await crawler.crawlRemainingPages(
                        firstPage: firstPage,
                        baseURL: targetUrl,
                        existingPublications: firstPage.catalogs,
                        feedMetadata: firstPage.metadata
                    )

                    if case .success(let fullData) = remainingResult {
                        let fullCount = (try? OPDS2CatalogsFeed.fromData(fullData))?.catalogs.count ?? -1
                        Log.info(#file, "Background pagination complete: \(fullCount) total libraries cached")
                        self.cacheAccountsCatalogData(fullData, hash: hash)
                        self.loadAccountSetsAndAuthDoc(fromCatalogData: fullData, key: hash) { _ in
                            NotificationCenter.default.post(name: .TPPCatalogDidLoad, object: nil)
                        }
                    }
                    self.triggerCatalogPreload()
                }

            case .noChanges:
                self.callAndClearLoadingHandlers(for: hash, true)

            case .failure(let error):
                Log.info(#file, "First page crawl failed: \(error), falling back to direct GET to \(targetUrl)")
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
                let pubCount = (try? OPDS2CatalogsFeed.fromData(data))?.catalogs.count ?? -1
                Log.info(#file, "Background crawl successful for hash \(hash), \(pubCount) libraries in result, dataSize=\(data.count)")
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

    private func cacheAccountsCatalogData(_ data: Data, hash: String, isBundled: Bool = false) {
        // Save catalog data
        guard let url = accountsCatalogUrl(hash: hash) else { return }
        try? data.write(to: url)

        // Save metadata with current timestamp. `isBundled` distinguishes
        // build-time-snapshot writes from authoritative network writes so
        // staleness logic can keep refresh alive on bundled-origin caches.
        let metadata = CatalogCacheMetadata(timestamp: Date(), hash: hash, isBundled: isBundled)
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
            return false
        }
        return !metadata.isExpired
    }

    /// Returns true if cache exists and is stale (needs background refresh)
    private func isCacheStale(hash: String) -> Bool {
        let metadata = readCacheMetadata(hash: hash)
        let serverMaxAge = readCrawlState(hash: hash)?.serverMaxAge
        return Self.isCacheStale(metadata: metadata, serverMaxAge: serverMaxAge)
    }

    /// Pure variant of `isCacheStale(hash:)` that doesn't touch the file
    /// system. Returns `true` when metadata is missing OR when the metadata
    /// reports staleness against `serverMaxAge`. Extracted from the private
    /// version so tests can exercise the nil-metadata → refresh path that
    /// previously had no test coverage (F-013).
    static func isCacheStale(
        metadata: CatalogCacheMetadata?,
        serverMaxAge: TimeInterval?
    ) -> Bool {
        guard let metadata else {
            // No metadata means we should refresh
            return true
        }
        return metadata.isStale(serverMaxAge: serverMaxAge)
    }

    /// Pure helper for `cleanupActiveContentBeforeAccountSwitch`'s
    /// `pathCount > 0` guard — extracted so the bound check is testable.
    static func shouldPopToRoot(navigationPathCount: Int) -> Bool {
        return navigationPathCount > 0
    }

    /// Pure helper for the `currentAccount.didSet` decision of whether to
    /// finish the account-switch synchronously. The previous implementation
    /// had `previousAccountId == newAccountId || previousAccountId == nil`
    /// inline in the setter; extracting it keeps the equality and identity
    /// branches testable and kills the surviving == ↔ != mutants.
    static func shouldFinishSwitchingImmediately(
        previousAccountId: String?,
        newAccountId: String?
    ) -> Bool {
        return previousAccountId == newAccountId || previousAccountId == nil
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

    // MARK: – Auth Document fetch with state-machine wiring

    /// Wraps `Account.loadAuthenticationDocument` with:
    /// 1. Per-UUID single-flight guard — the second concurrent caller for
    ///    the same UUID does NOT fire a duplicate HTTP request; the state
    ///    stream's broadcast (`CurrentValueSubject`) ensures both callers
    ///    observe the same eventual transition.
    /// 2. State-machine transitions — `.detailsLoading` before the fetch;
    ///    `.detailsLoaded(details)` on success; `.detailsFailed(...)` on
    ///    failure. New code that reads `account.details` must go through
    ///    `Account.awaitReady()`, which observes these transitions.
    ///
    /// Exposed `internal` so contract-snapshot tests can drive the wiring
    /// path directly without going through the full `loadCatalogs` cycle.
    internal func fetchAuthDocumentWithStateMachine(
        for account: Account,
        completion: @escaping (Bool) -> Void
    ) {
        inflightAuthDocLock.lock()
        let alreadyInflight = inflightAuthDocFetches.contains(account.uuid)
        if !alreadyInflight {
            inflightAuthDocFetches.insert(account.uuid)
        }
        inflightAuthDocLock.unlock()

        if alreadyInflight {
            // A fetch for this UUID is already in flight. Don't fire a
            // duplicate HTTP request — the state stream's broadcast covers
            // multi-consumer observation. Caller's completion gets `true`
            // so the calling DispatchGroup (if any) balances.
            completion(true)
            return
        }

        account._setState(.detailsLoading)
        account.loadAuthenticationDocument(using: self.currentUserAccount) { [weak self] success in
            guard let self = self else {
                completion(success)
                return
            }
            self.inflightAuthDocLock.lock()
            self.inflightAuthDocFetches.remove(account.uuid)
            self.inflightAuthDocLock.unlock()

            if success, let details = account.details {
                account._setState(.detailsLoaded(details))
            } else {
                account._setState(.detailsFailed(
                    .authDocumentFetchFailed(underlyingDescription: "loadAuthenticationDocument returned false")
                ))
            }
            completion(success)
        }
    }

    /// Fires `fetchAuthDocumentWithStateMachine` for the current account
    /// when its `LoadState` is non-terminal. Used by the `loadCatalogs`
    /// warm-path to close the driver gap on cold-launch with a hot
    /// in-memory accountSets cache — without this, `awaitReady()` callers
    /// (audiobook open, token refresh, bookmark sync, CarPlay auth) hang
    /// indefinitely waiting for `.detailsLoaded`/`.detailsFailed` because
    /// nothing drives the transition. No-op when there is no current
    /// account, or when state has already settled at a terminal value
    /// (existing `awaitReady()` awaiters resolve via that terminal).
    /// Single-flight guard inside `fetchAuthDocumentWithStateMachine`
    /// dedupes against concurrent callers from `refreshInBackground` or
    /// the library-switch path.
    internal func driveCurrentAccountAuthDocIfNeeded() {
        guard let account = currentAccount else { return }
        switch AccountStateStore.shared.state(for: account.uuid) {
        case .detailsLoaded:
            return // terminal — `awaitReady()` awaiters resolve via the loaded details
        case .detailsEvicted(.libraryDeselected):
            // `.detailsEvicted(.libraryDeselected)` is the eviction marker
            // the `currentAccount` setter writes against the PRIOR uuid
            // when the user switches libraries. If this account is back to
            // being the current account, that marker is stale — re-drive
            // the auth-doc fetch so awaitReady() callers (audiobook open,
            // token refresh, bookmark sync, CarPlay auth) don't throw
            // `.evicted` forever after a swap-away/swap-back.
            //
            // PR #1021 (Module A, swarm_51f248d5) split this case off from
            // `.detailsFailed(.accountNotFound)` so the eviction marker
            // stops sharing storage with the genuine HTTP-404 load failure
            // below. Now a real `.accountNotFound` correctly hits the
            // `.detailsFailed` arm and does NOT redrive.
            //
            // FORWARD-COMPAT (added by swarm_18b0d071 wave 3 Module B):
            // This arm matches ONLY `.libraryDeselected` today because
            // that is the only known `AccountEvictionReason`. When a NEW
            // `AccountEvictionReason` case is added in the future, the
            // implementer must decide between two semantics:
            //   (a) "Re-drive on re-entry" — same semantics as
            //       `.libraryDeselected`: the eviction was triggered by a
            //       reversible UX action (library swap, sign-out-on-
            //       current, etc.). Add `case .detailsEvicted(.<newReason>):`
            //       to THIS arm (alongside `.libraryDeselected`) so
            //       awaitReady() callers can resume after re-entry.
            //   (b) "Do NOT re-drive" — the eviction was triggered by an
            //       irreversible state (account deleted server-side,
            //       policy expiry, etc.). Add a NEW
            //       `case .detailsEvicted(.<newReason>):` arm that
            //       `return`s (mirroring the `.detailsFailed` arm below at
            //       line ~983) so awaitReady() correctly surfaces the
            //       failure to consumers instead of looping fetches.
            // The `default` case is deliberately NOT added to this switch
            // — Swift's switch-exhaustiveness check will fail at compile
            // time when a new `AccountEvictionReason` case is added,
            // forcing the future implementer to make the (a)/(b) decision
            // explicit here rather than silently inheriting the wrong
            // behaviour from a default fall-through.
            break
        case .detailsFailed:
            return // genuine load failure — caller must retry explicitly
        case .notLoaded, .basicInfoLoaded, .detailsLoading:
            break
        }
        fetchAuthDocumentWithStateMachine(for: account) { _ in }
    }

    // MARK: – Parsing & notifying

    internal func loadAccountSetsAndAuthDoc(
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

            // Account state-machine wiring (3.2.0): Phase 1 — drive every
            // freshly-constructed account into its post-load terminal state.
            // The `authentication_document` carry-over path above means an
            // account that previously held `.detailsLoaded` continues to
            // observe loaded details (under the new instance). Accounts
            // without a carry-over auth doc fall back to `.basicInfoLoaded`
            // until the current-account fetch below drives them through
            // `.detailsLoading` → `.detailsLoaded` / `.detailsFailed`.
            for newAccount in newAccounts {
                if newAccount.authenticationDocument != nil,
                   let details = newAccount.details {
                    // Belt-and-suspenders `guard let`: `authenticationDocument`
                    // didSet populates `details` synchronously, but a
                    // mock-data publication could in principle land here
                    // with an authDoc that fails to construct details.
                    newAccount._setState(.detailsLoaded(details))
                } else {
                    newAccount._setState(.basicInfoLoaded)
                }
            }

            let group = DispatchGroup()

            let accountExistenceChanged = hadAccount != (self.currentAccount != nil)
            let currentAccountMissingDetails = self.currentAccount != nil && self.currentAccount?.details == nil

            if accountExistenceChanged || currentAccountMissingDetails, let current = self.currentAccount {
                group.enter()
                current.loadLogo()
                fetchAuthDocumentWithStateMachine(for: current) { _ in
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
                // Don't overwrite a valid accountMainFeedURL with nil.
                // On cache loads the current account may not have its catalogUrl
                // populated yet (auth doc hasn't loaded), but the URL from the
                // previous session is still valid in UserDefaults.
                if let mainFeed {
                    self.settings.accountMainFeedURL = mainFeed
                } else if self.settings.accountMainFeedURL == nil {
                    Log.warn(#file, "accountMainFeedURL is nil and no cached value — catalog will not load until auth doc completes")
                }
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

#if DEBUG
extension AccountsManager {
    /// Test-only seam: populate an accountSets bucket without going through
    /// OPDS2 parsing. Routes through `performWrite` so concurrent-access
    /// invariants are preserved. Used by mutation-killing tests for
    /// `account(_ uuid:)` — multi-bucket scenarios are not otherwise
    /// reachable from outside the class.
    func _testSetAccountSet(_ accounts: [Account], forKey key: String) {
        performWrite { self.accountSets[key] = accounts }
    }

    /// Test-only: cancel the in-flight background `loadCatalogs` Task (if any)
    /// and the network executor's non-essential URL session tasks. Cooperative
    /// — returns immediately after issuing the cancel; observation is delegated
    /// to the Task's own `Task.isCancelled` check inside `fetchFromNetwork`.
    /// Idempotent: safe to call repeatedly. Does NOT mutate persistent state;
    /// only cancels in-flight async work.
    ///
    /// Production-safe — guarded by `#if DEBUG` and called only from
    /// `AppContainer._resetForTesting()`. swarm_4b64e4e0 Fix 2 — closes the
    /// H1 finding from swarm_f88ae9e3 A.
    ///
    /// Residual race window (documented intentional): if `loadCatalogs` is
    /// already past the post-await `Task.isCancelled` check inside
    /// `fetchFromNetwork`, the network response still lands in `accountSets`
    /// on the OLD AccountsManager instance — but the OLD instance is no
    /// longer reachable from `AppContainer.production()` post-reset, so the
    /// write is observable only by code paths holding a strong reference to
    /// the prior `accountsManager` (vanishingly few in tests; none in
    /// production). Acceptable per swarm_4b64e4e0 outcome.md.
    func cancelBackgroundWork() {
        backgroundFetchTask?.cancel()
        backgroundFetchTask = nil
        networkExecutor.cancelNonEssentialTasks()
    }

    /// Test-only observation surface for `backgroundFetchTask`. Returns
    /// `true` if the task is currently in a cancelled state OR if the task
    /// handle has been nilled out by `cancelBackgroundWork()`. Used by
    /// `AccountsManagerCancellationTests` to verify the cooperative-cancel
    /// invariant without poking at the private storage directly.
    var _backgroundFetchTaskIsCancelledOrCleared: Bool {
        guard let task = backgroundFetchTask else { return true }
        return task.isCancelled
    }
}
#endif
