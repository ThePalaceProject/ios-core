import Foundation
import os
import PalaceLogging
#if canImport(UIKit)
import UIKit
#endif

public protocol CatalogRepositoryProtocol: Sendable {
    func loadTopLevelCatalog(at url: URL) async throws -> CatalogFeed?
    func search(query: String, baseURL: URL) async throws -> CatalogFeed?
    func search(query: String, searchDescriptorURL: URL) async throws -> CatalogFeed?
    func fetchFeed(at url: URL) async throws -> CatalogFeed?
    func fetchSearchEntryPoints(from url: URL) async throws -> [SearchFormatEntry]
    func invalidateCache(for url: URL)

    /// Synchronous, memory-only cache lookup. Returns a cached feed if one
    /// exists and is not too old, without triggering any network activity.
    /// Used by CatalogViewModel for instant entry point switching.
    func cachedFeed(for url: URL) -> CatalogFeed?
}

public final class CatalogRepository: CatalogRepositoryProtocol, @unchecked Sendable {
    // CONCURRENCY INVARIANT (@unchecked Sendable):
    // All mutable state lives inside `cache`, an OSAllocatedUnfairLock that
    // serializes every read and write (the lock replaced the former serial
    // `catalog.cache.queue` DispatchQueue). No mutable stored property exists
    // outside that lock. The remaining stored properties are immutable `let`s:
    // `api` is an internally-thread-safe network client, `now` /
    // `accountIDProvider` are `@Sendable` closures, and `defaults`
    // (`UserDefaults`) is documented thread-safe. We retain `@unchecked`
    // (rather than synthesized `Sendable`) only because the injected
    // `CatalogAPI` protocol is not yet annotated `Sendable` (owned by a
    // sibling modernization pass); the lock makes the conformance sound today.
    private let api: CatalogAPI
    private static let lastAppLaunchKey = "CatalogRepository.lastAppLaunch"

    /// Test seam: injectable "now" provider so unit tests can drive the
    /// stale-while-revalidate clock deterministically without sleeping.
    /// Production callers use the default (`Date.init`).
    private let now: @Sendable () -> Date

    /// Library/account isolation: cache entries are scoped by the current
    /// account UUID so that, if a single repository instance survives a
    /// library switch, library A's catalog can NOT be served to library B.
    /// The bearer token itself is deliberately NOT used as the key — it
    /// rotates (refresh / re-auth) while the library identity is stable.
    /// `nil` is treated as the "anonymous / pre-account" scope.
    private let accountIDProvider: @Sendable () -> String?

    /// `UserDefaults` backing store for the `lastAppLaunchKey` heuristic
    /// (drives `needsBackgroundRefresh` and the 7-day URLCache wipe).
    /// Production callers use `.standard`; tests inject a per-suite
    /// `UserDefaults(suiteName:)` so the last-launch timestamp cannot
    /// leak across tests. There is NO fallback once injected.
    private let defaults: UserDefaults

    /// Lock-guarded mutable cache state. Replaces the former serial
    /// `cacheQueue` DispatchQueue — every access goes through
    /// `cache.withLockUnchecked { … }`. `withLockUnchecked` is used (rather
    /// than `withLock`) because the guarded model types (`CatalogFeed`,
    /// `SearchFormatEntry`) are not yet `Sendable`; the lock itself provides
    /// the synchronization that makes that safe.
    private struct CacheState {
        var memoryCache: [String: CachedFeed] = [:]
        /// Dedicated cache for format entry points, keyed by groups-feed URL.
        /// Pre-warmed by loadTopLevelCatalog so search can display the format
        /// picker immediately without an extra network round-trip when the
        /// user first opens search.
        var formatEntriesCache: [String: [SearchFormatEntry]] = [:]
        /// Track if we need to refresh stale content in background.
        var needsBackgroundRefresh = false
    }
    private let cache = OSAllocatedUnfairLock(uncheckedState: CacheState())

