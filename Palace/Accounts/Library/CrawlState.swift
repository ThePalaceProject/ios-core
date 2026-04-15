import Foundation

/// Persistent state for incremental library registry crawling.
///
/// Stored at `crawl_state_{hash}.json` alongside the catalog cache files.
/// Tracks when the last successful crawl occurred and the URL for the
/// `order=modified` facet, enabling incremental crawls that only fetch
/// recently-changed libraries.
struct CrawlState: Codable {
    /// Timestamp of the last successful crawl (incremental or full).
    /// Used as the cutoff: during incremental crawls, pagination stops
    /// when a publication's `updated` date is at or before this date.
    var lastSuccessfulCrawlDate: Date?

    /// URL for the `order=modified` sort facet discovered in the feed.
    /// If the feed doesn't expose this facet, incremental crawling is
    /// not possible and a full crawl is required.
    var orderModifiedFacetURL: URL?

    /// Timestamp of the last completed full crawl (all pages fetched,
    /// no `rel="next"` on last page). Used to decide when a fresh full
    /// crawl should be triggered even if incremental is available.
    var lastFullCrawlDate: Date?

    /// Server's Cache-Control max-age value (in seconds), if available.
    /// Used to dynamically adjust the client-side stale TTL.
    var serverMaxAge: TimeInterval?

    /// Returns `true` when incremental crawling is not possible and a
    /// full crawl must be performed. This is the case when we have never
    /// crawled before or when no `order=modified` facet URL is known.
    var needsFullCrawl: Bool {
        lastSuccessfulCrawlDate == nil || orderModifiedFacetURL == nil
    }

    init(
        lastSuccessfulCrawlDate: Date? = nil,
        orderModifiedFacetURL: URL? = nil,
        lastFullCrawlDate: Date? = nil,
        serverMaxAge: TimeInterval? = nil
    ) {
        self.lastSuccessfulCrawlDate = lastSuccessfulCrawlDate
        self.orderModifiedFacetURL = orderModifiedFacetURL
        self.lastFullCrawlDate = lastFullCrawlDate
        self.serverMaxAge = serverMaxAge
    }
}
