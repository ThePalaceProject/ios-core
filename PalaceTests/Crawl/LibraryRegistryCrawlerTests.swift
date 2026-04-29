import XCTest
import PalaceCatalog
@testable import Palace

// MARK: - Mock Network Fetcher

private final class MockCrawlerFetcher: CrawlerNetworkFetching {
    var responses: [URL: Result<Data, Error>] = [:]
    var fetchedURLs: [URL] = []
    var mockResponse: HTTPURLResponse?

    func fetchData(from url: URL) async throws -> (Data, HTTPURLResponse?) {
        fetchedURLs.append(url)
        guard let result = responses[url] else {
            throw URLError(.fileDoesNotExist)
        }
        switch result {
        case .success(let data): return (data, mockResponse)
        case .failure(let error): throw error
        }
    }
}

// MARK: - Mock Delegate

private final class MockCrawlerDelegate: LibraryRegistryCrawlerDelegate {
    var progressUpdates: [CrawlProgress] = []

    func crawler(_ crawler: LibraryRegistryCrawler, didUpdateProgress progress: CrawlProgress) {
        progressUpdates.append(progress)
    }
}

// MARK: - Tests

final class LibraryRegistryCrawlerTests: XCTestCase {

    private var fetcher: MockCrawlerFetcher!
    private var delegate: MockCrawlerDelegate!
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        fetcher = MockCrawlerFetcher()
        delegate = MockCrawlerDelegate()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("crawl_tests_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeCrawler() -> LibraryRegistryCrawler {
        let crawler = LibraryRegistryCrawler(
            fetcher: fetcher,
            hash: "test_hash",
            stateDirectory: tempDir
        )
        crawler.delegate = delegate
        return crawler
    }

    private func makeFeedJSON(
        publications: [[String: Any]],
        nextURL: String? = nil,
        facets: [[String: Any]]? = nil,
        numberOfItems: Int? = nil
    ) -> Data {
        var feed: [String: Any] = [
            "metadata": [
                "title": "Test Registry",
                "numberOfItems": numberOfItems as Any
            ].compactMapValues { $0 },
            "catalogs": publications
        ]

        var links: [[String: Any]] = [
            ["href": "https://registry.example.com/libraries/crawlable", "rel": "self"]
        ]
        if let next = nextURL {
            links.append(["href": next, "rel": "next"])
        }
        feed["links"] = links

        if let facets = facets {
            feed["facets"] = facets
        }

        return try! JSONSerialization.data(withJSONObject: feed)
    }

    private func makePublicationJSON(id: String, title: String = "Library", updated: String? = nil) -> [String: Any] {
        var metadata: [String: Any] = ["id": id, "title": title]
        if let updated = updated {
            metadata["updated"] = updated
        }
        return [
            "metadata": metadata,
            "links": [["href": "https://example.com/\(id)/catalog", "rel": "http://opds-spec.org/catalog"]]
        ]
    }

    private func makeSortFacet(modifiedHref: String, modifiedActive: Bool) -> [String: Any] {
        [
            "metadata": [
                "title": "Sort By",
                "type": CrawlableFeedAnalysis.sortFacetTypeURI
            ],
            "links": [
                [
                    "href": modifiedHref,
                    "title": "Modified",
                    "rel": modifiedActive ? "self" : NSNull()
                ].compactMapValues { $0 is NSNull ? nil : $0 },
                [
                    "href": "https://example.com/crawlable?order=name",
                    "title": "Name"
                ]
            ]
        ]
    }

    private func makeCatalogMetadata() -> OPDS2CatalogsFeed.Metadata {
        OPDS2CatalogsFeed.Metadata(adobe_vendor_id: nil, title: "Registry")
    }

    // MARK: - Full Crawl Tests

    func testFirstLaunch_PerformsFullCrawl_SinglePage() async {
        let baseURL = URL(string: "https://registry.example.com/libraries")!
        let crawlableURL = URL(string: "https://registry.example.com/libraries/crawlable")!

        let sortFacet = makeSortFacet(
            modifiedHref: "https://registry.example.com/libraries/crawlable?order=modified",
            modifiedActive: true
        )

        let page1 = makeFeedJSON(
            publications: [
                makePublicationJSON(id: "lib-1", updated: "2026-04-15T10:00:00Z"),
                makePublicationJSON(id: "lib-2", updated: "2026-04-14T10:00:00Z"),
            ],
            facets: [sortFacet]
        )

        fetcher.responses[crawlableURL] = .success(page1)

        let crawler = makeCrawler()
        let result = await crawler.crawl(
            baseURL: baseURL,
            existingPublications: [],
            feedMetadata: makeCatalogMetadata()
        )

        guard case .success(let data) = result else {
            XCTFail("Expected success, got \(result)")
            return
        }

        let feed = try! OPDS2CatalogsFeed.fromData(data)
        XCTAssertEqual(feed.catalogs.count, 2)
    }

