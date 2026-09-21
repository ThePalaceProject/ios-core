//
//  CrawlerCompletenessTests.swift
//  PalaceTests
//
//  PP-5191, crawler side. Three rules, each of which fails silently — in the
//  QUIET direction — if it regresses:
//
//    A-4  `numberOfItems` is never carried forward from cache. On the
//         deletion-reconcile path `feedMetadata` IS the cached feed's metadata,
//         so inheriting it republishes a stale total: a genuine 1457 -> 1400
//         shrink emits 1400 against a declared 1457, reads PARTIAL, and is
//         refused forever. Deletions never reconcile, and it renders as "there
//         were no deletions".
//
//    V-2  A parallel crawl derives its page offsets from the server's declared
//         total. If the server under-reports it, too few offsets are computed,
//         nothing throws, and a short list would be published as an
//         authoritative full crawl under a "pagination complete" log.
//
//    B-6  A partial merge must force the next crawl to be full, or bundled rows
//         become sticky for the 7-day interval — but it must NOT preserve the
//         discovered facet URL's loss, nor fire when the registry is complete.
//

import XCTest
import PalaceCatalog
@testable import Palace

final class CrawlerCompletenessTests: XCTestCase {

    private var stateDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pp5191_crawl_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: stateDir)
        try super.tearDownWithError()
    }

    private func publication(_ id: String) -> OPDS2Publication {
        OPDS2Publication(links: [], metadata: .init(id: id, title: "Library \(id)"), images: nil)
    }

    private func pageData(ids: [String], declaring: Int?) throws -> Data {
        try XCTUnwrap(LibraryCatalogMerger.serializeAsCatalogsFeed(
            publications: ids.map(publication),
            metadata: .init(adobe_vendor_id: "v", title: "Libraries", numberOfItems: declaring)
        ))
    }

    private func crawler(_ fetcher: CrawlerNetworkFetching) -> LibraryRegistryCrawler {
        LibraryRegistryCrawler(fetcher: fetcher, hash: "h", stateDirectory: stateDir, currentAppVersion: nil)
    }

    private func crawlState() throws -> CrawlState {
        let url = stateDir.appendingPathComponent("crawl_state_h.json")
        return try JSONDecoder().decode(CrawlState.self, from: Data(contentsOf: url))
    }

    // MARK: - A-4: the declared total comes from the response, never the cache

    func testCrawl_emitsTheFreshlyFetchedTotal_notTheCachedOne() async throws {
        // The registry has genuinely SHRUNK: the live response says 2, while the
        // cached metadata still claims 3. Inheriting the cached 3 would mark the
        // result PARTIAL and see the deletion refused downstream, forever.
        let live = try pageData(ids: ["a", "b"], declaring: 2)
        let result = await crawler(SinglePageFetcher(data: live)).crawl(
            baseURL: URL(string: "https://registry.example.com/libraries")!,
            existingPublications: [publication("a"), publication("b"), publication("gone")],
            feedMetadata: .init(adobe_vendor_id: "v", title: "Libraries", numberOfItems: 3)
        )

        guard case .success(let data) = result else {
            return XCTFail("expected a successful crawl, got \(result)")
        }
        let feed = try OPDS2CatalogsFeed.fromData(data)
        XCTAssertEqual(feed.metadata.numberOfItems, 2,
                       "The declared total must come from the response just fetched. Carrying the cached 3 forward makes a legitimate deletion look like a truncated feed.")
        XCTAssertFalse(LibraryCatalogMerger.feedIsPartial(feed),
                       "…and so the shrunken-but-whole registry must read COMPLETE, or the deletion can never be applied")
    }

    // MARK: - V-2: a crawl short of its declared total is not a full crawl

    func testCrawlRemainingPages_whenPaginationEndsShortOfTheDeclaredTotal_doesNotRecordAFullCrawl() async throws {
        // Declares 500 but the feed ends after page 1's 2 entries and one more page.
        let firstPageRaw = try pageData(ids: ["a", "b"], declaring: 500)
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: firstPageRaw) as? [String: Any])
        root["links"] = [["rel": "next", "href": "https://registry.example.com/libraries/crawlable?offset=2&size=2", "type": "application/opds+json"]]
        let firstPage = try OPDS2CatalogsFeed.fromData(try JSONSerialization.data(withJSONObject: root))

        let secondPage = try pageData(ids: ["c"], declaring: 500)
        let result = await crawler(SinglePageFetcher(data: secondPage)).crawlRemainingPages(
            firstPage: firstPage,
            baseURL: URL(string: "https://registry.example.com/libraries")!,
            existingPublications: [publication("resident-1"), publication("resident-2")],
            feedMetadata: nil
        )

        guard case .success(let data) = result else { return XCTFail("expected success, got \(result)") }

        // Concern 5: `lastFullCrawlDate` alone does not pin the half that DELETES.
        // With `isFullCrawl: true` the merge returns only the updates and the two
        // resident libraries are dropped; with `reachedDeclaredTotal` (false here)
        // they are preserved. Assert the libraries, not just the timestamp.
        let feed = try OPDS2CatalogsFeed.fromData(data)
        let ids = Set(feed.catalogs.map(\.metadata.id))
        XCTAssertTrue(ids.isSuperset(of: ["resident-1", "resident-2"]),
                      "A crawl that ended short of its declared total must not be treated as a full crawl — full-crawl mode returns ONLY the updates, deleting every library the short walk did not happen to see.")

        let state = try crawlState()
        XCTAssertNil(state.lastFullCrawlDate,
                     "3 of a declared 500 is not a full crawl. Stamping it would publish a short list as authoritative and suppress the next real full crawl for 7 days.")
        XCTAssertNotNil(state.lastSuccessfulCrawlDate,
                        "it WAS a successful crawl — just not a complete one")
    }

    // MARK: - The declared total must SURVIVE serialization

    /// Concern 3: dropping `numberOfItems` at the crawlFirstPage serialize site is
    /// invisible to every other test — `displayIsPartial` simply goes false,
    /// `requireFullCrawlOnNextRun()` silently stops firing, and the registry quietly
    /// reverts to the pre-fix behaviour. Assert the field survives the round trip.
    func testCrawlFirstPage_carriesTheDeclaredTotalThroughSerialization() async throws {
        let page = try pageData(ids: ["a", "b"], declaring: 1457)
        let result = await crawler(SinglePageFetcher(data: page)).crawlFirstPage(
            baseURL: URL(string: "https://registry.example.com/libraries")!
        )
        guard case .success(let data, _) = result else {
            return XCTFail("expected a first-page success, got \(result)")
        }
        let feed = try OPDS2CatalogsFeed.fromData(data)
        XCTAssertEqual(feed.metadata.numberOfItems, 1457,
                       "Without the declared total on the serialized page, a 2-row feed is indistinguishable from the whole registry and every completeness check downstream disarms.")
        XCTAssertTrue(LibraryCatalogMerger.feedIsPartial(feed))
    }

    // MARK: - B-6: requireFullCrawlOnNextRun

    func testRequireFullCrawlOnNextRun_clearsCompletionMarkers_butKeepsTheDiscoveredFacetURL() throws {
        let facet = URL(string: "https://registry.example.com/libraries/crawlable?order=modified")!
        let seeded = CrawlState(
            lastSuccessfulCrawlDate: Date(),
            orderModifiedFacetURL: facet,
            lastFullCrawlDate: Date(),
            lastCrawlAppVersion: "3.3.0",
            serverMaxAge: 43_200
        )
        try JSONEncoder().encode(seeded).write(to: stateDir.appendingPathComponent("crawl_state_h.json"))

        crawler(SinglePageFetcher(data: Data())).requireFullCrawlOnNextRun()

        let state = try crawlState()
        XCTAssertNil(state.lastSuccessfulCrawlDate)
        XCTAssertNil(state.lastFullCrawlDate)
        XCTAssertTrue(state.needsFullCrawl(currentAppVersion: nil, now: Date()),
                      "the whole point: the NEXT crawl must take the full branch")
        XCTAssertEqual(state.orderModifiedFacetURL, facet,
                       "the facet URL is a discovered capability of the feed, not a record of work done — dropping it costs an extra round trip on every reset")
        XCTAssertEqual(state.serverMaxAge, 43_200,
                       "the server's cache policy is likewise not work-done state")
    }
}

// MARK: - Test doubles

/// Serves the same bytes for any URL, with no pagination links, so a crawl
/// terminates after one page.
private final class SinglePageFetcher: CrawlerNetworkFetching, @unchecked Sendable {
    private let data: Data
    init(data: Data) { self.data = data }
    func fetchData(from url: URL) async throws -> (Data, HTTPURLResponse?) { (data, nil) }
}
