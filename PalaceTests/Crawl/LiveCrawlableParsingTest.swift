import XCTest
@testable import Palace

/// Integration test that fetches the live crawlable endpoint and verifies parsing.
/// Requires network access — skipped in CI (set SKIP_NETWORK_TESTS=1 to skip).
final class LiveCrawlableParsingTest: XCTestCase {

    override func setUpWithError() throws {
        try super.setUpWithError()
        if ProcessInfo.processInfo.environment["SKIP_NETWORK_TESTS"] == "1" {
            throw XCTSkip("Skipping network-dependent test in CI")
        }
    }

    func testParseLiveCrawlableFeed() async throws {
        let url = URL(string: "https://registry.palaceproject.io/libraries/crawlable?size=20")!
        let (data, _) = try await URLSession.shared.data(from: url)

        // Verify it parses with our decoder
        let feed = try OPDS2CatalogsFeed.fromData(data)

        XCTAssertGreaterThan(feed.catalogs.count, 0, "Should have catalogs")
        XCTAssertFalse(feed.links.isEmpty, "Should have links")

        // Check next page URL
        let nextURL = feed.nextPageURL
        XCTAssertNotNil(nextURL, "Should have a next page link for paginated feed")

        // Check facets
        XCTAssertNotNil(feed.facets, "Should have facets")

        // Check sort facet detection
        let modifiedURL = CrawlableFeedAnalysis.orderModifiedFacetURL(from: feed)
        XCTAssertNotNil(modifiedURL, "Should find the order=modified facet URL")

        let isActive = CrawlableFeedAnalysis.isOrderModifiedActive(in: feed)
        XCTAssertTrue(isActive, "order=modified should be the default active sort")

        // Check first catalog has expected fields
        let first = feed.catalogs[0]
        XCTAssertFalse(first.metadata.id.isEmpty)
        XCTAssertFalse(first.metadata.title.isEmpty)
    }

    func testCrawlableURL_FromBetaURL() {
        let beta = URL(string: "https://registry.palaceproject.io/libraries/qa")!
        let crawlable = LibraryRegistryCrawler.crawlableURL(from: beta)
        XCTAssertEqual(crawlable.path, "/libraries/crawlable")
        XCTAssertTrue(
            crawlable.absoluteString.contains("availability=all"),
            "Beta URL should include availability=all, got: \(crawlable)"
        )
    }

    func testCrawlableURL_FromProdURL() {
        let prod = URL(string: "https://registry.palaceproject.io/libraries")!
        let crawlable = LibraryRegistryCrawler.crawlableURL(from: prod)
        XCTAssertEqual(crawlable.absoluteString, "https://registry.palaceproject.io/libraries/crawlable")
    }

    /// End-to-end: crawl the live registry with a real network call
    func testFullCrawl_LiveEndpoint() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("live_crawl_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Use a direct URLSession fetcher (not TPPNetworkExecutor)
        let fetcher = DirectURLSessionFetcher()
        let crawler = LibraryRegistryCrawler(
            fetcher: fetcher,
            hash: "live_test",
            stateDirectory: tempDir
        )

        let baseURL = URL(string: "https://registry.palaceproject.io/libraries")!
        let result = await crawler.crawl(
            baseURL: baseURL,
            existingPublications: [],
            feedMetadata: nil
        )

        switch result {
        case .success(let data):
            let feed = try OPDS2CatalogsFeed.fromData(data)
            XCTAssertGreaterThan(feed.catalogs.count, 100, "Full crawl should fetch all libraries (>100)")

            // Verify crawl state was saved
            let stateURL = tempDir.appendingPathComponent("crawl_state_live_test.json")
            let stateData = try Data(contentsOf: stateURL)
            let state = try JSONDecoder().decode(CrawlState.self, from: stateData)
            XCTAssertNotNil(state.lastSuccessfulCrawlDate)
            XCTAssertNotNil(state.orderModifiedFacetURL)
            XCTAssertNotNil(state.lastFullCrawlDate, "Full crawl should set lastFullCrawlDate")

        case .noChanges:
            XCTFail("First crawl should not return noChanges")
        case .failure(let error):
            XCTFail("Live crawl failed: \(error)")
        }
    }
}

/// Simple fetcher using URLSession directly — avoids TPPNetworkExecutor complexity
private struct DirectURLSessionFetcher: CrawlerNetworkFetching {
    func fetchData(from url: URL) async throws -> (Data, HTTPURLResponse?) {
        let (data, response) = try await URLSession.shared.data(from: url)
        return (data, response as? HTTPURLResponse)
    }
}
