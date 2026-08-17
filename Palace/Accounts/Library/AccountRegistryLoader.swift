//
//  AccountRegistryLoader.swift
//  Palace
//
//  god-class decomposition — Wave 3 / 3a-4 (the fourth, largest, in-target
//  collaborator split out of `AccountsManager`).
//
//  The catalog LOAD orchestration: `loadCatalogs`' stale-while-revalidate pipeline,
//  the first-page-then-paginate network crawl + its direct-GET fallbacks, the CP-D1
//  launch preload + slim-snapshot hydration, the owned background-crawl task registry
//  + its test-boundary drain choreography, and the per-catalog loading-completion
//  handler dedupe. It ORCHESTRATES the already-extracted collaborators — the disk
//  cache (`AccountRegistryCaching`, 3a-1), the registry state store
//  (`AccountRegistryStore`, 3a-2), and the auth-doc state machine (`AuthDocumentLoader`,
//  3a-3, reached through the injected drive/fetch closures) — so the hub carries none
//  of the load pipeline.
//
//  A `final class @unchecked Sendable` (NOT an actor): `loadCatalogs` and the drain are
//  called synchronously from init / the currentAccount setter / the test-boundary reset
//  (which cannot `await`), and the drain depends on a synchronous `registryStore` barrier
//  read blocking — same class-not-actor rationale as `AccountRegistryStore` /
//  `AuthDocumentLoader`.
//
//  `@unchecked Sendable` invariant: `loadingCompletionHandlers` is read via
//  `loadingHandlersQueue.sync` / written via `.async(flags:.barrier)`; `ownedCrawlTasks`
//  is an internally-synchronized `OwnedCrawlTaskRegistry`; `_trackedFirstRunTasks` is
//  guarded by `_trackedCrawlTasksLock`; `_fetchFromNetworkCount` by its own lock;
//  `crawlScheduler`/`catalogPreloader`/the injected values are immutable; the DEBUG-only
//  `backgroundFetchTask` handle is driven only from the test-boundary seams. Every
//  background crawl `Task { [weak self] … }` captures the loader, whose mutable state is
//  all so-synchronized.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import PalacePreferences
import PalaceLogging
import PalaceCatalog
import PalaceBookRegistry
import PalaceBookModel
import UIKit

/// Documented carrier for a non-Sendable `(Bool) -> Void` load-completion handler
/// stored into the `loadingHandlersQueue` barrier in `addLoadingHandler` (and reused
/// for the `group.notify` completion box in `loadAccountSetsAndAuthDoc`). `@unchecked
/// Sendable` invariant: the wrapped closure is only appended to / read from
/// `loadingCompletionHandlers[hash]` under the serial `.barrier` of the concurrent
/// `loadingHandlersQueue`, and invoked later on the caller's queue — never concurrently
/// with its own storage mutation. Thread-affinity is the caller's contract (unchanged).
private struct LoadCompletionBox: @unchecked Sendable {
    let handler: (Bool) -> Void
}

/// Documented carrier for the non-Sendable `LibraryRegistryCrawler` handed from the
/// first-page crawl Task into its nested background pagination Task in `fetchFromNetwork`.
/// `@unchecked Sendable` invariant: the crawler is used strictly sequentially — the outer
/// Task finishes `crawlFirstPage` BEFORE the pagination Task is spawned, and only the
/// pagination Task touches it thereafter, so the two never touch it concurrently.
private struct CrawlerHandoffBox: @unchecked Sendable {
    let crawler: LibraryRegistryCrawler
}

/// Catalog load orchestration + owned background-crawl + drain. See the file header for
/// the class-not-actor and `@unchecked Sendable` rationale. Injected into `AccountsManager`
/// as a `lazy var`; tests construct it directly with spy providers.
final class AccountRegistryLoader: @unchecked Sendable {

    // MARK: - Injected collaborators (values)

    private let registryCache: any AccountRegistryCaching
    private let registryStore: AccountRegistryStore
    private let crawlScheduler: CrawlTaskScheduler
    private let settings: TPPSettings
    private let imageCache: ImageCacheType
    private let accountStateStore: AccountStateStore
    private let ageCheck: TPPAgeCheckVerifying

    private let catalogPreloader = CatalogPreloader()

    // MARK: - Injected provider closures (the self-referential drive surface — 9)

    private let networkExecutorProvider: () -> any AccountNetworking
    private let currentAccountProvider: () -> Account?
    private let currentAccountIdProvider: () -> String?
    private let accountsForKeyProvider: (String) -> [Account]
    private let accountProvider: (String) -> Account?
    private let currentUserAccountProvider: () -> TPPUserAccount?
    private let driveCurrentAccountAuthDoc: () -> Void
    private let fetchAuthDocumentWithStateMachineImpl: (Account, @escaping (Bool) -> Void) -> Void
    /// COPPA age-check needs the owning manager as a `TPPCurrentLibraryAccountProvider`
    /// (the loader is not that type — architect finding 3).
    private let currentLibraryAccountProvider: () -> TPPCurrentLibraryAccountProvider?

