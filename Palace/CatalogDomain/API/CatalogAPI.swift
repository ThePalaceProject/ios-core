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
        let acceptHeader = RemoteFeatureFlags.shared.isOPDS2Enabled
            ? "application/opds+json, application/atom+xml;q=0.9, */*;q=0.1"
            : "application/atom+xml, */*;q=0.1"
        let req = NetworkRequest(
            method: .GET,
            url: url,
            headers: ["Accept": acceptHeader]
        )
        let res = try await client.send(req)
        Log.info(#file, "[OPDS2-DIAG] Fetched \(url.lastPathComponent): \(res.data.count) bytes, " +
            "first byte=\(String(data: res.data.prefix(1), encoding: .utf8) ?? "?")")
        return try parser.parseFeed(from: res.data)
    }

    public func search(query: String, baseURL: URL) async throws -> CatalogFeed? {
        guard let catalogFeed = try await fetchFeed(at: baseURL) else {
            throw NSError(domain: NSURLErrorDomain, code: NSURLErrorBadURL, userInfo: [NSLocalizedDescriptionKey: "Could not load catalog feed"])
        }

        // OPDS 2: use the search URL template directly
        if let opds2SearchURL = catalogFeed.opds2Feed?.searchURL {
            let searchURLString = opds2SearchURL.absoluteString
                .replacingOccurrences(of: "{?query}", with: "?q=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query)")
                .replacingOccurrences(of: "{query}", with: query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query)

            // If it was a templated URL, use the expanded version; otherwise append ?q=
            if let url = URL(string: searchURLString), searchURLString != opds2SearchURL.absoluteString {
                Log.info(#file, "[OPDS2-DIAG] OPDS2 search: \(url.absoluteString)")
                return try await fetchFeed(at: url)
            } else {
                var comps = URLComponents(url: opds2SearchURL, resolvingAgainstBaseURL: false)
                var items = comps?.queryItems ?? []
                items.append(URLQueryItem(name: "q", value: query))
                comps?.queryItems = items
                if let url = comps?.url {
                    Log.info(#file, "[OPDS2-DIAG] OPDS2 search (appended q): \(url.absoluteString)")
                    return try await fetchFeed(at: url)
                }
            }
        }

        // OPDS 1: use OpenSearch descriptor
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

                guard let searchResultURL = description.opdsURL(forSearchingString: query) else {
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
        // OPDS 2 path
        if let opds2 = feed.opds2Feed {
            return extractOPDS2SearchEntryPoints(from: opds2)
        }

        // OPDS 1 path
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
                  let title = link.title,
                  !title.isEmpty else { continue }
            let href = link.href

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

    /// Extract entry points from OPDS 2 feed facets.
    private static func extractOPDS2SearchEntryPoints(from feed: OPDS2Feed) -> [SearchFormatEntry] {
        let entryPointGroupNames: Set<String> = ["formats", "entrypoint", "entry point", "entry points"]

        // Search URL from the feed links
        let searchURL = feed.searchURL

        guard let facets = feed.facets else { return [] }

        var entries: [SearchFormatEntry] = []
        for facetGroup in facets {
            guard entryPointGroupNames.contains(facetGroup.title.lowercased()) else { continue }

            for link in facetGroup.links {
                guard let href = link.hrefURL else { continue }

                let isActive = link.isActive
                entries.append(SearchFormatEntry(
                    id: link.href,
                    title: link.title,
                    groupsFeedURL: href,
                    searchDescriptorURL: isActive ? searchURL : nil,
                    isActive: isActive
                ))
            }
        }
        return entries
    }
}
