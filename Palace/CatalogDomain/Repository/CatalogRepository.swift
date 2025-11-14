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
  
  private struct CachedFeed {
    let feed: CatalogFeed
    let timestamp: Date
    
    var isExpired: Bool {
      Date().timeIntervalSince(timestamp) > 600 // 10 minutes
    }
  }
  
  public init(api: CatalogAPI) {
    self.api = api
    self.checkAndClearStaleCache()
  }
  
  private func checkAndClearStaleCache() {
    let now = Date()
    let lastLaunch = UserDefaults.standard.object(forKey: Self.lastAppLaunchKey) as? Date ?? .distantPast
    let daysSinceLastLaunch = Calendar.current.dateComponents([.day], from: lastLaunch, to: now).day ?? 0
    
    if daysSinceLastLaunch >= 1 {
      Log.info(#file, "App hasn't been used in \(daysSinceLastLaunch) days, clearing stale catalog cache")
      URLCache.shared.removeAllCachedResponses()
      memoryCache.removeAll()
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
    
    if let entry = cachedEntry, !entry.isExpired {
      Log.debug(#file, "Returning cached catalog feed for \(url.absoluteString)")
      return entry.feed
    }
    
    Log.info(#file, "Fetching fresh catalog feed from network: \(url.absoluteString)")
    
    // Fetch from API with timeout protection
    let feed: CatalogFeed?
    do {
      feed = try await withTimeout(seconds: 30) { [weak self] in
        try await self?.api.fetchFeed(at: url)
      }
    } catch {
      Log.error(#file, "Failed to fetch catalog feed: \(error.localizedDescription)")
      throw NSError(domain: "CatalogRepository", code: 0, 
                   userInfo: [NSLocalizedDescriptionKey: "Failed to fetch catalog feed: \(error.localizedDescription)"])
    }
    
    guard let feed = feed else {
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


