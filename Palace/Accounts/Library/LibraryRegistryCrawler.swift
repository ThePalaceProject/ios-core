import Foundation
import PalaceLogging
import PalaceNetwork
import PalaceCatalog

// MARK: - Progress

/// Progress information reported during a crawl.
struct CrawlProgress {
    let pagesProcessed: Int
    let totalItems: Int?
    let publicationsProcessed: Int
    let isIncremental: Bool
}

// MARK: - Network Protocol

/// Abstraction for fetching data from a URL. Allows mocking in tests.
/// Returns the response alongside data so callers can inspect headers
/// (e.g. Cache-Control max-age).
protocol CrawlerNetworkFetching {
    func fetchData(from url: URL) async throws -> (Data, HTTPURLResponse?)
}

/// Default fetcher using URLSession directly — no auth tokens, no custom
/// cache policies. Registry crawling is a public unauthenticated endpoint.
struct URLSessionCrawlerFetcher: CrawlerNetworkFetching {
    func fetchData(from url: URL) async throws -> (Data, HTTPURLResponse?) {
        let (data, response) = try await URLSession.shared.data(for: URLRequest.withoutHTTP3Assumption(url: url))
        return (data, response as? HTTPURLResponse)
    }
}

// Note: HTTPURLResponse.cacheControlMaxAge is defined in Palace/Network/TPPCaching.swift

// MARK: - Delegate

protocol LibraryRegistryCrawlerDelegate: AnyObject {
    func crawler(_ crawler: LibraryRegistryCrawler, didUpdateProgress progress: CrawlProgress)
}

// MARK: - Crawler

/// Fetches libraries from the registry's paginated crawlable endpoint,
/// supporting both incremental and full crawls.
///
/// **Incremental crawl**: Uses `order=modified` facet to fetch only
/// recently-changed libraries. Stops paginating when encountering a
/// library whose `updated` date is at or before the last crawl date.
/// Never deletes libraries.
///
/// **Full crawl**: Paginates through all pages. When complete (no
/// `rel="next"` link), libraries not present in the crawl are deleted.
final class LibraryRegistryCrawler {

    enum CrawlResult {
        case success(Data)   // Merged OPDS2CatalogsFeed JSON
        case noChanges       // Nothing newer since last crawl
        case failure(Error)
    }

    /// Result from crawlFirstPage — includes the parsed page so callers
    /// can check nextPageURL without re-parsing serialized data (which
    /// drops pagination links).
    enum FirstPageResult {
        case success(data: Data, page: OPDS2CatalogsFeed)
        case noChanges
        case failure(Error)
    }

    private let fetcher: CrawlerNetworkFetching
    private let hash: String
    private let stateDirectory: URL
    private let currentAppVersion: String?
    private let nowProvider: () -> Date

    weak var delegate: LibraryRegistryCrawlerDelegate?