    /// Resolves the build-time bundled registry snapshot resource. Production binds
    /// `Bundle.main`; tests inject a stub to observe the first-launch bundled decode's
    /// thread + invocation count without a `#if DEBUG` seam.
    var snapshotResourceResolver: BundleResourceResolving = Bundle.main

    // MARK: - Owned load state

    // Per-catalog in-flight tracking:
    private var loadingCompletionHandlers = [String: [(Bool) -> Void]]()
    private let loadingHandlersQueue = DispatchQueue(label: "com.tpp.loadingHandlers", attributes: .concurrent)

    /// Owns every background catalog-crawl Task (PP-4754) so the reset choreography can
    /// cancel + await them. Self-pruning + internally synchronized.
    private let ownedCrawlTasks = OwnedCrawlTaskRegistry()

    /// Loader-local copy of the XCTest env gate (the hub's `_isRunningUnderXCTest`).
    private static let _isRunningUnderXCTest =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    /// Guards `_trackedFirstRunTasks`.
    private let _trackedCrawlTasksLock = NSLock()
    /// Subset of owned tasks that are `loadCatalogs` FIRST-RUN tasks (populated only
    /// under XCTest). The narrow join seam awaits only these; the broad one awaits all.
    private var _trackedFirstRunTasks: [Task<Void, Never>] = []

    /// Test-observability: count of `fetchFromNetwork` entries (bumped only under XCTest).
    private let _fetchFromNetworkCountLock = NSLock()
    private var _fetchFromNetworkCount = 0
    var fetchFromNetworkCountForTesting: Int {
        _fetchFromNetworkCountLock.lock()
        defer { _fetchFromNetworkCountLock.unlock() }
        return _fetchFromNetworkCount
    }

    #if DEBUG
    /// Test-only handle to the post-init background `loadCatalogs` task (see the hub's
    /// cancel/inject seams). Only non-nil under DEBUG.
    var backgroundFetchTask: Task<Void, Never>?
    #endif

    init(
        registryCache: any AccountRegistryCaching,
        registryStore: AccountRegistryStore,
        crawlScheduler: CrawlTaskScheduler,
        settings: TPPSettings,
        imageCache: ImageCacheType,
        accountStateStore: AccountStateStore,
        ageCheck: TPPAgeCheckVerifying,
        networkExecutorProvider: @escaping () -> any AccountNetworking,
        currentAccountProvider: @escaping () -> Account?,
        currentAccountIdProvider: @escaping () -> String?,
        accountsForKeyProvider: @escaping (String) -> [Account],
        accountProvider: @escaping (String) -> Account?,
        currentUserAccountProvider: @escaping () -> TPPUserAccount?,
        driveCurrentAccountAuthDoc: @escaping () -> Void,
        fetchAuthDocumentWithStateMachine: @escaping (Account, @escaping (Bool) -> Void) -> Void,
        currentLibraryAccountProvider: @escaping () -> TPPCurrentLibraryAccountProvider?
    ) {
        self.registryCache = registryCache
        self.registryStore = registryStore
        self.crawlScheduler = crawlScheduler
        self.settings = settings
        self.imageCache = imageCache
        self.accountStateStore = accountStateStore
        self.ageCheck = ageCheck
        self.networkExecutorProvider = networkExecutorProvider
        self.currentAccountProvider = currentAccountProvider
        self.currentAccountIdProvider = currentAccountIdProvider
        self.accountsForKeyProvider = accountsForKeyProvider
        self.accountProvider = accountProvider
        self.currentUserAccountProvider = currentUserAccountProvider
        self.driveCurrentAccountAuthDoc = driveCurrentAccountAuthDoc
        self.fetchAuthDocumentWithStateMachineImpl = fetchAuthDocumentWithStateMachine
        self.currentLibraryAccountProvider = currentLibraryAccountProvider
    }

    // MARK: - Owned-task spawning + join seams

    /// Spawn a background crawl `Task` through `crawlScheduler` and register it in
    /// `ownedCrawlTasks` so the reset choreography can cancel + await it. A `defer`
    /// self-prunes the token as the task unwinds, bounding the live set.
    @discardableResult
    func spawnOwnedCrawlTask(
        priority: TaskPriority,
        detached: Bool,
        firstRun: Bool = false,
        _ operation: @escaping @Sendable () async -> Void
    ) -> Task<Void, Never> {
        let token = UUID()
        let registry = ownedCrawlTasks
        let owned: @Sendable () async -> Void = {
            defer { registry.complete(token) }
            await operation()
        }
        let task = detached
            ? crawlScheduler.spawnDetached(priority, owned)
            : crawlScheduler.spawn(priority, owned)
        ownedCrawlTasks.register(token, task)
        if firstRun { _trackFirstRunTask(task) }
        return task
    }

