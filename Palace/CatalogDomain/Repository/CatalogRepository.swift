import Foundation

public protocol CatalogRepositoryProtocol {
  func loadTopLevelCatalog(at url: URL) async throws -> CatalogFeed?
  func search(query: String, baseURL: URL) async throws -> CatalogFeed?
  func fetchFeed(at url: URL) async throws -> CatalogFeed?
  func invalidateCache(for url: URL)
}

public final class CatalogRepository: CatalogRepositoryProtocol {
  private let api: CatalogAPI
  private var memoryCache: [String: CachedFeed] = [:]
  private let cacheQueue = DispatchQueue(label: "catalog.cache.queue", qos: .userInitiated)
  private static let lastAppLaunchKey = "CatalogRepository.lastAppLaunch"
  
  /// Track if we need to refresh stale content in background
  private var needsBackgroundRefresh = false
  
  private struct CachedFeed {
    let feed: CatalogFeed
    let timestamp: Date
    
    /// Fresh cache - use without question (10 minutes)
    var isExpired: Bool {
      Date().timeIntervalSince(timestamp) > 600
    }
    
    /// Stale but usable - show immediately, refresh in background (24 hours)
    var isStaleButUsable: Bool {
      let age = Date().timeIntervalSince(timestamp)
      return age > 600 && age <= 86400 // Between 10 min and 24 hours
    }
    
    /// Too old - must refresh (> 24 hours)
    var isTooOld: Bool {
      Date().timeIntervalSince(timestamp) > 86400
    }
  }
  
  public init(api: CatalogAPI) {
    self.api = api
    self.checkStaleCacheStatus()
  }
  
  /// Check if cache is stale - clear URLCache but keep memory cache for stale-while-revalidate
  private func checkStaleCacheStatus() {
    let now = Date()
    let lastLaunch = UserDefaults.standard.object(forKey: Self.lastAppLaunchKey) as? Date ?? .distantPast
    let daysSinceLastLaunch = Calendar.current.dateComponents([.day], from: lastLaunch, to: now).day ?? 0
    
    if daysSinceLastLaunch >= 1 {
      Log.info(#file, "App hasn't been used in \(daysSinceLastLaunch) days - clearing HTTP cache, keeping memory cache for stale-while-revalidate")
      // Clear URLCache to prevent stale/corrupted HTTP responses from causing parsing crashes
      // in legacy OPDS code. Our memory cache is preserved for stale-while-revalidate.
      URLCache.shared.removeAllCachedResponses()
      needsBackgroundRefresh = true
    }
    
    UserDefaults.standard.set(now, forKey: Self.lastAppLaunchKey)
  }

  public func loadTopLevelCatalog(at url: URL) async throws -> CatalogFeed? {
    let cacheKey = url.absoluteString
    
    let cachedEntry = await withCheckedContinuation { [weak self] continuation in
      cacheQueue.async {
        continuation.resume(returning: self?.memoryCache[cacheKey])
      }
    }
    
    // STALE-WHILE-REVALIDATE PATTERN:
    // 1. Fresh cache (< 10 min) → return immediately
    // 2. Stale but usable (10 min - 24 hr) → return immediately, refresh in background
    // 3. Too old (> 24 hr) or no cache → fetch fresh
    
    if let entry = cachedEntry, !entry.isExpired {
      Log.debug(#file, "Returning fresh cached catalog feed for \(url.absoluteString)")
      return entry.feed
    }
    
    // Stale-while-revalidate: return stale content immediately, refresh in background
    if let entry = cachedEntry, entry.isStaleButUsable || needsBackgroundRefresh {
      Log.info(#file, "Returning stale cached catalog feed, refreshing in background: \(url.absoluteString)")
      
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
        self.memoryCache[cacheKey] = CachedFeed(feed: feed, timestamp: Date())
        continuation.resume()
      }
    }
    
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
          self.memoryCache[cacheKey] = CachedFeed(feed: feed, timestamp: Date())
          Log.info(#file, "Background refresh completed for: \(url.absoluteString)")
          continuation.resume()
        }
      }
      
      // Preload related facets too
      await preloadRelatedFacets(from: feed)
      
    } catch {
      Log.warn(#file, "Background refresh failed (not critical): \(error.localizedDescription)")
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
      
      let result = try await group.next()!
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

  public func invalidateCache(for url: URL) {
    let cacheKey = url.absoluteString
    cacheQueue.async {
      self.memoryCache[cacheKey] = nil
    }
  }
  
  // MARK: - Background Preloading
  
  private func preloadRelatedFacets(from feed: CatalogFeed) async {
    guard let links = feed.opdsFeed.links as? [TPPOPDSLink] else { return }
    
    let facetURLs = links
      .filter { $0.rel == TPPOPDSRelationFacet }
      .compactMap { $0.href }
      .prefix(5) // Limit preloading to avoid excessive network usage
    
    for url in facetURLs {
      let cacheKey = url.absoluteString
      
      // Check if already cached
      let isCached = await withCheckedContinuation { continuation in
        cacheQueue.async {
          continuation.resume(returning: self.memoryCache[cacheKey] != nil)
        }
      }
      
      if isCached { continue }
      
      do {
        if let preloadedFeed = try await api.fetchFeed(at: url) {
          await withCheckedContinuation { continuation in
            cacheQueue.async {
              self.memoryCache[cacheKey] = CachedFeed(feed: preloadedFeed, timestamp: Date())
              continuation.resume()
            }
          }
        }
      } catch {
        // Silently fail preloading
      }
    }
  }
}


