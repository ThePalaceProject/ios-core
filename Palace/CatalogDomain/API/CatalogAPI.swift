import Foundation

public protocol CatalogAPI {
  func fetchFeed(at url: URL) async throws -> CatalogFeed?
  func search(query: String, baseURL: URL) async throws -> CatalogFeed?
}

public final class DefaultCatalogAPI: CatalogAPI {
  private let client: NetworkClient
  private let parser: OPDSParser

  public init(client: NetworkClient, parser: OPDSParser) {
    self.client = client
    self.parser = parser
  }

  public func fetchFeed(at url: URL) async throws -> CatalogFeed? {
    let req = NetworkRequest(method: .GET, url: url)
    let res = try await client.send(req)
    return try parser.parseFeed(from: res.data)
  }

  public func search(query: String, baseURL: URL) async throws -> CatalogFeed? {
    var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
    var items = comps?.queryItems ?? []
    items.append(URLQueryItem(name: "q", value: query))
    comps?.queryItems = items
    guard let url = comps?.url else { throw NSError(domain: NSURLErrorDomain, code: NSURLErrorBadURL) }
    return try await fetchFeed(at: url)
  }
}


