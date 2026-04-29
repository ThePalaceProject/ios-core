import XCTest
import PalaceCatalog
@testable import Palace

final class CrawlableFeedAnalysisTests: XCTestCase {

    // MARK: - Helpers

    private func makeFeed(
        facets: [OPDS2FacetGroup]? = nil,
        links: [OPDS2Link]? = nil,
        publications: [OPDS2Publication]? = nil
    ) -> OPDS2Feed {
        OPDS2Feed(
            metadata: OPDS2FeedMetadata(title: "Test Feed"),
            links: links,
            publications: publications,
            facets: facets
        )
    }

    private func makeSortFacetGroup(
        links: [OPDS2FacetLink]
    ) -> OPDS2FacetGroup {
        OPDS2FacetGroup(
            metadata: OPDS2FacetGroupMetadata(
                title: "Sort By",
                type: CrawlableFeedAnalysis.sortFacetTypeURI
            ),
            links: links
        )
    }

    private func makePublication(id: String, updated: Date?) -> OPDS2Publication {
        OPDS2Publication(
            links: [],
            metadata: OPDS2Publication.Metadata(
                updated: updated,
                description: nil,
                id: id,
                title: "Library \(id)"
            ),
            images: nil
        )
    }

    // MARK: - orderModifiedFacetURL

    func testOrderModifiedFacetURL_WhenPresent_ReturnsURL() {
        let expectedURL = "https://registry.example.com/libraries/crawlable?order=modified"
        let group = makeSortFacetGroup(links: [
            OPDS2FacetLink(href: expectedURL, title: "Most recently modified first", rel: "self"),
            OPDS2FacetLink(href: "https://registry.example.com/libraries/crawlable?order=name", title: "Name"),
        ])
        let feed = makeFeed(facets: [group])

        let result = CrawlableFeedAnalysis.orderModifiedFacetURL(from: feed)
        XCTAssertEqual(result, URL(string: expectedURL))
    }

    func testOrderModifiedFacetURL_WhenNoSortFacetGroup_ReturnsNil() {
        let group = OPDS2FacetGroup(
            metadata: OPDS2FacetGroupMetadata(
                title: "Availability",
                type: "http://palaceproject.io/terms/rel/availability"
            ),
            links: [
                OPDS2FacetLink(href: "https://example.com/?availability=production", title: "Production")
            ]
        )
        let feed = makeFeed(facets: [group])

        XCTAssertNil(CrawlableFeedAnalysis.orderModifiedFacetURL(from: feed))
    }

    func testOrderModifiedFacetURL_WhenNoFacets_ReturnsNil() {
        let feed = makeFeed(facets: nil)
        XCTAssertNil(CrawlableFeedAnalysis.orderModifiedFacetURL(from: feed))
    }

    func testOrderModifiedFacetURL_WhenSortGroupHasNoModifiedLink_ReturnsNil() {
        let group = makeSortFacetGroup(links: [
            OPDS2FacetLink(href: "https://example.com/?order=name", title: "Name"),
            OPDS2FacetLink(href: "https://example.com/?order=natural", title: "Natural"),
        ])
        let feed = makeFeed(facets: [group])

        XCTAssertNil(CrawlableFeedAnalysis.orderModifiedFacetURL(from: feed))
    }

    func testOrderModifiedFacetURL_WhenNotActive_StillReturnsURL() {
        let expectedURL = "https://registry.example.com/libraries/crawlable?order=modified"
        let group = makeSortFacetGroup(links: [
            OPDS2FacetLink(href: expectedURL, title: "Modified"), // no rel="self"
            OPDS2FacetLink(href: "https://example.com/?order=name", title: "Name", rel: "self"),
        ])
        let feed = makeFeed(facets: [group])

        let result = CrawlableFeedAnalysis.orderModifiedFacetURL(from: feed)
        XCTAssertEqual(result, URL(string: expectedURL))
    }

    // MARK: - isOrderModifiedActive

    func testIsOrderModifiedActive_WhenFacetHasRelSelf_ReturnsTrue() {
        let group = makeSortFacetGroup(links: [
            OPDS2FacetLink(href: "https://example.com/?order=modified", title: "Modified", rel: "self"),
            OPDS2FacetLink(href: "https://example.com/?order=name", title: "Name"),
        ])
        let feed = makeFeed(facets: [group])

        XCTAssertTrue(CrawlableFeedAnalysis.isOrderModifiedActive(in: feed))
    }

    func testIsOrderModifiedActive_WhenOtherFacetActive_ReturnsFalse() {
        let group = makeSortFacetGroup(links: [
            OPDS2FacetLink(href: "https://example.com/?order=modified", title: "Modified"),
            OPDS2FacetLink(href: "https://example.com/?order=name", title: "Name", rel: "self"),
        ])
        let feed = makeFeed(facets: [group])

        XCTAssertFalse(CrawlableFeedAnalysis.isOrderModifiedActive(in: feed))
    }

