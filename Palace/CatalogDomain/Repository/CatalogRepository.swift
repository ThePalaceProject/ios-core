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
  
  private struct CachedFeed {
    let feed: CatalogFeed
    let timestamp: Date
    
    var isExpired: Bool {
      Date().timeIntervalSince(timestamp) > 600 // 10 minutes
    }
  }
  
  public init(api: CatalogAPI) {
    self.api = api
  }

  public func loadTopLevelCatalog(at url: URL) async throws -> CatalogFeed? {
    let cacheKey = url.absoluteString
    
    let cachedEntry = await withCheckedContinuation { continuation in
      cacheQueue.async {
        continuation.resume(returning: self.memoryCache[cacheKey])
      }
    }
    
    if let entry = cachedEntry, !entry.isExpired {
      return entry.feed
    }
    
    // Fetch from API
    guard let feed = try await api.fetchFeed(at: url) else {
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


