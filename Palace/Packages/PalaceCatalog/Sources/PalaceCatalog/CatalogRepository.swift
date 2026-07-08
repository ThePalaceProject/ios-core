import Foundation
import PalaceLogging
#if canImport(UIKit)
import UIKit
#endif

public protocol CatalogRepositoryProtocol {
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

public final class CatalogRepository: CatalogRepositoryProtocol {
    private let api: CatalogAPI
    private var memoryCache: [String: CachedFeed] = [:]
    private let cacheQueue = DispatchQueue(label: "catalog.cache.queue", qos: .userInitiated)
    private static let lastAppLaunchKey = "CatalogRepository.lastAppLaunch"

    /// Test seam: injectable "now" provider so unit tests can drive the
    /// stale-while-revalidate clock deterministically without sleeping.
    /// Production callers use the default (`Date.init`).
    private let now: () -> Date

    /// Library/account isolation: cache entries are scoped by the current
    /// account UUID so that, if a single repository instance survives a
    /// library switch, library A's catalog can NOT be served to library B.
    /// The bearer token itself is deliberately NOT used as the key — it
    /// rotates (refresh / re-auth) while the library identity is stable.
    /// `nil` is treated as the "anonymous / pre-account" scope.
    private let accountIDProvider: () -> String?

    /// `UserDefaults` backing store for the `lastAppLaunchKey` heuristic
    /// (drives `needsBackgroundRefresh` and the 7-day URLCache wipe).
    /// Production callers use `.standard`; tests inject a per-suite
    /// `UserDefaults(suiteName:)` so the last-launch timestamp cannot
    /// leak across tests. There is NO fallback once injected.
    private let defaults: UserDefaults

    /// Dedicated cache for format entry points, keyed by groups-feed URL.
    /// Pre-warmed by loadTopLevelCatalog so search can display the format picker immediately
    /// without an extra network round-trip when the user first opens search.
    private var formatEntriesCache: [String: [SearchFormatEntry]] = [:]

    /// Track if we need to refresh stale content in background
    private var needsBackgroundRefresh = false

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
        self.now = Date.init
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
    public init(api: CatalogAPI, accountID: @escaping () -> String?, defaults: UserDefaults = .standard) {
        self.api = api
        self.now = Date.init
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
    public init(api: CatalogAPI, now: @escaping () -> Date, defaults: UserDefaults = .standard) {
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
    public init(api: CatalogAPI, accountID: @escaping () -> String?, now: @escaping () -> Date, defaults: UserDefaults = .standard) {
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
        cacheQueue.async { [weak self] in
            guard let self else { return }
            Log.info(#file, "Memory warning received — clearing in-memory catalog cache (disk cache preserved)")
            self.memoryCache.removeAll()
            self.formatEntriesCache.removeAll()
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
            URLCache.shared.removeAllCachedResponses()
        }
        if daysSinceLastLaunch >= 1 {
            needsBackgroundRefresh = true
        }

        defaults.set(currentDate, forKey: Self.lastAppLaunchKey)
    }

    public func loadTopLevelCatalog(at url: URL) async throws -> CatalogFeed? {
        let cacheKey = cacheKey(for: url)

        let cachedEntry = await withCheckedContinuation { [weak self] continuation in
            cacheQueue.async {
                continuation.resume(returning: self?.memoryCache[cacheKey])
            }
        }

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
        if let entry = cachedEntry, isStaleButUsable(entry) || needsBackgroundRefresh {
            Log.info(#file, "Returning stale cached catalog feed, refreshing in background: \(url.absoluteString)")
            prewarmFormatEntriesCache(from: entry.feed, cacheKey: cacheKey)

            // Schedule background refresh
            Task.detached(priority: .utility) { [weak self] in
                await self?.refreshFeedInBackground(url: url, cacheKey: cacheKey)
            }

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
        await withCheckedContinuation { continuation in
            cacheQueue.async {
                self.memoryCache[cacheKey] = CachedFeed(feed: feed, timestamp: self.now())
                continuation.resume()
            }
        }
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

            await withCheckedContinuation { continuation in
                cacheQueue.async {
                    self.memoryCache[cacheKey] = CachedFeed(feed: feed, timestamp: self.now())
                    Log.info(#file, "Background refresh completed for: \(url.absoluteString)")
                    continuation.resume()
                }
            }

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
        cacheQueue.async { [weak self] in
            guard let self, self.formatEntriesCache[cacheKey] == nil else { return }
            self.formatEntriesCache[cacheKey] = entries
        }
    }

    private func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
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
        let cached = await withCheckedContinuation { (c: CheckedContinuation<[SearchFormatEntry]?, Never>) in
            cacheQueue.async { [weak self] in
                c.resume(returning: self?.formatEntriesCache[cacheKey])
            }
        }
        if let cached, !cached.isEmpty {
            return cached
        }

        // Cache miss — fetch from network and cache for next time.
        let entries = try await api.fetchSearchEntryPoints(from: url)
        if !entries.isEmpty {
            cacheQueue.async { [weak self] in
                self?.formatEntriesCache[cacheKey] = entries
            }
        }
        return entries
    }

    public func search(query: String, searchDescriptorURL: URL) async throws -> CatalogFeed? {
        try await api.search(query: query, searchDescriptorURL: searchDescriptorURL)
    }

    public func invalidateCache(for url: URL) {
        let cacheKey = cacheKey(for: url)
        cacheQueue.async {
            self.memoryCache[cacheKey] = nil
        }
    }

    public func cachedFeed(for url: URL) -> CatalogFeed? {
        let cacheKey = cacheKey(for: url)
        // Synchronous access — safe because cacheQueue is serial and we
        // only read. DispatchQueue.sync on a serial queue is deadlock-safe
        // when called from a different queue (MainActor in our case).
        return cacheQueue.sync {
            guard let entry = memoryCache[cacheKey], !isTooOld(entry) else { return nil }
            return entry.feed
        }
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

                    let isCached = await withCheckedContinuation { continuation in
                        self.cacheQueue.async {
                            continuation.resume(returning: self.memoryCache[cacheKey] != nil)
                        }
                    }
                    guard !isCached else { return }

                    do {
                        if let preloadedFeed = try await self.api.fetchFeed(at: url) {
                            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                                self.cacheQueue.async {
                                    self.memoryCache[cacheKey] = CachedFeed(feed: preloadedFeed, timestamp: self.now())
                                    c.resume()
                                }
                            }
                        }
                    } catch {
                        // Silently fail preloading
                    }
                }
            }
        }
    }
}
