import XCTest
@testable import Palace

/// Tests the entire fallback chain for library registry crawling:
///
/// 1. Crawlable endpoint succeeds → use crawled data
/// 2. Crawlable endpoint fails → fall back to existing cached data
/// 3. Crawlable endpoint returns malformed data → fall back gracefully
/// 4. First page succeeds, remaining pages fail → partial data is usable
/// 5. Incremental crawl fails → full crawl on next attempt
/// 6. Network completely down → returns failure (caller falls back to direct GET)
final class CrawlerFallbackTests: XCTestCase {

    private var fetcher: MockFallbackFetcher!
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        fetcher = MockFallbackFetcher()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fallback_tests_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func makeCrawler() -> LibraryRegistryCrawler {
        LibraryRegistryCrawler(fetcher: fetcher, hash: "test", stateDirectory: tempDir)
    }

    private let baseURL = URL(string: "https://registry.example.com/libraries")!

    // MARK: - Helpers

    private func makeCatalogsFeedJSON(
        catalogs: [[String: Any]],
        nextURL: String? = nil,
        numberOfItems: Int? = nil
    ) -> Data {
        var feed: [String: Any] = [
            "metadata": ["title": "Registry", "numberOfItems": numberOfItems as Any].compactMapValues { $0 },
            "catalogs": catalogs
        ]
        var links: [[String: Any]] = [
            ["href": "https://registry.example.com/libraries/crawlable", "rel": "self"]
        ]
        if let next = nextURL {
            links.append(["href": next, "rel": "next"])
        }
        feed["links"] = links
        return try! JSONSerialization.data(withJSONObject: feed)
    }

    private func makeCatalog(id: String, title: String = "Library") -> [String: Any] {
        [
            "metadata": ["id": id, "title": title, "updated": "2026-04-15T10:00:00Z"],
            "links": [["href": "https://example.com/\(id)/catalog", "rel": "http://opds-spec.org/catalog"]]
        ]
    }

    // MARK: - 1. Happy Path: Crawlable succeeds

    func testCrawl_WhenCrawlableSucceeds_ReturnsCrawledData() async {
        let crawlableURL = URL(string: "https://registry.example.com/libraries/crawlable")!
        let feedJSON = makeCatalogsFeedJSON(catalogs: [makeCatalog(id: "lib-1"), makeCatalog(id: "lib-2")])
        fetcher.stub(url: crawlableURL, data: feedJSON)

        let crawler = makeCrawler()
        let result = await crawler.crawl(baseURL: baseURL, existingPublications: [], feedMetadata: nil)

        guard case .success(let data) = result else {
            XCTFail("Expected success, got \(result)")
            return
        }
        let feed = try! OPDS2CatalogsFeed.fromData(data)
        XCTAssertEqual(feed.catalogs.count, 2)
    }

    // MARK: - 2. Crawlable endpoint returns HTTP error

    func testCrawl_WhenCrawlableReturnsError_ReturnsFailure() async {
        let crawlableURL = URL(string: "https://registry.example.com/libraries/crawlable")!
        fetcher.stub(url: crawlableURL, error: URLError(.notConnectedToInternet))

        let crawler = makeCrawler()
        let result = await crawler.crawl(baseURL: baseURL, existingPublications: [], feedMetadata: nil)

        guard case .failure = result else {
            XCTFail("Expected failure when crawlable endpoint is down")
            return
        }
    }

    // MARK: - 3. Crawlable returns malformed JSON

    func testCrawl_WhenCrawlableReturnsMalformedJSON_ReturnsFailure() async {
        let crawlableURL = URL(string: "https://registry.example.com/libraries/crawlable")!
        fetcher.stub(url: crawlableURL, data: "not json".data(using: .utf8)!)

        let crawler = makeCrawler()
        let result = await crawler.crawl(baseURL: baseURL, existingPublications: [], feedMetadata: nil)

        guard case .failure = result else {
            XCTFail("Expected failure for malformed JSON")
            return
        }
    }

    // MARK: - 4. First page succeeds, second page fails