    /// Record a `loadCatalogs` FIRST-RUN task in the narrow-join subset. No-op outside XCTest.
    private func _trackFirstRunTask(_ task: Task<Void, Never>) {
        guard Self._isRunningUnderXCTest else { return }
        _trackedCrawlTasksLock.lock()
        _trackedFirstRunTasks.append(task)
        _trackedCrawlTasksLock.unlock()
    }

    /// Test-only whole-quiescence JOIN seam (PP-4754). Grows-until-stable; NO wall-clock.
    func _awaitCatalogLoadForTesting(maxRounds: Int = 8) async {
        guard Self._isRunningUnderXCTest else { return }
        var awaited = Set<UUID>()
        for _ in 0..<maxRounds {
            let fresh = ownedCrawlTasks.snapshot().filter { !awaited.contains($0.0) }
            if fresh.isEmpty { return }
            for (token, task) in fresh {
                _ = await task.value
                awaited.insert(token)
            }
        }
    }

    /// Test-only quiescence assertion helper: number of live owned crawl tasks.
    var _ownedCrawlTaskCountForTesting: Int { ownedCrawlTasks.count }

    /// Snapshot-then-await-without-a-lock (Swift 6 bans `NSLock.lock()` across an await).
    private func _snapshotFirstRunTasksForTesting() -> [Task<Void, Never>] {
        _trackedCrawlTasksLock.lock()
        defer { _trackedCrawlTasksLock.unlock() }
        return _trackedFirstRunTasks
    }

    /// Test-only NARROW deterministic JOIN seam. Awaits every tracked FIRST-RUN task.
    func _awaitAllCrawlTasksForTesting() async {
        for task in _snapshotFirstRunTasksForTesting() {
            _ = await task.value
        }
    }

    // MARK: - Preload + CP-D1 slim hydration

    /// Hydrate the registry from the on-disk OPDS2 catalog cache without dispatching to a
    /// background queue. Safe from `init()` (local I/O, single-digit ms). CP-D1.
    func preloadAccountsFromDiskCacheSync() {
        let hash = registryStore.currentHash
        // Fast path (CP-D1 LaunchHydration): when a slim snapshot exists, decode ONLY the
        // current + settings accounts synchronously so `currentAccount` resolves and its
        // auth-doc drive fires within a few ms of launch. The full decode+map moves OFF
        // the launch main thread — it materializes via the background `loadCatalogs` that
        // `init()` dispatches immediately after. Consumers block on the EXISTING
        // `Account.awaitReady()` gate, which survives the slim→full instance swap.
        //
        // Gated on `registryCache.hasFreshCatalogData`: the slim snapshot carries no
        // separate metadata, so a truly-expired cache still falls through to the no-op.
        if registryCache.hasFreshCatalogData(hash: hash), hydrateSlimLaunchSnapshot(hash: hash) {
            refreshSlimLaunchSnapshotOffMain(hash: hash)
            return
        }
        // Slow path: no slim snapshot yet. Hydrate the full set synchronously exactly as
        // before, then seed a slim snapshot off-main so the NEXT launch takes the fast path.
        guard registryCache.hasFreshCatalogData(hash: hash),
              let cachedData = registryCache.readCatalogData(hash: hash) else {
            return
        }
        hydrateFullAccountSets(fromCatalogData: cachedData, hash: hash)
        refreshSlimLaunchSnapshotOffMain(hash: hash)
    }