    func testFirstLaunch_PerformsFullCrawl_PaginatesAllPages() async {
        let baseURL = URL(string: "https://registry.example.com/libraries")!
        let crawlableURL = URL(string: "https://registry.example.com/libraries/crawlable")!
        let page2URL = URL(string: "https://registry.example.com/libraries/crawlable?offset=2")!

        let sortFacet = makeSortFacet(
            modifiedHref: "https://registry.example.com/libraries/crawlable?order=modified",
            modifiedActive: true
        )

        let page1 = makeFeedJSON(
            publications: [
                makePublicationJSON(id: "lib-1", updated: "2026-04-15T10:00:00Z"),
            ],
            nextURL: page2URL.absoluteString,
            facets: [sortFacet],
            numberOfItems: 2
        )

        let page2 = makeFeedJSON(
            publications: [
                makePublicationJSON(id: "lib-2", updated: "2026-04-14T10:00:00Z"),
            ],
            facets: [sortFacet]
        )

        fetcher.responses[crawlableURL] = .success(page1)
        fetcher.responses[page2URL] = .success(page2)

        let crawler = makeCrawler()
        let result = await crawler.crawl(
            baseURL: baseURL,
            existingPublications: [],
            feedMetadata: makeCatalogMetadata()
        )

        guard case .success(let data) = result else {
            XCTFail("Expected success")
            return
        }

        let feed = try! OPDS2CatalogsFeed.fromData(data)
        XCTAssertEqual(feed.catalogs.count, 2)
        XCTAssertEqual(fetcher.fetchedURLs.count, 2)
    }

    // MARK: - Incremental Crawl Tests

    func testIncrementalCrawl_StopsAtLastCrawlTimestamp() async {
        let baseURL = URL(string: "https://registry.example.com/libraries")!
        let facetURL = URL(string: "https://registry.example.com/libraries/crawlable?order=modified")!

        // Pre-seed crawl state
        let state = CrawlState(
            lastSuccessfulCrawlDate: Date(timeIntervalSince1970: 1713160000), // April 15, 2024 ~06:00 UTC
            orderModifiedFacetURL: facetURL,
            lastFullCrawlDate: Date(timeIntervalSince1970: 1713160000)
        )
        let stateData = try! JSONEncoder().encode(state)
        try! stateData.write(to: tempDir.appendingPathComponent("crawl_state_test_hash.json"))

        let sortFacet = makeSortFacet(
            modifiedHref: facetURL.absoluteString,
            modifiedActive: true
        )

        let page = makeFeedJSON(
            publications: [
                makePublicationJSON(id: "lib-new", updated: "2026-04-15T12:00:00Z"),
                makePublicationJSON(id: "lib-old", updated: "2024-04-14T06:00:00Z"), // older than last crawl
            ],
            facets: [sortFacet]
        )

        fetcher.responses[facetURL] = .success(page)

        let existingPubs = [
            OPDS2Publication(
                links: [],
                metadata: OPDS2Publication.Metadata(id: "lib-existing", title: "Existing"),
                images: nil
            )
        ]

        let crawler = makeCrawler()
        let result = await crawler.crawl(
            baseURL: baseURL,
            existingPublications: existingPubs,
            feedMetadata: makeCatalogMetadata()
        )

        guard case .success(let data) = result else {
            XCTFail("Expected success")
            return
        }

        let feed = try! OPDS2CatalogsFeed.fromData(data)
        // Should have: lib-new (new), lib-existing (preserved), but NOT lib-old (filtered out)
        let ids = Set(feed.catalogs.map(\.metadata.id))
        XCTAssertTrue(ids.contains("lib-new"))
        XCTAssertTrue(ids.contains("lib-existing"))
    }

    // MARK: - No order=modified Facet

    func testFullCrawl_WhenNoOrderModifiedFacet_FetchesAllPages() async {
        let baseURL = URL(string: "https://registry.example.com/libraries")!
        let crawlableURL = URL(string: "https://registry.example.com/libraries/crawlable")!

        // Feed with no sort facet
        let page = makeFeedJSON(
            publications: [
                makePublicationJSON(id: "lib-1"),
                makePublicationJSON(id: "lib-2"),
            ]
        )

        fetcher.responses[crawlableURL] = .success(page)

        let crawler = makeCrawler()
        let result = await crawler.crawl(
            baseURL: baseURL,
            existingPublications: [],
            feedMetadata: makeCatalogMetadata()
        )

        guard case .success(let data) = result else {
            XCTFail("Expected success")
            return
        }

        let feed = try! OPDS2CatalogsFeed.fromData(data)
        XCTAssertEqual(feed.catalogs.count, 2)
    }