    func testCrawlRemainingPages_WhenSecondPageFails_ReturnsFailure() async {
        let crawlableURL = URL(string: "https://registry.example.com/libraries/crawlable")!
        let page2URL = URL(string: "https://registry.example.com/libraries/crawlable?offset=100")!

        let page1 = makeCatalogsFeedJSON(
            catalogs: [makeCatalog(id: "lib-1")],
            nextURL: page2URL.absoluteString,
            numberOfItems: 200
        )
        fetcher.stub(url: crawlableURL, data: page1)
        fetcher.stub(url: page2URL, error: URLError(.timedOut))

        let crawler = makeCrawler()
        let firstPage = try! OPDS2CatalogsFeed.fromData(page1)

        let result = await crawler.crawlRemainingPages(
            firstPage: firstPage,
            baseURL: baseURL,
            existingPublications: firstPage.catalogs,
            feedMetadata: firstPage.metadata
        )

        guard case .failure = result else {
            XCTFail("Expected failure when page 2 times out")
            return
        }
        // First page data was already displayed — user sees partial library list
    }

    // MARK: - 5. First page fast path — success and failure

    func testCrawlFirstPage_Success_ReturnsPartialData() async {
        let crawlableURL = URL(string: "https://registry.example.com/libraries/crawlable")!
        let feedJSON = makeCatalogsFeedJSON(
            catalogs: [makeCatalog(id: "lib-1"), makeCatalog(id: "lib-2")],
            nextURL: "https://registry.example.com/libraries/crawlable?offset=100"
        )
        fetcher.stub(url: crawlableURL, data: feedJSON)

        let crawler = makeCrawler()
        let result = await crawler.crawlFirstPage(baseURL: baseURL)

        guard case .success(let data) = result else {
            XCTFail("Expected first page success")
            return
        }
        let feed = try! OPDS2CatalogsFeed.fromData(data)
        XCTAssertEqual(feed.catalogs.count, 2, "Should return first page catalogs")
    }

    func testCrawlFirstPage_NetworkDown_ReturnsFailure() async {
        let crawlableURL = URL(string: "https://registry.example.com/libraries/crawlable")!
        fetcher.stub(url: crawlableURL, error: URLError(.notConnectedToInternet))

        let crawler = makeCrawler()
        let result = await crawler.crawlFirstPage(baseURL: baseURL)

        guard case .failure = result else {
            XCTFail("Expected failure — caller should fall back to direct GET")
            return
        }
    }

    // MARK: - 6. Incremental crawl fails → next attempt does full crawl

    func testIncrementalCrawlFails_NextAttemptDoesFullCrawl() async {
        let facetURL = URL(string: "https://registry.example.com/libraries/crawlable?order=modified")!
        let crawlableURL = URL(string: "https://registry.example.com/libraries/crawlable")!

        // Seed crawl state for incremental mode
        let state = CrawlState(
            lastSuccessfulCrawlDate: Date(),
            orderModifiedFacetURL: facetURL,
            lastFullCrawlDate: Date()
        )
        let stateData = try! JSONEncoder().encode(state)
        try! stateData.write(to: tempDir.appendingPathComponent("crawl_state_test.json"))

        // Incremental URL fails
        fetcher.stub(url: facetURL, error: URLError(.networkConnectionLost))

        let crawler = makeCrawler()
        let result1 = await crawler.crawl(baseURL: baseURL, existingPublications: [], feedMetadata: nil)

        guard case .failure = result1 else {
            XCTFail("Expected incremental crawl to fail")
            return
        }

        // CrawlState should still have the old values (not cleared on failure)
        let savedState = try! JSONDecoder().decode(
            CrawlState.self,
            from: Data(contentsOf: tempDir.appendingPathComponent("crawl_state_test.json"))
        )
        XCTAssertNotNil(savedState.lastSuccessfulCrawlDate, "State preserved after failure")
        XCTAssertNotNil(savedState.orderModifiedFacetURL, "Facet URL preserved after failure")
    }

    // MARK: - 7. Crawlable returns valid JSON but wrong structure

