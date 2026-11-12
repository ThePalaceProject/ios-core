import Foundation

/// Persistent state for incremental library registry crawling.
///
/// Stored at `crawl_state_{hash}.json` alongside the catalog cache files.
/// Tracks when the last successful crawl occurred and the URL for the
/// `order=modified` facet, enabling incremental crawls that only fetch
/// recently-changed libraries.
// PUBLIC_INTENT: LibraryRegistryCrawler (app target) reads and writes the crawl state.
public struct CrawlState: Codable, Sendable {
    /// Periodic forced full crawl interval — every 7 days the crawler
    /// performs a full crawl regardless of incremental availability so
    /// that deletions are reconciled even when the public feed does not
    /// tombstone removed libraries (PP-4259 R1 safety net).
    // PUBLIC_INTENT: LibraryRegistryCrawler (app target) reads and writes the crawl state.
    public static let periodicFullCrawlInterval: TimeInterval = 7 * 24 * 60 * 60

    /// Timestamp of the last successful crawl (incremental or full).
    /// Used as the cutoff: during incremental crawls, pagination stops
    /// when a publication's `updated` date is at or before this date.
    // PUBLIC_INTENT: LibraryRegistryCrawler (app target) reads and writes the crawl state.
    public var lastSuccessfulCrawlDate: Date?

    /// URL for the `order=modified` sort facet discovered in the feed.
    /// If the feed doesn't expose this facet, incremental crawling is
    /// not possible and a full crawl is required.
    // PUBLIC_INTENT: LibraryRegistryCrawler (app target) reads and writes the crawl state.
    public var orderModifiedFacetURL: URL?

    /// Timestamp of the last completed full crawl (all pages fetched,
    /// no `rel="next"` on last page). Used to decide when a fresh full
    /// crawl should be triggered even if incremental is available.
    // PUBLIC_INTENT: LibraryRegistryCrawler (app target) reads and writes the crawl state.
    public var lastFullCrawlDate: Date?

    /// App version (`CFBundleShortVersionString`) recorded at the last
    /// successful crawl. When the app upgrades, a full crawl is forced
    /// once so deletions accumulated over the prior version reconcile.
    // PUBLIC_INTENT: LibraryRegistryCrawler (app target) reads and writes the crawl state.
    public var lastCrawlAppVersion: String?

    /// Server's Cache-Control max-age value (in seconds), if available.
    /// Used to dynamically adjust the client-side stale TTL.
    // PUBLIC_INTENT: LibraryRegistryCrawler (app target) reads and writes the crawl state.
    public var serverMaxAge: TimeInterval?

    /// Returns `true` when incremental crawling is not possible and a
    /// full crawl must be performed. Triggers:
    ///   - Never crawled before (no `lastSuccessfulCrawlDate`)
    ///   - No `order=modified` facet URL known
    ///   - App version changed since last crawl (forced once on upgrade)
    ///   - Last full crawl was more than 7 days ago (R1 deletion safety net)
    ///   - Have a successful crawl recorded but never a "full" one
    // PUBLIC_INTENT: LibraryRegistryCrawler (app target) reads and writes the crawl state.
    public func needsFullCrawl(
        currentAppVersion: String? = nil,
        now: Date = Date()
    ) -> Bool {
        if lastSuccessfulCrawlDate == nil || orderModifiedFacetURL == nil {
            return true
        }
        if let current = currentAppVersion, lastCrawlAppVersion != current {
            return true
        }
        guard let lastFull = lastFullCrawlDate else {
            return true
        }
        if now.timeIntervalSince(lastFull) >= Self.periodicFullCrawlInterval {
            return true
        }
        return false
    }

    // PUBLIC_INTENT: LibraryRegistryCrawler (app target) reads and writes the crawl state.
    public init(
        lastSuccessfulCrawlDate: Date? = nil,
        orderModifiedFacetURL: URL? = nil,
        lastFullCrawlDate: Date? = nil,
        lastCrawlAppVersion: String? = nil,
        serverMaxAge: TimeInterval? = nil
    ) {
        self.lastSuccessfulCrawlDate = lastSuccessfulCrawlDate
        self.orderModifiedFacetURL = orderModifiedFacetURL
        self.lastFullCrawlDate = lastFullCrawlDate
        self.lastCrawlAppVersion = lastCrawlAppVersion
        self.serverMaxAge = serverMaxAge
    }
}
