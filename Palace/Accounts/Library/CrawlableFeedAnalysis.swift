import Foundation

/// Utilities for analyzing crawlable OPDS 2.0 feeds to determine
/// crawl strategy (incremental vs full) and pagination stop conditions.
enum CrawlableFeedAnalysis {

    /// Type URI for the sort facet group in Palace Library Registry feeds.
    static let sortFacetTypeURI = "http://palaceproject.io/terms/rel/sort"

    /// Titles that identify the "modified" sort facet link.
    /// Case-insensitive matching is done via lowercased comparison.
    private static let modifiedFacetKeywords: [String] = [
        "modified", "most recently modified"
    ]

    private static func isModifiedFacet(_ title: String) -> Bool {
        let lower = title.lowercased()
        return modifiedFacetKeywords.contains { lower.contains($0) }
    }

    // MARK: - Facet Detection

    /// Finds the URL for the `order=modified` sort facet in the feed.
    static func orderModifiedFacetURL(from feed: OPDS2Feed) -> URL? {
        orderModifiedFacetURL(fromFacets: feed.facets)
    }

    /// Finds the URL for the `order=modified` sort facet in a catalogs feed.
    static func orderModifiedFacetURL(from feed: OPDS2CatalogsFeed) -> URL? {
        orderModifiedFacetURL(fromFacets: feed.facets)
    }

    /// Returns `true` if the `order=modified` facet is the currently
    /// active sort in the feed (its link has `rel="self"`).
    static func isOrderModifiedActive(in feed: OPDS2Feed) -> Bool {
        isOrderModifiedActive(inFacets: feed.facets)
    }

    /// Returns `true` if the `order=modified` facet is active in a catalogs feed.
    static func isOrderModifiedActive(in feed: OPDS2CatalogsFeed) -> Bool {
        isOrderModifiedActive(inFacets: feed.facets)
    }

    // MARK: - Pagination

    /// Returns `true` if the feed has no `rel="next"` link.
    static func isFullCrawlComplete(_ feed: OPDS2Feed) -> Bool {
        feed.nextPageURL == nil
    }

    /// Returns `true` if the catalogs feed has no `rel="next"` link.
    static func isFullCrawlComplete(_ feed: OPDS2CatalogsFeed) -> Bool {
        feed.nextPageURL == nil
    }

    // MARK: - Incremental Stop Condition

    /// Returns `true` if any publication in the list has an `updated`
    /// date at or before `lastCrawlDate`.
    static func shouldStopIncrementalCrawl(
        publications: [OPDS2Publication],
        lastCrawlDate: Date
    ) -> Bool {
        publications.contains { pub in
            guard let updated = pub.metadata.updated else { return false }
            return updated <= lastCrawlDate
        }
    }

    /// Filters publications to only those newer than `lastCrawlDate`.
    /// Publications without an `updated` date are included (assumed new).
    static func publicationsNewerThan(
        lastCrawlDate: Date,
        in publications: [OPDS2Publication]
    ) -> [OPDS2Publication] {
        publications.filter { pub in
            guard let updated = pub.metadata.updated else { return true }
            return updated > lastCrawlDate
        }
    }

    // MARK: - Private Helpers

    private static func orderModifiedFacetURL(fromFacets facets: [OPDS2FacetGroup]?) -> URL? {
        guard let sortGroup = facets?.first(where: {
            $0.metadata.type == sortFacetTypeURI
        }) else {
            return nil
        }

        return sortGroup.links
            .first { isModifiedFacet($0.title) }?
            .hrefURL
    }

    private static func isOrderModifiedActive(inFacets facets: [OPDS2FacetGroup]?) -> Bool {
        guard let sortGroup = facets?.first(where: {
            $0.metadata.type == sortFacetTypeURI
        }) else {
            return false
        }

        return sortGroup.links.contains {
            isModifiedFacet($0.title) && $0.rel == "self"
        }
    }
}
