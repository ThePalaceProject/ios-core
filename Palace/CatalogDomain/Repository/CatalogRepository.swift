import Foundation

public protocol CatalogRepositoryProtocol {
  func loadTopLevelCatalog(at url: URL) async throws -> CatalogFeed?
  func search(query: String, baseURL: URL) async throws -> CatalogFeed?
  func invalidateCache(for url: URL)
}

public final class CatalogRepository: CatalogRepositoryProtocol {
  private let api: CatalogAPI
  private var memoryCache: [URL: CatalogFeed] = [:]

  public init(api: CatalogAPI) {
    self.api = api
  }

  public func loadTopLevelCatalog(at url: URL) async throws -> CatalogFeed? {
    if let cached = memoryCache[url] { return cached }
    let feed = try await api.fetchFeed(at: url)
    if let feed { memoryCache[url] = feed }
    return feed
  }

  public func search(query: String, baseURL: URL) async throws -> CatalogFeed? {
    try await api.search(query: query, baseURL: baseURL)
  }

  public func invalidateCache(for url: URL) {
    memoryCache[url] = nil
  }
}