    /// Handle on the most recently scheduled background stale-revalidate
    /// refresh Task. Retained ONLY so tests can `await` its completion
    /// deterministically (`_awaitBackgroundRefreshForTesting()`), instead of
    /// polling `cachedFeed(...)` for the write to land — a poll that is
    /// inherently racy under cooperative-pool oversubscription because the
    /// refresh is dispatched at `.utility` priority and the pool can defer it
    /// past any fixed poll deadline (the parallel-sim-clone timeouts in CI
    /// run 29805821296). Production behavior is UNCHANGED: the refresh still
    /// runs detached / fire-and-forget; we merely keep a reference to the last
    /// one so a test can join it. `nil` until the first stale read schedules a
    /// refresh. Lock-guarded so the write from `loadTopLevelCatalog` and the
    /// read from the test seam are race-free.
    private let lastBackgroundRefreshTask = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

    private struct CachedFeed {
        let feed: CatalogFeed
        let timestamp: Date
    }

    /// Fresh cache - use without question (< 10 minutes old)
    private func isExpired(_ entry: CachedFeed) -> Bool {
        now().timeIntervalSince(entry.timestamp) > 600
    }

    /// Stale but usable - show immediately, refresh in background (10 min - 24 hours)
    private func isStaleButUsable(_ entry: CachedFeed) -> Bool {
        let age = now().timeIntervalSince(entry.timestamp)
        return age > 600 && age <= 86400
    }

    /// Too old - must refresh (> 24 hours)
    private func isTooOld(_ entry: CachedFeed) -> Bool {
        now().timeIntervalSince(entry.timestamp) > 86400
    }

    // PUBLIC_INTENT: defaults: arg added by swarm_cd181acd D-cleanup to inject UserDefaults for per-test isolation. Default `.standard` preserves all production callers.
    public init(api: CatalogAPI, defaults: UserDefaults = .standard) {
        self.api = api
        self.now = { Date() }
        self.accountIDProvider = { nil }
        self.defaults = defaults
        self.checkStaleCacheStatus()
        self.subscribeToMemoryWarning()
    }

    /// Production initializer that scopes the cache by the current
    /// account/library UUID. Pass a closure rather than a snapshot so that
    /// the repository sees the *current* account each call — the value
    /// changes when the user switches libraries.
    // PUBLIC_INTENT: defaults: arg added by swarm_cd181acd D-cleanup; same rationale as the no-accountID overload above.
    public init(api: CatalogAPI, accountID: @escaping @Sendable () -> String?, defaults: UserDefaults = .standard) {
        self.api = api
        self.now = { Date() }
        self.accountIDProvider = accountID
        self.defaults = defaults
        self.checkStaleCacheStatus()
        self.subscribeToMemoryWarning()
    }

    /// Test-only initializer that accepts an injectable clock. Production code
    /// should use `init(api:)` which defaults `now` to `Date.init`. This overload
    /// is `public` only to be reachable from `PalaceTests` (which imports
    /// `PalaceCatalog` without `@testable`).
    // PUBLIC_INTENT: defaults: arg added by swarm_cd181acd D-cleanup; same rationale. Test-only initializer reachable from PalaceTests without @testable.
    public init(api: CatalogAPI, now: @escaping @Sendable () -> Date, defaults: UserDefaults = .standard) {
        self.api = api
        self.now = now
        self.accountIDProvider = { nil }
        self.defaults = defaults
        self.checkStaleCacheStatus()
        self.subscribeToMemoryWarning()
    }

