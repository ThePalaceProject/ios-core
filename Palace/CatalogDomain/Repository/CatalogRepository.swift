import Foundation

public protocol CatalogRepositoryProtocol {
  func loadTopLevelCatalog(at url: URL) async throws -> CatalogFeed?
  func search(query: String, baseURL: URL) async throws -> CatalogFeed?
  func invalidateCache(for url: URL)
}

public final class CatalogRepository: CatalogRepositoryProtocol {
  private let api: CatalogAPI
  private let feedCache: GeneralCache<String, CatalogFeed>
  
  public init(api: CatalogAPI) {
    self.api = api
    self.feedCache = GeneralCache<String, CatalogFeed>(
      cacheName: "CatalogFeeds", 
      mode: .memoryOnly  // Use memory-only since CatalogFeed contains non-Codable TPPOPDSFeed
    )
  }

  public func loadTopLevelCatalog(at url: URL) async throws -> CatalogFeed? {
    let cacheKey = url.absoluteString
    let tenMinutes: TimeInterval = 10 * 60 // 10 minutes cache for fresh facet data
    
    return try await feedCache.get(
      cacheKey,
      policy: .timedCache(tenMinutes)
    ) {
      guard let feed = try await self.api.fetchFeed(at: url) else {
        throw NSError(domain: "CatalogRepository", code: 0, 
                     userInfo: [NSLocalizedDescriptionKey: "Failed to fetch catalog feed"])
      }
      
      Task.detached(priority: .background) {
        await self.preloadRelatedFacets(from: feed)
      }
      
      return feed
    }
  }

  public func search(query: String, baseURL: URL) async throws -> CatalogFeed? {
    try await api.search(query: query, baseURL: baseURL)
  }

  public func invalidateCache(for url: URL) {
    let cacheKey = url.absoluteString
    feedCache.remove(for: cacheKey)
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
      
      if feedCache.get(for: cacheKey) != nil {
        continue // Already cached, skip
      }
      
      do {
        if let preloadedFeed = try await api.fetchFeed(at: url) {
          feedCache.set(preloadedFeed, for: cacheKey, expiresIn: 600)
        }
      } catch {
      }
    }
  }
}