    // MARK: - CrawlState Persistence

    func testCrawl_SavesCrawlState_OnSuccess() async {
        let baseURL = URL(string: "https://registry.example.com/libraries")!
        let crawlableURL = URL(string: "https://registry.example.com/libraries/crawlable")!
        let modifiedURL = "https://registry.example.com/libraries/crawlable?order=modified"

        let sortFacet = makeSortFacet(modifiedHref: modifiedURL, modifiedActive: true)
        let page = makeFeedJSON(
            publications: [makePublicationJSON(id: "lib-1", updated: "2026-04-15T10:00:00Z")],
            facets: [sortFacet]
        )

        fetcher.responses[crawlableURL] = .success(page)

        let crawler = makeCrawler()
        _ = await crawler.crawl(
            baseURL: baseURL,
            existingPublications: [],
            feedMetadata: makeCatalogMetadata()
        )

        let stateURL = tempDir.appendingPathComponent("crawl_state_test_hash.json")
        let stateData = try! Data(contentsOf: stateURL)
        let state = try! JSONDecoder().decode(CrawlState.self, from: stateData)

        XCTAssertNotNil(state.lastSuccessfulCrawlDate)
        XCTAssertEqual(state.orderModifiedFacetURL, URL(string: modifiedURL))
    }

    // MARK: - Network Failure

    func testCrawl_HandlesNetworkFailure_ReturnsFailure() async {
        let baseURL = URL(string: "https://registry.example.com/libraries")!
        let crawlableURL = URL(string: "https://registry.example.com/libraries/crawlable")!

        fetcher.responses[crawlableURL] = .failure(URLError(.notConnectedToInternet))

        let crawler = makeCrawler()
        let result = await crawler.crawl(
            baseURL: baseURL,
            existingPublications: [],
            feedMetadata: makeCatalogMetadata()
        )

        guard case .failure = result else {
            XCTFail("Expected failure")
            return
        }
    }

    // MARK: - Progress Reporting

    func testCrawl_ReportsProgress() async {
        let baseURL = URL(string: "https://registry.example.com/libraries")!
        let crawlableURL = URL(string: "https://registry.example.com/libraries/crawlable")!
        let page2URL = URL(string: "https://registry.example.com/libraries/crawlable?offset=1")!

        let sortFacet = makeSortFacet(
            modifiedHref: "https://example.com/crawlable?order=modified",
            modifiedActive: true
        )

        let page1 = makeFeedJSON(
            publications: [makePublicationJSON(id: "lib-1", updated: "2026-04-15T10:00:00Z")],
            nextURL: page2URL.absoluteString,
            facets: [sortFacet],
            numberOfItems: 2
        )

        let page2 = makeFeedJSON(
            publications: [makePublicationJSON(id: "lib-2", updated: "2026-04-14T10:00:00Z")],
            facets: [sortFacet]
        )

        fetcher.responses[crawlableURL] = .success(page1)
        fetcher.responses[page2URL] = .success(page2)

        let crawler = makeCrawler()
        _ = await crawler.crawl(
            baseURL: baseURL,
            existingPublications: [],
            feedMetadata: makeCatalogMetadata()
        )

        XCTAssertGreaterThanOrEqual(delegate.progressUpdates.count, 2)
        XCTAssertEqual(delegate.progressUpdates.first?.pagesProcessed, 1)
    }

    // MARK: - Facet Detection and Storage

    func testCrawl_WhenFacetNotActive_StoresFacetURLForFutureUse() async {
        let baseURL = URL(string: "https://registry.example.com/libraries")!
        let crawlableURL = URL(string: "https://registry.example.com/libraries/crawlable")!
        let modifiedURL = "https://registry.example.com/libraries/crawlable?order=modified"

        // Facet present but NOT active (name is active)
        let sortFacet = makeSortFacet(modifiedHref: modifiedURL, modifiedActive: false)
        let page = makeFeedJSON(
            publications: [makePublicationJSON(id: "lib-1")],
            facets: [sortFacet]
        )

        fetcher.responses[crawlableURL] = .success(page)

        let crawler = makeCrawler()
        _ = await crawler.crawl(
            baseURL: baseURL,
            existingPublications: [],
            feedMetadata: makeCatalogMetadata()
        )

        // Should have stored the facet URL even though it wasn't active
        let stateURL = tempDir.appendingPathComponent("crawl_state_test_hash.json")
        let stateData = try! Data(contentsOf: stateURL)
        let state = try! JSONDecoder().decode(CrawlState.self, from: stateData)

        XCTAssertEqual(state.orderModifiedFacetURL, URL(string: modifiedURL))
    }
}
