import Foundation

public protocol CatalogAPI {
    func fetchFeed(at url: URL) async throws -> CatalogFeed?
    func search(query: String, baseURL: URL) async throws -> CatalogFeed?
    /// Search using a known OpenSearch descriptor URL, skipping the groups feed fetch.
    func search(query: String, searchDescriptorURL: URL) async throws -> CatalogFeed?
    /// Fetch a groups feed and return its entry-point format facets.
    func fetchSearchEntryPoints(from url: URL) async throws -> [SearchFormatEntry]
}

public final class DefaultCatalogAPI: CatalogAPI {
    public let client: NetworkClient
    public let parser: OPDSParser

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
        guard let catalogFeed = try await fetchFeed(at: baseURL) else {
            throw NSError(domain: NSURLErrorDomain, code: NSURLErrorBadURL, userInfo: [NSLocalizedDescriptionKey: "Could not load catalog feed"])
        }

        let links = catalogFeed.opdsFeed.links as? [TPPOPDSLink] ?? []
        if let searchURL = links.first(where: { $0.rel == "search" && $0.href != nil })?.href {
            return try await search(query: query, searchDescriptorURL: searchURL)
        } else {
            var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
            var items = comps?.queryItems ?? []
            items.append(URLQueryItem(name: "q", value: query))
            comps?.queryItems = items
            guard let url = comps?.url else {
                throw NSError(domain: NSURLErrorDomain, code: NSURLErrorBadURL, userInfo: [NSLocalizedDescriptionKey: "Could not create search URL"])
            }
            return try await fetchFeed(at: url)
        }
    }

    public func search(query: String, searchDescriptorURL: URL) async throws -> CatalogFeed? {
        return try await withCheckedThrowingContinuation { continuation in
            TPPOpenSearchDescription.withURL(searchDescriptorURL, shouldResetCache: false) { description in
                guard let description = description else {
                    continuation.resume(throwing: NSError(domain: NSURLErrorDomain, code: NSURLErrorBadURL, userInfo: [NSLocalizedDescriptionKey: "Could not load OpenSearch description"]))
                    return
                }

                guard let searchResultURL = description.opdsurl(forSearching: query) else {
                    continuation.resume(throwing: NSError(domain: NSURLErrorDomain, code: NSURLErrorBadURL, userInfo: [NSLocalizedDescriptionKey: "Could not create search URL"]))
                    return
                }

                Task {
                    do {
                        let searchResults = try await self.fetchFeed(at: searchResultURL)
                        continuation.resume(returning: searchResults)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    public func fetchSearchEntryPoints(from url: URL) async throws -> [SearchFormatEntry] {
        guard let feed = try await fetchFeed(at: url) else { return [] }
        return Self.extractSearchEntryPoints(from: feed)
    }

    /// Extract entry-point format facets and their search descriptor URLs from a groups feed.
    static func extractSearchEntryPoints(from feed: CatalogFeed) -> [SearchFormatEntry] {
        let opdsFeed = feed.opdsFeed

        // The groups feed's rel="search" link is the search descriptor for the active format.
        var activeSearchDescriptorURL: URL?
        if let links = opdsFeed.links as? [TPPOPDSLink] {
            for link in links where link.rel == "search" {
                activeSearchDescriptorURL = link.href
                break
            }
        }

        var entries: [SearchFormatEntry] = []
        for case let link as TPPOPDSLink in opdsFeed.links {
            guard link.rel == TPPOPDSRelationFacet,
                  let href = link.href,
                  let title = link.title else { continue }

            var isEntryPoint = false
            for (key, _) in link.attributes {
                if let keyStr = key as? String, TPPOPDSAttributeKeyStringIsFacetGroupType(keyStr) {
                    isEntryPoint = true
                    break
                }
            }
            guard isEntryPoint else { continue }

            let isActive = link.attributes.contains { k, v in
                guard let keyStr = k as? String, TPPOPDSAttributeKeyStringIsActiveFacet(keyStr) else { return false }
                return (v as? String)?.localizedCaseInsensitiveContains("true") ?? false
            }

            entries.append(SearchFormatEntry(
                id: href.absoluteString,
                title: title,
                groupsFeedURL: href,
                searchDescriptorURL: isActive ? activeSearchDescriptorURL : nil,
                isActive: isActive
            ))
        }
        return entries
    }
}