    func testIsOrderModifiedActive_WhenNoFacets_ReturnsFalse() {
        let feed = makeFeed(facets: nil)
        XCTAssertFalse(CrawlableFeedAnalysis.isOrderModifiedActive(in: feed))
    }

    // MARK: - isFullCrawlComplete

    func testIsFullCrawlComplete_WhenNoNextLink_ReturnsTrue() {
        let feed = makeFeed(links: [
            OPDS2Link(href: "https://example.com/?offset=0", rel: "self"),
            OPDS2Link(href: "https://example.com/?offset=0", rel: "first"),
        ])

        XCTAssertTrue(CrawlableFeedAnalysis.isFullCrawlComplete(feed))
    }

    func testIsFullCrawlComplete_WhenHasNextLink_ReturnsFalse() {
        let feed = makeFeed(links: [
            OPDS2Link(href: "https://example.com/?offset=0", rel: "self"),
            OPDS2Link(href: "https://example.com/?offset=100", rel: "next"),
        ])

        XCTAssertFalse(CrawlableFeedAnalysis.isFullCrawlComplete(feed))
    }

    func testIsFullCrawlComplete_WhenNoLinks_ReturnsTrue() {
        let feed = makeFeed(links: nil)
        XCTAssertTrue(CrawlableFeedAnalysis.isFullCrawlComplete(feed))
    }

    // MARK: - shouldStopIncrementalCrawl

    func testShouldStopIncremental_WhenPublicationOlderThanLastCrawl_ReturnsTrue() {
        let lastCrawl = Date(timeIntervalSince1970: 1700000000)
        let publications = [
            makePublication(id: "lib-1", updated: Date(timeIntervalSince1970: 1700000100)),
            makePublication(id: "lib-2", updated: Date(timeIntervalSince1970: 1699999900)), // older
        ]

        XCTAssertTrue(
            CrawlableFeedAnalysis.shouldStopIncrementalCrawl(
                publications: publications,
                lastCrawlDate: lastCrawl
            )
        )
    }

    func testShouldStopIncremental_WhenPublicationExactlyAtLastCrawl_ReturnsTrue() {
        let lastCrawl = Date(timeIntervalSince1970: 1700000000)
        let publications = [
            makePublication(id: "lib-1", updated: lastCrawl),
        ]

        XCTAssertTrue(
            CrawlableFeedAnalysis.shouldStopIncrementalCrawl(
                publications: publications,
                lastCrawlDate: lastCrawl
            )
        )
    }

    func testShouldStopIncremental_WhenAllPublicationsNewer_ReturnsFalse() {
        let lastCrawl = Date(timeIntervalSince1970: 1700000000)
        let publications = [
            makePublication(id: "lib-1", updated: Date(timeIntervalSince1970: 1700000100)),
            makePublication(id: "lib-2", updated: Date(timeIntervalSince1970: 1700000200)),
        ]

        XCTAssertFalse(
            CrawlableFeedAnalysis.shouldStopIncrementalCrawl(
                publications: publications,
                lastCrawlDate: lastCrawl
            )
        )
    }

    func testShouldStopIncremental_WhenPublicationHasNoUpdatedDate_ReturnsFalse() {
        let lastCrawl = Date(timeIntervalSince1970: 1700000000)
        let publications = [
            makePublication(id: "lib-1", updated: nil),
        ]

        XCTAssertFalse(
            CrawlableFeedAnalysis.shouldStopIncrementalCrawl(
                publications: publications,
                lastCrawlDate: lastCrawl
            )
        )
    }

    func testShouldStopIncremental_WhenEmptyPublications_ReturnsFalse() {
        let lastCrawl = Date(timeIntervalSince1970: 1700000000)

        XCTAssertFalse(
            CrawlableFeedAnalysis.shouldStopIncrementalCrawl(
                publications: [],
                lastCrawlDate: lastCrawl
            )
        )
    }

    // MARK: - publicationsNewerThan

    func testPublicationsNewerThan_FiltersCorrectly() {
        let lastCrawl = Date(timeIntervalSince1970: 1700000000)
        let publications = [
            makePublication(id: "new-1", updated: Date(timeIntervalSince1970: 1700000100)),
            makePublication(id: "old-1", updated: Date(timeIntervalSince1970: 1699999900)),
            makePublication(id: "exact", updated: lastCrawl),
            makePublication(id: "new-2", updated: Date(timeIntervalSince1970: 1700000200)),
            makePublication(id: "no-date", updated: nil),
        ]

        let newer = CrawlableFeedAnalysis.publicationsNewerThan(
            lastCrawlDate: lastCrawl,
            in: publications
        )

        let ids = newer.map(\.metadata.id)
        XCTAssertEqual(ids, ["new-1", "new-2", "no-date"])
    }
}