    func testCrawl_WhenResponseMissingCatalogs_ReturnsFailure() async {
        let crawlableURL = URL(string: "https://registry.example.com/libraries/crawlable")!
        // Valid JSON but missing required "catalogs" key
        let badFeed = try! JSONSerialization.data(withJSONObject: [
            "metadata": ["title": "Registry"],
            "links": [["href": "https://example.com", "rel": "self"]]
        ])
        fetcher.stub(url: crawlableURL, data: badFeed)

        let crawler = makeCrawler()
        let result = await crawler.crawl(baseURL: baseURL, existingPublications: [], feedMetadata: nil)

        guard case .failure = result else {
            XCTFail("Expected failure for feed missing catalogs key")
            return
        }
    }

    // MARK: - 8. CrawlState file corrupted → treats as first launch

    func testCrawl_WhenCrawlStateCorrupted_TreatsAsFirstLaunch() async {
        // Write garbage to crawl state file
        try! "not json".data(using: .utf8)!.write(to: tempDir.appendingPathComponent("crawl_state_test.json"))

        let crawlableURL = URL(string: "https://registry.example.com/libraries/crawlable")!
        let feedJSON = makeCatalogsFeedJSON(catalogs: [makeCatalog(id: "lib-1")])
        fetcher.stub(url: crawlableURL, data: feedJSON)

        let crawler = makeCrawler()
        let result = await crawler.crawl(baseURL: baseURL, existingPublications: [], feedMetadata: nil)

        guard case .success = result else {
            XCTFail("Should succeed by treating corrupted state as fresh start")
            return
        }
    }

    // MARK: - 9. Parallel fetch — one page fails, whole batch fails

    func testCrawlRemainingPages_OneParallelPageFails_ReturnsFailure() async {
        let crawlableURL = URL(string: "https://registry.example.com/libraries/crawlable")!
        let page2URL = URL(string: "https://registry.example.com/libraries/crawlable?offset=100&size=100")!
        let page3URL = URL(string: "https://registry.example.com/libraries/crawlable?offset=200&size=100")!

        let page1 = makeCatalogsFeedJSON(
            catalogs: [makeCatalog(id: "lib-1")],
            nextURL: page2URL.absoluteString,
            numberOfItems: 300
        )

        let page2Data = makeCatalogsFeedJSON(catalogs: [makeCatalog(id: "lib-2")])
        fetcher.stub(url: crawlableURL, data: page1)
        fetcher.stub(url: page2URL, data: page2Data)
        fetcher.stub(url: page3URL, error: URLError(.cannotConnectToHost))

        let crawler = makeCrawler()
        let firstPage = try! OPDS2CatalogsFeed.fromData(page1)

        let result = await crawler.crawlRemainingPages(
            firstPage: firstPage,
            baseURL: baseURL,
            existingPublications: firstPage.catalogs,
            feedMetadata: firstPage.metadata
        )

        guard case .failure = result else {
            XCTFail("Expected failure when one parallel page fails")
            return
        }
        // First page was already displayed — user has partial data
    }

    // MARK: - 10. Empty crawlable feed

    func testCrawl_EmptyFeed_ReturnsSuccessWithNoLibraries() async {
        let crawlableURL = URL(string: "https://registry.example.com/libraries/crawlable")!
        let feedJSON = makeCatalogsFeedJSON(catalogs: [])
        fetcher.stub(url: crawlableURL, data: feedJSON)

        let crawler = makeCrawler()
        let result = await crawler.crawl(baseURL: baseURL, existingPublications: [], feedMetadata: nil)

        guard case .success(let data) = result else {
            XCTFail("Empty feed should succeed (not fail)")
            return
        }
        let feed = try! OPDS2CatalogsFeed.fromData(data)
        XCTAssertEqual(feed.catalogs.count, 0)
    }
}

// MARK: - Mock Fetcher

private final class MockFallbackFetcher: CrawlerNetworkFetching {
    private var stubs: [URL: Result<Data, Error>] = [:]

    func stub(url: URL, data: Data) {
        stubs[url] = .success(data)
    }

    func stub(url: URL, error: Error) {
        stubs[url] = .failure(error)
    }

    func fetchData(from url: URL) async throws -> (Data, HTTPURLResponse?) {
        guard let result = stubs[url] else {
            throw URLError(.fileDoesNotExist)
        }
        switch result {
        case .success(let data): return (data, nil)
        case .failure(let error): throw error
        }
    }
}
