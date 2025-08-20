import Foundation

public protocol CatalogRepositoryProtocol {
  func loadTopLevelCatalog(at url: URL) async throws -> CatalogFeed?
  func search(query: String, baseURL: URL) async throws -> CatalogFeed?
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
    // Do not cache searches in memory for now
    try await api.search(query: query, baseURL: baseURL)
  }
}