    /// Decode the small slim snapshot, hydrate the current + settings accounts, drive them
    /// to `.basicInfoLoaded` (only if still `.notLoaded`), and fire the current account's
    /// auth-doc drive. Returns false to fall through to the full sync path. CP-D1.
    private func hydrateSlimLaunchSnapshot(hash: String) -> Bool {
        guard let url = registryCache.slimSnapshotURL(hash: hash),
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            return false
        }
        do {
            let feed = try OPDS2CatalogsFeed.fromData(data)
            let accounts = feed.catalogs.map {
                Account(publication: $0, imageCache: imageCache)
            }
            guard !accounts.isEmpty else { return false }
            // CP-D1 (Finding 5): a stale slim file can LACK the now-current account
            // (currentAccountId ≠ slim set after a mid-session switch). If the current
            // account is absent, fall through to the full sync hydrate rather than take
            // the fast path with a slim set that can't resolve `currentAccount` —
            // otherwise a transient nil-currentAccount launch window (spurious sign-in
            // modals / empty library UI) that did not exist pre-D1.
            if let currentId = currentAccountIdProvider(),
               !accounts.contains(where: { $0.uuid == currentId }) {
                return false
            }
            registryStore.storeSlim(accounts)
            for account in accounts {
                if case .notLoaded = accountStateStore.state(for: account.uuid) {
                    account._setState(.basicInfoLoaded)
                }
            }
            // Drive the current account's auth-doc so `awaitReady()` consumers resolve
            // without waiting on the full off-main materialization. `currentAccount`
            // resolves via `account(_:)`'s slim fallback.
            //
            // DEFERRED off this synchronous stack (was a direct call). On cold launch the
            // manager is constructed INSIDE `_buildCachedAppContainer()` under
            // `_cachedLock.withLock`; the drive transitively re-enters the composition root
            // (auth-doc → network executor), and re-entering the non-recursive lock on the
            // same thread traps — it crashed launch for every signed-in user. Hopping to the
            // next main-runloop turn lets the container finish building + release the lock
            // first. The drive is an async fire-and-forget fetch, so a one-turn defer is
            // behaviorally inert for `awaitReady()` consumers (all run well after launch).
            DispatchQueue.main.async { [weak self] in
                self?.driveCurrentAccountAuthDoc()
            }
            Log.info(#file, "CP-D1: slim launch snapshot hydrated \(accounts.count) accounts (hash=\(hash))")
            return true
        } catch {
            Log.warn(#file, "CP-D1: slim launch snapshot decode failed: \(error). Falling back to full sync hydrate.")
            return false
        }
    }

    /// The original synchronous full-hydrate path. Only advances still-`.notLoaded` uuids.
    private func hydrateFullAccountSets(fromCatalogData cachedData: Data, hash: String) {
        do {
            let feed = try OPDS2CatalogsFeed.fromData(cachedData)
            let accounts = feed.catalogs.map {
                Account(publication: $0, imageCache: imageCache)
            }
            registryStore.mutate { $0[hash] = accounts }
            for account in accounts {
                if case .notLoaded = accountStateStore.state(for: account.uuid) {
                    account._setState(.basicInfoLoaded)
                }
            }
            Log.info(#file, "Pre-loaded \(accounts.count) accounts from disk cache (sync, hash=\(hash))")
        } catch {
            Log.warn(#file, "Sync disk-cache pre-load failed: \(error). Will refresh from network async.")
        }
    }

    /// Rebuild the slim launch snapshot from the full on-disk cache, OFF the main thread.
    /// XCTest-gated (a detached best-effort write outlives the test and pollutes siblings).
    func refreshSlimLaunchSnapshotOffMain(hash: String) {
        guard !Self._isRunningUnderXCTest else { return }
        spawnOwnedCrawlTask(priority: .utility, detached: true) { [weak self] in
            guard let self, !Task.isCancelled else { return }
            guard let data = self.registryCache.readCatalogData(hash: hash) else { return }
            guard !Task.isCancelled else { return }
            self.writeSlimSnapshot(fromFullCatalogData: data, hash: hash)
        }
    }

    /// Carve the current + settings accounts out of the full blob and persist them as a
    /// small OPDS2 feed. Runs on a background queue. CP-D1.
    private func writeSlimSnapshot(fromFullCatalogData data: Data, hash: String) {
        let keepUUIDs = slimSnapshotUUIDs()
        guard !keepUUIDs.isEmpty, let url = registryCache.slimSnapshotURL(hash: hash) else { return }
        guard let carved = Self.carveSlimFeed(fromFullCatalogData: data, keepUUIDs: keepUUIDs) else {
            Log.warn(#file, "CP-D1: slim snapshot carve produced no data (hash=\(hash))")
            return
        }
        do {
            try carved.write(to: url)
            Log.info(#file, "CP-D1: slim launch snapshot written (\(keepUUIDs.count) uuids, \(carved.count) bytes, hash=\(hash))")
        } catch {
            Log.warn(#file, "CP-D1: slim snapshot write failed: \(error)")
        }
    }

    /// The uuids the slim launch snapshot must carry: the current account plus
    /// `settingsAccountIdsList`. CP-D1.
    private func slimSnapshotUUIDs() -> Set<String> {
        var uuids = Set<String>()
        if let current = currentAccountIdProvider() {
            uuids.insert(current)
        }
        for uuid in settings.settingsAccountIdsList {
            uuids.insert(uuid)
        }
        return uuids
    }

    /// Pure raw-JSON carve: keep only the `catalogs` entries whose `metadata.id` is in
    /// `keepUUIDs`, re-serialize the otherwise-unchanged root (preserves the exact
    /// date-string format the reader expects). Static + pure. CP-D1.
    static func carveSlimFeed(fromFullCatalogData data: Data, keepUUIDs: Set<String>) -> Data? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let catalogs = root["catalogs"] as? [[String: Any]] else {
            return nil
        }
        let kept = catalogs.filter { entry in
            guard let metadata = entry["metadata"] as? [String: Any],
                  let id = metadata["id"] as? String else { return false }
            return keepUUIDs.contains(id)
        }
        guard !kept.isEmpty else { return nil }
        var slimRoot = root
        slimRoot["catalogs"] = kept
        return try? JSONSerialization.data(withJSONObject: slimRoot)
    }

    // MARK: - Loading-completion handler dedupe

    /// Adds a completion handler for the given catalog hash, returns true if a load is
    /// already underway.
    private func addLoadingHandler(for hash: String, _ handler: ((Bool) -> Void)?) -> Bool {
        var alreadyLoading = false
        loadingHandlersQueue.sync {
            alreadyLoading = loadingCompletionHandlers[hash] != nil
        }

        guard !alreadyLoading else {
            if let h = handler {
                let box = LoadCompletionBox(handler: h)
                loadingHandlersQueue.async(flags: .barrier) { [weak self] in
                    self?.loadingCompletionHandlers[hash]?.append(box.handler)
                }
            }
            return true
        }

        let box = handler.map { LoadCompletionBox(handler: $0) }
        loadingHandlersQueue.async(flags: .barrier) {
            self.loadingCompletionHandlers[hash] = box.map { [$0.handler] } ?? []
        }
        return false
    }

    /// Calls & clears all handlers for the given hash.
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

    // MARK: - Load orchestration

    /// Spawn the post-init background `loadCatalogs` crawl (owned + drainable), storing
    /// the handle for the DEBUG cancel/inject seams. Called from `AccountsManager.init`.
    func spawnInitialBackgroundLoad() {
        let task = spawnOwnedCrawlTask(priority: .utility, detached: true) { [weak self] in
            self?.loadCatalogs(completion: nil)
        }
        #if DEBUG
        backgroundFetchTask = task
        #else
        _ = task
        #endif
    }

    /// Public entrypoint — stale-while-revalidate: memory hit → immediate (refresh if
    /// stale); disk hit → immediate + background refresh; miss → bundled fast-path + network.
    func loadCatalogs(completion: ((Bool) -> Void)?) {
        let targetUrl = TPPConfiguration.customUrl()
            ?? (settings.useBetaLibraries
                    ? TPPConfiguration.betaUrl
                    : TPPConfiguration.prodUrl)
        let hash = targetUrl.absoluteString
            .md5()
            .base64EncodedStringUrlSafe()
            .trimmingCharacters(in: ["="])

        // 1. Already loaded in memory → return immediately (still drive the current
        // account's auth-doc so `awaitReady()` callers resolve on cold-launch warm path).
        if registryStore.bucketIsNonEmpty(hash: hash) {
            driveCurrentAccountAuthDoc()
            completion?(true)
            if registryCache.isCatalogStale(hash: hash) {
                refreshInBackground(targetUrl: targetUrl, hash: hash)
            }
            return
        }

        // 2. Disk cache (stale-while-revalidate).
        if registryCache.hasFreshCatalogData(hash: hash),
           let cachedData = registryCache.readCatalogData(hash: hash) {
            Log.info(#file, "Loading catalogs from cache (stale-while-revalidate), hash=\(hash), dataSize=\(cachedData.count)")

            if addLoadingHandler(for: hash, completion) { return }

            loadAccountSetsAndAuthDoc(fromCatalogData: cachedData, key: hash) { [weak self] success in
                NotificationCenter.default.post(name: .TPPCatalogDidLoad, object: nil)
                self?.callAndClearLoadingHandlers(for: hash, success)
            }

            refreshInBackground(targetUrl: targetUrl, hash: hash)
            return
        }

        // 2.5 + 3. No disk cache: build-time bundled snapshot fast-path THEN the network
        // fetch that supersedes it. SINGLE dedupe guard above the bundled branch (a
        // concurrent second caller short-circuits HERE, before the ~2.4 MB bundled decode)
        // and deliberately NOT re-checked before `fetchFromNetwork`.
        if addLoadingHandler(for: hash, completion) { return }

        // Hop the bundled decode + network kickoff OFF the calling thread (cold first
        // launch reaches here from @MainActor). `.utility` matches the init crawl arms;
        // tracked so `cancelBackgroundWork()` cancels it.
        spawnOwnedCrawlTask(priority: .utility, detached: true, firstRun: true) { [weak self] in
            guard let self = self else { return }

            if let bundledData = BundledRegistrySnapshot.load(resolver: self.snapshotResourceResolver),
               !Task.isCancelled {
                Log.info(#file, "First launch — loading bundled registry snapshot for hash \(hash), dataSize=\(bundledData.count)")
                self.registryCache.writeCatalogData(bundledData, hash: hash, isBundled: true)
                self.loadAccountSetsAndAuthDoc(fromCatalogData: bundledData, key: hash) { _ in
                    NotificationCenter.default.post(name: .TPPCatalogDidLoad, object: nil)
                }
            }

            if Task.isCancelled { return }
            Log.debug(#file, "Loading catalogs from network for hash \(hash)…")
            self.fetchFromNetwork(targetUrl: targetUrl, hash: hash)
        }
    }

    /// First-page fast path: fetch first page → display; paginate remaining in background.
    /// Falls back to a direct GET if even the first page fails.
    private func fetchFromNetwork(targetUrl: URL, hash: String) {
        if Self._isRunningUnderXCTest {
            _fetchFromNetworkCountLock.lock()
            _fetchFromNetworkCount += 1
            _fetchFromNetworkCountLock.unlock()
        }

        if TPPConfiguration.customRegistryIsExplicitURL() {
            fallbackFetchFromNetwork(targetUrl: targetUrl, hash: hash)
            return
        }
        spawnOwnedCrawlTask(priority: .userInitiated, detached: false) { [weak self] in
            guard let self = self else { return }
            Log.debug(#file, "Fetching catalogs via first-page fast path for hash \(hash)")

            let crawler = LibraryRegistryCrawler(fetcher: URLSessionCrawlerFetcher(), hash: hash)

            let firstPageResult = await crawler.crawlFirstPage(baseURL: targetUrl)
            if Task.isCancelled { return }

            switch firstPageResult {
            case .success(let firstPageData, let firstPage):
                self.registryCache.writeCatalogData(firstPageData, hash: hash)
                self.loadAccountSetsAndAuthDoc(fromCatalogData: firstPageData, key: hash) { success in
                    NotificationCenter.default.post(name: .TPPCatalogDidLoad, object: nil)
                    self.callAndClearLoadingHandlers(for: hash, success)
                }

                guard firstPage.nextPageURL != nil else {
                    Log.info(#file, "Single-page registry response (\(firstPage.catalogs.count) libraries) — no pagination needed")
                    self.triggerCatalogPreload()
                    break
                }

                Log.info(#file, "Registry has more pages (first page: \(firstPage.catalogs.count) of \(firstPage.metadata.numberOfItems ?? -1)) — paginating in background")
                let crawlerBox = CrawlerHandoffBox(crawler: crawler)
                self.spawnOwnedCrawlTask(priority: .utility, detached: false) { [weak self] in
                    guard let self = self else { return }

                    let remainingResult = await crawlerBox.crawler.crawlRemainingPages(
                        firstPage: firstPage,
                        baseURL: targetUrl,
                        existingPublications: firstPage.catalogs,
                        feedMetadata: firstPage.metadata
                    )

                    if case .success(let fullData) = remainingResult {
                        let fullCount = (try? OPDS2CatalogsFeed.fromData(fullData))?.catalogs.count ?? -1
                        Log.info(#file, "Background pagination complete: \(fullCount) total libraries cached")
                        self.registryCache.writeCatalogData(fullData, hash: hash)
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

    /// Fallback direct GET when the crawler fails on first launch (owned + drainable).
    private func fallbackFetchFromNetwork(targetUrl: URL, hash: String) {
        spawnOwnedCrawlTask(priority: .utility, detached: true) { [weak self] in
            guard let self = self else { return }
            do {
                let (data, _) = try await self.networkExecutorProvider().GET(targetUrl, useTokenIfAvailable: false)
                if Task.isCancelled { return }
                self.registryCache.writeCatalogData(data, hash: hash)
                self.loadAccountSetsAndAuthDoc(fromCatalogData: data, key: hash) { success in
                    NotificationCenter.default.post(name: .TPPCatalogDidLoad, object: nil)
                    self.callAndClearLoadingHandlers(for: hash, success)
                }
            } catch {
                if Task.isCancelled { return }
                Log.error(#file, "Failed to load catalogs from network: \(error.localizedDescription)")
                if let data = self.registryCache.readCatalogData(hash: hash) {
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

    /// Background refresh via the incremental crawler; direct-GET fallback.
    private func refreshInBackground(targetUrl: URL, hash: String) {
        if TPPConfiguration.customRegistryIsExplicitURL() {
            fallbackFetchFromNetwork(targetUrl: targetUrl, hash: hash)
            return
        }
        spawnOwnedCrawlTask(priority: .utility, detached: false) { [weak self] in
            guard let self = self else { return }
            Log.debug(#file, "Starting background refresh (crawl) for catalog hash \(hash)")

            let existingPubs: [OPDS2Publication]
            let existingMetadata: OPDS2CatalogsFeed.Metadata?
            if let cachedData = self.registryCache.readCatalogData(hash: hash),
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
                self.registryCache.writeCatalogData(data, hash: hash)
                self.loadAccountSetsAndAuthDoc(fromCatalogData: data, key: hash) { [weak self] _ in
                    NotificationCenter.default.post(name: .TPPCatalogDidLoad, object: nil)
                    self?.triggerCatalogPreload()
                }

            case .noChanges:
                Log.debug(#file, "Background crawl found no changes for hash \(hash)")
                self.triggerCatalogPreload()

            case .failure(let error):
                Log.debug(#file, "Background crawl failed for hash \(hash): \(error.localizedDescription)")
                self.fallbackDirectRefresh(targetUrl: targetUrl, hash: hash)
            }
        }
    }

    /// Fallback direct GET when the crawlable refresh endpoint fails (owned + drainable).
    private func fallbackDirectRefresh(targetUrl: URL, hash: String) {
        spawnOwnedCrawlTask(priority: .utility, detached: true) { [weak self] in
            guard let self = self else { return }
            do {
                let (data, _) = try await self.networkExecutorProvider().GET(targetUrl, useTokenIfAvailable: false)
                if Task.isCancelled { return }
                Log.info(#file, "Fallback direct refresh successful for hash \(hash)")
                self.registryCache.writeCatalogData(data, hash: hash)
                self.loadAccountSetsAndAuthDoc(fromCatalogData: data, key: hash) { _ in
                    NotificationCenter.default.post(name: .TPPCatalogDidLoad, object: nil)
                }
            } catch {
                Log.debug(#file, "Fallback direct refresh also failed for hash \(hash): \(error.localizedDescription)")
            }
        }
    }

    /// Triggers catalog feed preloading for active accounts.
    private func triggerCatalogPreload() {
        spawnOwnedCrawlTask(priority: .utility, detached: false) { [weak self] in
            guard let self = self else { return }
            await self.catalogPreloader.preloadCatalogs(
                currentAccount: self.currentAccountProvider(),
                recentAccountUUIDs: self.settings.settingsAccountIdsList,
                accountProvider: { self.accountProvider($0) }
            )
        }
    }

    // MARK: - Parsing & notifying

    func loadAccountSetsAndAuthDoc(
        fromCatalogData data: Data,
        key hash: String,
        completion: @escaping (Bool) -> Void
    ) {
        let completionBox = LoadCompletionBox(handler: completion)
        do {
            let feed = try OPDS2CatalogsFeed.fromData(data)
            let hadAccount = currentAccountProvider() != nil
            let oldAccounts = accountsForKeyProvider(hash)
            let oldAccountsByUUID = Dictionary(
                oldAccounts.map { ($0.uuid, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let newAccounts = feed.catalogs.map { publication -> Account in
                // CP-D1 (Finding 4): on the slim→full LAUNCH materialization REUSE the
                // existing slim instance so an in-flight slim auth-doc fetch lands on the
                // current instance (one Account per uuid). Bounded to launch: once
                // populated (warm / network-refresh), the carry-over loop wins.
                if oldAccountsByUUID[publication.metadata.id] == nil,
                   let slim = registryStore.slimAccount(publication.metadata.id) {
                    return slim
                }
                return Account(publication: publication, imageCache: imageCache)
            }

            for newAccount in newAccounts {
                if let old = oldAccountsByUUID[newAccount.uuid] {
                    if let authDoc = old.authenticationDocument {
                        newAccount.authenticationDocument = authDoc
                    }
                    if old.logoUrl != newAccount.logoUrl {
                        imageCache.remove(for: newAccount.uuid)
                    }
                }
            }

            registryStore.mutate { $0[hash] = newAccounts }

            for newAccount in newAccounts {
                if newAccount.authenticationDocument != nil,
                   let details = newAccount.details {
                    newAccount._setState(.detailsLoaded(details))
                } else if case .notLoaded = accountStateStore.state(for: newAccount.uuid) {
                    newAccount._setState(.basicInfoLoaded)
                }
            }

            let group = DispatchGroup()

            let accountExistenceChanged = hadAccount != (currentAccountProvider() != nil)
            let currentAccountMissingDetails = currentAccountProvider() != nil && currentAccountProvider()?.details == nil

            if accountExistenceChanged || currentAccountMissingDetails, let current = currentAccountProvider() {
                group.enter()
                current.loadLogo()
                fetchAuthDocumentWithStateMachineImpl(current) { [self] _ in
                    if current.details?.needsAgeCheck ?? false,
                       let libraryProvider = currentLibraryAccountProvider(),
                       let userAccount = currentUserAccountProvider() {
                        group.enter()
                        ageCheck.verifyCurrentAccountAgeRequirement(
                            userAccountProvider: userAccount,
                            currentLibraryAccountProvider: libraryProvider
                        ) { _ in group.leave() }
                    }
                    group.leave()
                }
            }

            group.notify(queue: .main) { [self] in
                var mainFeed = URL(string: currentAccountProvider()?.catalogUrl ?? "")
                if let cur = currentAccountProvider(), cur.details?.needsAgeCheck ?? false {
                    mainFeed = cur.details?.defaultAuth?.coppaURL(isOfAge: true)
                }
                if let mainFeed {
                    settings.accountMainFeedURL = mainFeed
                } else if settings.accountMainFeedURL == nil {
                    Log.warn(#file, "accountMainFeedURL is nil and no cached value — catalog will not load until auth doc completes")
                }
                MainActor.assumeIsolated {
                    UIApplication.shared.delegate?.window??.tintColor = TPPConfiguration.mainColor()
                }
                NotificationCenter.default.post(name: .TPPCurrentAccountDidChange, object: nil)
                completionBox.handler(true)
            }

        } catch {
            TPPErrorLogger.logError(error, summary: "Error parsing catalog feed")
            completion(false)
        }
    }

    // MARK: - Test-boundary drain (DEBUG)

    #if DEBUG
    /// Cancel the in-flight background `loadCatalogs` Task + owned crawl tasks + the
    /// network executor's non-essential tasks. Cooperative — returns immediately.
    ///
    /// NOTE (Wave 3 / 3a-4): the `_explicitCancelCalled` flag stays on `AccountsManager`
    /// (the `AuthDocumentLoader.isTornDown` binding reads it) and is set by the HUB facade
    /// BEFORE this delegates — this body must NOT set it (it can't reach the hub flag) and
    /// must NOT call a flag-setting cancel, or the torn-down semantics never engage and a
    /// leaked auth-doc main-hop pollutes the next test.
    func cancelBackgroundWork() {
        backgroundFetchTask?.cancel()
        backgroundFetchTask = nil
        ownedCrawlTasks.cancelAll()
        _trackedCrawlTasksLock.lock()
        _trackedFirstRunTasks.removeAll()
        _trackedCrawlTasksLock.unlock()
        networkExecutorProvider().cancelNonEssentialTasks()
    }

    /// Cancel the in-flight crawl AND synchronously DRAIN it (pumping the run loop) before
    /// returning, so no orphan crawl outlives the test boundary holding the store barrier.
    func cancelAndDrainBackgroundWork(timeout: TimeInterval = 3.0) {
        let ownedTasks = ownedCrawlTasks.snapshot().map { $0.1 }
        let fetchTask = backgroundFetchTask
        let tasksToDrain = ownedTasks + [fetchTask].compactMap { $0 }

        cancelBackgroundWork() // requests cancellation, nils the handle (does NOT set the hub flag)

        if tasksToDrain.isEmpty {
            // No tracked Tasks, but init may have enqueued a DispatchQueue.main.async
            // auth-doc drive (see `hydrateSlimLaunchSnapshot`'s deferred hop) that is NOT
            // a Task and CANNOT be cancelled. Pump the main run loop briefly so any pending
            // hop fires NOW, inside the boundary — never BLOCK main (the crawl-drain
            // deadlock reason applies). Enqueue a sentinel AFTER any pending hop (FIFO) and
            // spin until it drains, bounded by 50ms.
            let sentinel = DispatchGroup()
            sentinel.enter()
            DispatchQueue.main.async { sentinel.leave() }
            let pumpDeadline = Date().addingTimeInterval(0.05)
            while sentinel.wait(timeout: .now()) == .timedOut && Date() < pumpDeadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
            return
        }

        let started = Date()
        let group = DispatchGroup()
        for task in tasksToDrain {
            group.enter()
            Task { _ = await task.value; group.leave() }
        }
        let deadline = started.addingTimeInterval(timeout)
        while group.wait(timeout: .now()) == .timedOut && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
        if group.wait(timeout: .now()) == .timedOut {
            NSLog("[WS0-DRAIN] cancelAndDrainBackgroundWork TIMED OUT after %dms draining %d task(s) — crawl did not observe cancellation; investigate.", elapsedMs, tasksToDrain.count)
        } else if elapsedMs >= 50 {
            NSLog("[WS0-DRAIN] cancelAndDrainBackgroundWork drained %d task(s) in %dms.", tasksToDrain.count, elapsedMs)
        }
    }

    /// Test-only setter that swaps a caller-provided Task into `backgroundFetchTask`.
    @discardableResult
    func _injectBackgroundFetchTaskForTesting(_ task: Task<Void, Never>?) -> Task<Void, Never>? {
        let prior = backgroundFetchTask
        backgroundFetchTask = task
        return prior
    }

    /// Test-only: `true` iff `backgroundFetchTask` is currently nil.
    var _backgroundFetchTaskHandleIsNil: Bool {
        return backgroundFetchTask == nil
    }

    /// Test-only: `true` if the task is cancelled OR the handle was nilled.
    var _backgroundFetchTaskIsCancelledOrCleared: Bool {
        guard let task = backgroundFetchTask else { return true }
        return task.isCancelled
    }
    #endif
}