    /// Test-only initializer that injects both a clock and an account-ID
    /// provider. Used by cache-isolation tests to simulate library switches
    /// deterministically.
    // PUBLIC_INTENT: defaults: arg added by swarm_cd181acd D-cleanup; same rationale. Test-only initializer for cache-isolation tests.
    public init(api: CatalogAPI, accountID: @escaping @Sendable () -> String?, now: @escaping @Sendable () -> Date, defaults: UserDefaults = .standard) {
        self.api = api
        self.now = now
        self.accountIDProvider = accountID
        self.defaults = defaults
        self.checkStaleCacheStatus()
        self.subscribeToMemoryWarning()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Build the cache key for `url`. Scoped by the current account UUID
    /// so library A's catalog can never be served to library B.
    private func cacheKey(for url: URL) -> String {
        let account = accountIDProvider() ?? "__anonymous__"
        return account + "|" + url.absoluteString
    }

    // MARK: - Memory-warning eviction
    //
    // CONTRACT: only the in-memory feed/format-entries maps are dropped.
    // The on-disk URLCache.shared is content-addressed and survives memory
    // pressure intentionally — dropping it would force a re-download of
    // every catalog page after the OS sends a warning, which is exactly
    // what disk caching is meant to avoid.
    private func subscribeToMemoryWarning() {
        #if canImport(UIKit)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
        #endif
    }

    @objc private func handleMemoryWarning() {
        Log.info(#file, "Memory warning received — clearing in-memory catalog cache (disk cache preserved)")
        cache.withLockUnchecked { state in
            state.memoryCache.removeAll()
            state.formatEntriesCache.removeAll()
        }
    }

    /// Check if cache is stale - clear URLCache but keep memory cache for stale-while-revalidate
    private func checkStaleCacheStatus() {
        let currentDate = now()
        let lastLaunch = defaults.object(forKey: Self.lastAppLaunchKey) as? Date ?? .distantPast
        let daysSinceLastLaunch = Calendar.current.dateComponents([.day], from: lastLaunch, to: currentDate).day ?? 0

        if daysSinceLastLaunch >= 7 {
            Log.info(#file, "App hasn't been used in \(daysSinceLastLaunch) days - clearing HTTP cache")
            // Clear URLCache to prevent stale/corrupted HTTP responses from causing parsing crashes
            // in legacy OPDS code. Our memory cache is preserved for stale-while-revalidate.
            //
            // N1 NOTE (swarm_27c181b5): OPDS feeds are actually served from the
            // network executor's PRIVATE URLCache (see `TPPCaching.makeCache`),
            // NOT from `URLCache.shared`, so this wipe is effectively a no-op for
            // feed responses. `CatalogRepository` lives in the PalaceCatalog SPM
            // package and only holds a `CatalogAPI` whose `NetworkClient` surface
            // (`send` only) exposes no cache-clear seam, and the package cannot
            // reach `AppContainer.production().networkExecutor` without an
            // inverted app-target dependency. Routing this site correctly needs a
            // `clearCache()` on the `NetworkClient` protocol — deferred rather
            // than introduce a bad dependency here. The privacy-critical clears
            // (sign-out / force-reset) already route through the executor.
            URLCache.shared.removeAllCachedResponses()
        }
        if daysSinceLastLaunch >= 1 {
            cache.withLockUnchecked { $0.needsBackgroundRefresh = true }
        }

        defaults.set(currentDate, forKey: Self.lastAppLaunchKey)
    }

    public func loadTopLevelCatalog(at url: URL) async throws -> CatalogFeed? {
        let cacheKey = cacheKey(for: url)

        let cachedEntry = cache.withLockUnchecked { $0.memoryCache[cacheKey] }

        // STALE-WHILE-REVALIDATE PATTERN:
        // 1. Fresh cache (< 10 min) → return immediately
        // 2. Stale but usable (10 min - 24 hr) → return immediately, refresh in background
        // 3. Too old (> 24 hr) or no cache → fetch fresh

        if let entry = cachedEntry, !isExpired(entry) {
            Log.debug(#file, "Returning fresh cached catalog feed for \(url.absoluteString)")
            prewarmFormatEntriesCache(from: entry.feed, cacheKey: cacheKey)
            return entry.feed
        }

        // Stale-while-revalidate: return stale content immediately, refresh in background
        let needsBackgroundRefresh = cache.withLockUnchecked { $0.needsBackgroundRefresh }
        if let entry = cachedEntry, isStaleButUsable(entry) || needsBackgroundRefresh {
            Log.info(#file, "Returning stale cached catalog feed, refreshing in background: \(url.absoluteString)")
            prewarmFormatEntriesCache(from: entry.feed, cacheKey: cacheKey)

            // Schedule background refresh (fire-and-forget in production). The
            // Task handle is retained in `lastBackgroundRefreshTask` purely so a
            // test can join it deterministically — see the field's doc comment.
            // Behavior is identical to a bare `Task.detached { … }`: nothing
            // production awaits this handle.
            let refreshTask = Task.detached(priority: .utility) { [weak self] in
                await self?.refreshFeedInBackground(url: url, cacheKey: cacheKey)
                return ()
            }
            lastBackgroundRefreshTask.withLock { $0 = refreshTask }

            return entry.feed
        }

        Log.info(#file, "Fetching fresh catalog feed from network: \(url.absoluteString)")

        // Fetch from API with timeout protection
        let feed: CatalogFeed?
        do {
            feed = try await withTimeout(seconds: 30) { [weak self] in
                try await self?.api.fetchFeed(at: url)
            }
        } catch is CancellationError {
            // Let cancellation errors propagate naturally for proper task cancellation handling
            Log.debug(#file, "Catalog feed fetch was cancelled")
            throw CancellationError()
        } catch {
            // If network fails and we have ANY cached content (even too old), use it as fallback
            if let entry = cachedEntry {
                Log.warn(#file, "Network failed, using old cached feed as fallback: \(error.localizedDescription)")
                return entry.feed
            }

            Log.error(#file, "Failed to fetch catalog feed: \(error.localizedDescription)")
            throw NSError(domain: "CatalogRepository", code: 0,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to fetch catalog feed: \(error.localizedDescription)"])
        }

        guard let feed = feed else {
            // Fallback to cached content if fetch returns nil
            if let entry = cachedEntry {
                return entry.feed
            }
            throw NSError(domain: "CatalogRepository", code: 0,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to fetch catalog feed"])
        }

        // Cache the result
        let cachedFeed = CachedFeed(feed: feed, timestamp: now())
        cache.withLockUnchecked { $0.memoryCache[cacheKey] = cachedFeed }
        prewarmFormatEntriesCache(from: feed, cacheKey: cacheKey)

        Task.detached(priority: .background) {
            await self.preloadRelatedFacets(from: feed)
        }

        return feed
    }

    /// Refresh a feed in the background without blocking UI
    private func refreshFeedInBackground(url: URL, cacheKey: String) async {
        do {
            let feed = try await withTimeout(seconds: 30) { [weak self] in
                try await self?.api.fetchFeed(at: url)
            }

            guard let feed = feed else { return }

            let cachedFeed = CachedFeed(feed: feed, timestamp: now())
            cache.withLockUnchecked { $0.memoryCache[cacheKey] = cachedFeed }
            Log.info(#file, "Background refresh completed for: \(url.absoluteString)")

            // Preload related facets too
            await preloadRelatedFacets(from: feed)
            prewarmFormatEntriesCache(from: feed, cacheKey: cacheKey)

        } catch {
            Log.warn(#file, "Background refresh failed (not critical): \(error.localizedDescription)")
        }
    }

    /// Extract format entry points from a feed and store them in the format-entries cache
    /// if not already populated. Called from all `loadTopLevelCatalog` code paths so the
    /// search format picker has data immediately when the user opens search.
    private func prewarmFormatEntriesCache(from feed: CatalogFeed, cacheKey: String) {
        let entries = DefaultCatalogAPI.extractSearchEntryPoints(from: feed)
        guard !entries.isEmpty else { return }
        cache.withLockUnchecked { state in
            guard state.formatEntriesCache[cacheKey] == nil else { return }
            state.formatEntriesCache[cacheKey] = entries
        }
    }

    private func withTimeout<T: Sendable>(seconds: TimeInterval, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut,
                              userInfo: [NSLocalizedDescriptionKey: "Request timed out after \(seconds) seconds"])
            }

            guard let result = try await group.next() else {
                throw NSError(domain: NSURLErrorDomain, code: NSURLErrorUnknown,
                              userInfo: [NSLocalizedDescriptionKey: "No result from task group"])
            }
            group.cancelAll()
            return result
        }
    }

    public func search(query: String, baseURL: URL) async throws -> CatalogFeed? {
        try await api.search(query: query, baseURL: baseURL)
    }

    public func fetchFeed(at url: URL) async throws -> CatalogFeed? {
        try await api.fetchFeed(at: url)
    }

    public func fetchSearchEntryPoints(from url: URL) async throws -> [SearchFormatEntry] {
        let cacheKey = cacheKey(for: url)

        // Check the dedicated format-entries cache first. Pre-warmed by loadTopLevelCatalog
        // so the search format picker has data without an extra network round-trip.
        let cached = cache.withLockUnchecked { $0.formatEntriesCache[cacheKey] }
        if let cached, !cached.isEmpty {
            return cached
        }

        // Cache miss — fetch from network and cache for next time.
        let entries = try await api.fetchSearchEntryPoints(from: url)
        if !entries.isEmpty {
            cache.withLockUnchecked { $0.formatEntriesCache[cacheKey] = entries }
        }
        return entries
    }

    public func search(query: String, searchDescriptorURL: URL) async throws -> CatalogFeed? {
        try await api.search(query: query, searchDescriptorURL: searchDescriptorURL)
    }

    public func invalidateCache(for url: URL) {
        let cacheKey = cacheKey(for: url)
        cache.withLockUnchecked { $0.memoryCache[cacheKey] = nil }
    }

    public func cachedFeed(for url: URL) -> CatalogFeed? {
        let cacheKey = cacheKey(for: url)
        // Synchronous, read-only lookup under the cache lock. The unfair lock
        // holds only briefly, so calling this from the MainActor is safe.
        return cache.withLockUnchecked { state in
            guard let entry = state.memoryCache[cacheKey], !isTooOld(entry) else { return nil }
            return entry.feed
        }
    }

    /// TEST SEAM — deterministically await the in-flight stale-revalidate
    /// background refresh scheduled by the most recent `loadTopLevelCatalog`
    /// stale read. Returns immediately if none is in flight.
    ///
    /// Why this exists: the background refresh is dispatched via
    /// `Task.detached(priority: .utility)` and production intentionally does
    /// not await it. A test that needs to assert the post-refresh cache state
    /// therefore has to wait for that Task to complete — and polling
    /// `cachedFeed(...)` for the write to land is NON-DETERMINISTIC under
    /// cooperative-thread-pool oversubscription: with 4 sim clones on a
    /// 3–4-core CI runner, a `.utility` task can be deferred past any fixed
    /// poll deadline, so the poll times out even though the code is correct
    /// (CI run 29805821296 parallel-only timeouts). Awaiting the actual Task
    /// handle removes the wall-clock/pool dependence entirely — the test
    /// blocks exactly until the refresh finishes, no matter how starved the
    /// pool is.
    ///
    /// This changes NO production behavior: `loadTopLevelCatalog` still fires
    /// the refresh detached and returns immediately; this method only reads a
    /// handle the repository already retains. `public` (not `#if DEBUG`) to be
    /// reachable from `PalaceTests`, which imports `PalaceCatalog` without
    /// `@testable` — matching the existing test-only initializers above.
    public func _awaitBackgroundRefreshForTesting() async {
        let task = lastBackgroundRefreshTask.withLock { $0 }
        await task?.value
    }

    // MARK: - Background Preloading

    private func preloadRelatedFacets(from feed: CatalogFeed) async {
        guard let links = feed.opdsFeed.links as? [TPPOPDSLink] else { return }

        let facetURLs = links
            .filter { $0.rel == TPPOPDSRelationFacet }
            .compactMap { $0.href }
            .prefix(5)

        // Fetch facets concurrently instead of serially
        await withTaskGroup(of: Void.self) { group in
            for url in facetURLs {
                group.addTask { [weak self] in
                    guard let self else { return }
                    let cacheKey = self.cacheKey(for: url)

                    let isCached = self.cache.withLockUnchecked { $0.memoryCache[cacheKey] != nil }
                    guard !isCached else { return }

                    do {
                        if let preloadedFeed = try await self.api.fetchFeed(at: url) {
                            let cachedFeed = CachedFeed(feed: preloadedFeed, timestamp: self.now())
                            self.cache.withLockUnchecked { $0.memoryCache[cacheKey] = cachedFeed }
                        }
                    } catch {
                        // Silently fail preloading
                    }
                }
            }
        }
    }
}