    init(
        fetcher: CrawlerNetworkFetching,
        hash: String,
        stateDirectory: URL? = nil,
        currentAppVersion: String? = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
        now: @escaping () -> Date = Date.init
    ) {
        self.fetcher = fetcher
        self.hash = hash
        self.stateDirectory = stateDirectory ?? {
            (try? FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )) ?? FileManager.default.temporaryDirectory
        }()
        self.currentAppVersion = currentAppVersion
        self.nowProvider = now
    }

    /// Main entry point. Determines crawl strategy and returns merged
    /// catalog data ready for caching.
    func crawl(
        baseURL: URL,
        existingPublications: [OPDS2Publication],
        feedMetadata: OPDS2CatalogsFeed.Metadata?
    ) async -> CrawlResult {
        var state = loadCrawlState()
        let crawlableURL = Self.crawlableURL(from: baseURL)

        // Determine starting URL: use stored facet URL for incremental,
        // or the plain crawlable URL for full crawls. The version + 7-day
        // periodic checks force a full crawl so deletions reconcile.
        let canIncremental = !state.needsFullCrawl(
            currentAppVersion: currentAppVersion,
            now: nowProvider()
        )
        let startURL = canIncremental ? (state.orderModifiedFacetURL ?? crawlableURL) : crawlableURL

        do {
            // Fetch first page — registry uses OPDS2CatalogsFeed format
            // (items under "catalogs" key, not "publications")
            let (firstPageData, firstResponse) = try await fetcher.fetchData(from: startURL)
            let firstPage = try OPDS2CatalogsFeed.fromData(firstPageData)

            // Extract server cache policy for future TTL tuning
            if let maxAge = firstResponse?.cacheControlMaxAge {
                state.serverMaxAge = maxAge
            }

            // Detect order=modified facet
            let facetURL = CrawlableFeedAnalysis.orderModifiedFacetURL(from: firstPage)
            let facetActive = CrawlableFeedAnalysis.isOrderModifiedActive(in: firstPage)

            // Update state with discovered facet URL
            if let facetURL = facetURL {
                state.orderModifiedFacetURL = facetURL
            }

            // Decide crawl mode
            let isIncremental: Bool
            if canIncremental && facetActive && facetURL != nil {
                isIncremental = true
            } else {
                isIncremental = false
            }

            // Collect publications across pages.
            // `allPublications` carries only entries that should propagate
            // through the merge (newer-than-cutoff in incremental mode,
            // every entry in full mode).
            // `rawCatalogs` carries every entry we've seen so far. When an
            // incremental walk reaches end-of-feed we promote that snapshot
            // to a full crawl and reconcile deletions opportunistically.
            var allPublications = [OPDS2Publication]()
            var rawCatalogs = [OPDS2Publication]()
            var currentPage = firstPage
            var pageCount = 0
            var reachedEnd = false

            while true {
                pageCount += 1
                let catalogs = currentPage.catalogs
                rawCatalogs.append(contentsOf: catalogs)

                if isIncremental, let lastCrawl = state.lastSuccessfulCrawlDate {
                    // Filter to only newer publications
                    let newer = CrawlableFeedAnalysis.publicationsNewerThan(
                        lastCrawlDate: lastCrawl,
                        in: catalogs
                    )
                    allPublications.append(contentsOf: newer)

                    // Report progress
                    delegate?.crawler(self, didUpdateProgress: CrawlProgress(
                        pagesProcessed: pageCount,
                        totalItems: nil, // OPDS2CatalogsFeed.Metadata doesn't carry numberOfItems
                        publicationsProcessed: allPublications.count,
                        isIncremental: true
                    ))

                    // Stop if we hit old content
                    if CrawlableFeedAnalysis.shouldStopIncrementalCrawl(
                        publications: catalogs,
                        lastCrawlDate: lastCrawl
                    ) {
                        break
                    }
                } else {
                    allPublications.append(contentsOf: catalogs)

                    delegate?.crawler(self, didUpdateProgress: CrawlProgress(
                        pagesProcessed: pageCount,
                        totalItems: nil,
                        publicationsProcessed: allPublications.count,
                        isIncremental: false
                    ))
                }

                // Check for next page
                guard let nextURL = currentPage.nextPageURL else {
                    reachedEnd = true
                    break
                }

                let (nextData, _) = try await fetcher.fetchData(from: nextURL)
                currentPage = try OPDS2CatalogsFeed.fromData(nextData)
            }

            // Opportunistic deletion reconciliation: an incremental walk
            // that reached end-of-feed has implicitly seen the entire
            // current registry, so we treat it as a full crawl.
            let endOfFeedFullCrawl = isIncremental && reachedEnd
            let isFullCrawl = (!isIncremental && reachedEnd) || endOfFeedFullCrawl
            let mergeUpdates = endOfFeedFullCrawl ? rawCatalogs : allPublications

            // If incremental, did NOT reach end-of-feed, and saw no new
            // publications, nothing changed.
            if isIncremental && !reachedEnd && allPublications.isEmpty {
                state.lastSuccessfulCrawlDate = nowProvider()
                state.lastCrawlAppVersion = currentAppVersion
                saveCrawlState(state)
                return .noChanges
            }

            // Merge
            let mergeResult = LibraryCatalogMerger.merge(
                existing: existingPublications,
                updates: mergeUpdates,
                isFullCrawl: isFullCrawl
            )

            // Serialize
            let meta = feedMetadata ?? OPDS2CatalogsFeed.Metadata(
                adobe_vendor_id: nil,
                title: "Palace Library Registry"
            )
            guard let serialized = LibraryCatalogMerger.serializeAsCatalogsFeed(
                publications: mergeResult.publications,
                metadata: meta
            ) else {
                return .failure(CrawlerError.serializationFailed)
            }

            // Update state
            let completedAt = nowProvider()
            state.lastSuccessfulCrawlDate = completedAt
            if isFullCrawl {
                state.lastFullCrawlDate = completedAt
            }
            state.lastCrawlAppVersion = currentAppVersion
            saveCrawlState(state)

            return .success(serialized)

        } catch {
            Log.error(#file, "Crawl failed: \(error.localizedDescription)")
            return .failure(error)
        }
    }

    // MARK: - First-Page Fast Path

    /// Fetches just the first page of the crawlable feed for fast display.
    /// Returns partial data (~20-100 libraries) in ~260ms instead of waiting
    /// for the full 5-second crawl. Call `crawlRemainingPages` afterward to
    /// get the rest in the background.
    func crawlFirstPage(baseURL: URL) async -> FirstPageResult {
        var state = loadCrawlState()
        let crawlableURL = Self.crawlableURL(from: baseURL)

        do {
            let (data, response) = try await fetcher.fetchData(from: crawlableURL)
            let page = try OPDS2CatalogsFeed.fromData(data)

            if let maxAge = response?.cacheControlMaxAge {
                state.serverMaxAge = maxAge
            }

            // Detect and store facet URL for future incremental crawls
            if let facetURL = CrawlableFeedAnalysis.orderModifiedFacetURL(from: page) {
                state.orderModifiedFacetURL = facetURL
            }
            saveCrawlState(state)

            // Serialize first page as a partial catalog for immediate display
            let meta = OPDS2CatalogsFeed.Metadata(
                adobe_vendor_id: page.metadata.adobe_vendor_id,
                title: page.metadata.title
            )
            guard let serialized = LibraryCatalogMerger.serializeAsCatalogsFeed(
                publications: page.catalogs,
                metadata: meta
            ) else {
                return .failure(CrawlerError.serializationFailed)
            }

            // Return both serialized data (for caching) and parsed page (for pagination links)
            return .success(data: serialized, page: page)
        } catch {
            Log.error(#file, "First page crawl failed: \(error.localizedDescription)")
            return .failure(error)
        }
    }

    /// Fetches remaining pages after the first page and merges everything
    /// into a complete catalog. Uses parallel fetching for full crawls.
    func crawlRemainingPages(
        firstPage: OPDS2CatalogsFeed,
        baseURL: URL,
        existingPublications: [OPDS2Publication],
        feedMetadata: OPDS2CatalogsFeed.Metadata?
    ) async -> CrawlResult {
        var state = loadCrawlState()

        guard let nextURL = firstPage.nextPageURL else {
            // Only one page — first page was the complete catalog
            let completedAt = nowProvider()
            state.lastSuccessfulCrawlDate = completedAt
            state.lastFullCrawlDate = completedAt
            state.lastCrawlAppVersion = currentAppVersion
            saveCrawlState(state)

            let meta = feedMetadata ?? OPDS2CatalogsFeed.Metadata(adobe_vendor_id: nil, title: "Palace Library Registry")
            guard let serialized = LibraryCatalogMerger.serializeAsCatalogsFeed(
                publications: firstPage.catalogs,
                metadata: meta
            ) else {
                return .failure(CrawlerError.serializationFailed)
            }
            return .success(serialized)
        }

        do {
            var allPublications = firstPage.catalogs

            // Try parallel fetching if we know the total count
            if let numberOfItems = firstPage.metadata.numberOfItems,
               numberOfItems > firstPage.catalogs.count {
                let remaining = try await fetchPagesParallel(
                    firstPageURL: nextURL,
                    totalItems: numberOfItems,
                    firstPageCount: firstPage.catalogs.count
                )
                allPublications.append(contentsOf: remaining)
            } else {
                // Fall back to sequential pagination
                var currentNextURL: URL? = nextURL
                while let url = currentNextURL {
                    let (data, _) = try await fetcher.fetchData(from: url)
                    let page = try OPDS2CatalogsFeed.fromData(data)
                    allPublications.append(contentsOf: page.catalogs)
                    currentNextURL = page.nextPageURL
                }
            }

            // Merge with existing
            let mergeResult = LibraryCatalogMerger.merge(
                existing: existingPublications,
                updates: allPublications,
                isFullCrawl: true
            )

            let meta = feedMetadata ?? OPDS2CatalogsFeed.Metadata(adobe_vendor_id: nil, title: "Palace Library Registry")
            guard let serialized = LibraryCatalogMerger.serializeAsCatalogsFeed(
                publications: mergeResult.publications,
                metadata: meta
            ) else {
                return .failure(CrawlerError.serializationFailed)
            }

            let completedAt = nowProvider()
            state.lastSuccessfulCrawlDate = completedAt
            state.lastFullCrawlDate = completedAt
            state.lastCrawlAppVersion = currentAppVersion
            saveCrawlState(state)

            return .success(serialized)
        } catch {
            Log.error(#file, "Remaining pages crawl failed: \(error.localizedDescription)")
            return .failure(error)
        }
    }

    // MARK: - Parallel Page Fetching

    /// Fetches remaining pages in parallel using TaskGroup.
    /// Only used for full crawls where we know the total item count.
    private func fetchPagesParallel(
        firstPageURL: URL,
        totalItems: Int,
        firstPageCount: Int
    ) async throws -> [OPDS2Publication] {
        // Parse the first next-page URL to extract offset/size pattern
        guard let components = URLComponents(url: firstPageURL, resolvingAgainstBaseURL: false) else {
            throw CrawlerError.serializationFailed
        }

        let queryItems = components.queryItems ?? []
        let pageSize = Int(queryItems.first { $0.name == "size" }?.value ?? "") ?? 100
        let firstOffset = Int(queryItems.first { $0.name == "offset" }?.value ?? "") ?? firstPageCount

        // Calculate all page offsets
        var offsets = [Int]()
        var offset = firstOffset
        while offset < totalItems {
            offsets.append(offset)
            offset += pageSize
        }

        guard !offsets.isEmpty else { return [] }

        // Fetch in parallel with max concurrency of 4
        let maxConcurrent = 4
        var allResults = [(offset: Int, catalogs: [OPDS2Publication])]()

        for chunk in offsets.chunked(into: maxConcurrent) {
            let chunkResults = try await withThrowingTaskGroup(
                of: (Int, [OPDS2Publication]).self
            ) { group in
                for pageOffset in chunk {
                    group.addTask { [fetcher] in
                        var pageComponents = components
                        pageComponents.queryItems = (pageComponents.queryItems ?? []).map { item in
                            if item.name == "offset" {
                                return URLQueryItem(name: "offset", value: "\(pageOffset)")
                            }
                            return item
                        }
                        // Ensure offset is present
                        if !(pageComponents.queryItems ?? []).contains(where: { $0.name == "offset" }) {
                            pageComponents.queryItems = (pageComponents.queryItems ?? []) + [URLQueryItem(name: "offset", value: "\(pageOffset)")]
                        }

                        guard let url = pageComponents.url else {
                            throw CrawlerError.serializationFailed
                        }

                        let (data, _) = try await fetcher.fetchData(from: url)
                        let page = try OPDS2CatalogsFeed.fromData(data)
                        return (pageOffset, page.catalogs)
                    }
                }

                var results = [(Int, [OPDS2Publication])]()
                for try await result in group {
                    results.append(result)
                }
                return results
            }
            allResults.append(contentsOf: chunkResults)
        }

        // Sort by offset to maintain deterministic ordering
        return allResults
            .sorted { $0.offset < $1.offset }
            .flatMap(\.catalogs)
    }

    // MARK: - URL Construction

    /// Converts a base registry URL to the crawlable endpoint URL.
    /// e.g. `.../libraries` → `.../libraries/crawlable`
    ///      `.../libraries/qa` → `.../libraries/crawlable?availability=all`
    static func crawlableURL(from baseURL: URL) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        let originalPath = components?.path ?? ""
        let isBeta = originalPath.hasSuffix("/qa")

        // Strip /qa suffix if present, append /crawlable
        var path = originalPath
        if isBeta {
            path = String(path.dropLast(3))
        }
        if !path.hasSuffix("/crawlable") {
            path = path.hasSuffix("/") ? "\(path)crawlable" : "\(path)/crawlable"
        }
        components?.path = path

        // Beta libraries need availability=all to include hidden/testing libraries
        if isBeta {
            var items = components?.queryItems ?? []
            items.append(URLQueryItem(name: "availability", value: "all"))
            components?.queryItems = items
        }

        return components?.url ?? baseURL.appendingPathComponent("crawlable")
    }

    // MARK: - State Persistence

    private var stateFileURL: URL {
        stateDirectory.appendingPathComponent("crawl_state_\(hash).json")
    }

    private func loadCrawlState() -> CrawlState {
        guard let data = try? Data(contentsOf: stateFileURL),
              let state = try? JSONDecoder().decode(CrawlState.self, from: data) else {
            return CrawlState()
        }
        return state
    }

    private func saveCrawlState(_ state: CrawlState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: stateFileURL)
    }

    // MARK: - Errors

    enum CrawlerError: Error, LocalizedError {
        case serializationFailed

        var errorDescription: String? {
            switch self {
            case .serializationFailed:
                return "Failed to serialize merged catalog feed"
            }
        }
    }
}

// MARK: - Array Chunking

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
