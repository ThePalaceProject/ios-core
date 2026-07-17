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

// MARK: - Gated Fetcher (deterministic cancellation harness)

/// Actor gate that lets a test suspend the crawl inside its FIRST fetch,
/// cancel the surrounding Task, and only THEN release the fetch — so the
/// crawl resumes into a cancelled Task deterministically (no wall-clock races).
private actor FetchGate {
    private var startedCont: CheckedContinuation<Void, Never>?
    private var started = false
    private var releaseCont: CheckedContinuation<Void, Never>?
    private var released = false

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startedCont = $0 }
    }

    func markStarted() {
        started = true
        startedCont?.resume()
        startedCont = nil
    }

    func waitForRelease() async {
        if released { return }
        await withCheckedContinuation { releaseCont = $0 }
    }

    func release() {
        released = true
        releaseCont?.resume()
        releaseCont = nil
    }
}

/// Fetcher whose FIRST `fetchData` suspends on `gate` (signals started, then
/// awaits release). The gate uses a plain (non-cancellation-aware) continuation
/// so the crawl only stops if the crawler itself observes `Task.isCancelled` —
/// which is exactly the production behavior under test.
private final class GatedCrawlerFetcher: CrawlerNetworkFetching, @unchecked Sendable {
    var responses: [URL: Data] = [:]
    let gate = FetchGate()
    private let lock = NSLock()
    private var _fetchedURLs: [URL] = []
    private var firstCall = true

    var fetchedURLs: [URL] {
        lock.lock(); defer { lock.unlock() }
        return _fetchedURLs
    }

    func fetchData(from url: URL) async throws -> (Data, HTTPURLResponse?) {
        lock.lock()
        _fetchedURLs.append(url)
        let isFirst = firstCall
        firstCall = false
        lock.unlock()

        if isFirst {
            await gate.markStarted()
            await gate.waitForRelease()
        }

        guard let data = responses[url] else { throw URLError(.fileDoesNotExist) }
        return (data, nil)
    }
}

/// Carries the non-Sendable crawler across the `Task {}` boundary. The crawler
/// is confined to the single crawl Task; the test never touches it concurrently.
private struct CrawlerBox: @unchecked Sendable {
    let crawler: LibraryRegistryCrawler
}

/// Sendable summary of a crawl result so the crawl `Task` can return across the
/// isolation boundary under `-strict-concurrency=complete`.
private enum CrawlOutcome: Sendable, Equatable {
    case cancelledFailure
    case otherFailure(String)
    case success
    case noChanges
}

// MARK: - Tests

@MainActor
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

    private func makeCrawler(
        currentAppVersion: String? = "3.2.0",
        now: @escaping () -> Date = Date.init
    ) -> LibraryRegistryCrawler {
        let crawler = LibraryRegistryCrawler(
            fetcher: fetcher,
            hash: "test_hash",
            stateDirectory: tempDir,
            currentAppVersion: currentAppVersion,
            now: now
        )
        crawler.delegate = delegate
        return crawler
    }

    private func writeCrawlState(_ state: CrawlState) throws {
        let data = try JSONEncoder().encode(state)
        try data.write(to: tempDir.appendingPathComponent("crawl_state_test_hash.json"))
    }

    private func readCrawlState() throws -> CrawlState {
        let stateURL = tempDir.appendingPathComponent("crawl_state_test_hash.json")
        let data = try Data(contentsOf: stateURL)
        return try JSONDecoder().decode(CrawlState.self, from: data)
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

    func testIncrementalCrawl_StopsAtLastCrawlTimestamp() async throws {
        let now = Date(timeIntervalSince1970: 1713160000 + 24 * 60 * 60)
        let lastCrawl = Date(timeIntervalSince1970: 1713160000) // ~24h before `now`
        let baseURL = URL(string: "https://registry.example.com/libraries")!
        let facetURL = URL(string: "https://registry.example.com/libraries/crawlable?order=modified")!
        let page2URL = URL(string: "https://registry.example.com/libraries/crawlable?order=modified&offset=2")!

        // Pre-seed crawl state with lastFullCrawlDate within the 7-day window
        // so the periodic forced-full-crawl doesn't fire.
        try writeCrawlState(CrawlState(
            lastSuccessfulCrawlDate: lastCrawl,
            orderModifiedFacetURL: facetURL,
            lastFullCrawlDate: lastCrawl,
            lastCrawlAppVersion: "3.2.0"
        ))

        let sortFacet = makeSortFacet(
            modifiedHref: facetURL.absoluteString,
            modifiedActive: true
        )

        // Page 1 has one new entry + rel=next; the loop early-stops on page
        // contents so we never reach end-of-feed (existing entries preserved).
        let page = makeFeedJSON(
            publications: [
                makePublicationJSON(id: "lib-new", updated: "2026-04-15T12:00:00Z"),
                makePublicationJSON(id: "lib-old", updated: "2024-04-14T06:00:00Z"), // older than last crawl
            ],
            nextURL: page2URL.absoluteString,
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

        let crawler = makeCrawler(currentAppVersion: "3.2.0", now: { now })
        let result = await crawler.crawl(
            baseURL: baseURL,
            existingPublications: existingPubs,
            feedMetadata: makeCatalogMetadata()
        )

        guard case .success(let data) = result else {
            XCTFail("Expected success")
            return
        }

        let feed = try OPDS2CatalogsFeed.fromData(data)
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

    // MARK: - PP-4259: Forced full crawl on app-version change

    func testCrawl_WhenAppVersionChanged_HitsCrawlableURL_NotFacetURL() async throws {
        let baseURL = URL(string: "https://registry.example.com/libraries")!
        let crawlableURL = URL(string: "https://registry.example.com/libraries/crawlable")!
        let facetURL = URL(string: "https://registry.example.com/libraries/crawlable?order=modified")!

        // Pre-seed fresh, healthy state from a prior app version
        try writeCrawlState(CrawlState(
            lastSuccessfulCrawlDate: Date(),
            orderModifiedFacetURL: facetURL,
            lastFullCrawlDate: Date(),
            lastCrawlAppVersion: "3.1.0"
        ))

        let sortFacet = makeSortFacet(modifiedHref: facetURL.absoluteString, modifiedActive: true)
        let page = makeFeedJSON(
            publications: [makePublicationJSON(id: "lib-1", updated: "2026-04-15T10:00:00Z")],
            facets: [sortFacet]
        )
        fetcher.responses[crawlableURL] = .success(page)

        let crawler = makeCrawler(currentAppVersion: "3.2.0")
        _ = await crawler.crawl(
            baseURL: baseURL,
            existingPublications: [],
            feedMetadata: makeCatalogMetadata()
        )

        XCTAssertEqual(fetcher.fetchedURLs, [crawlableURL],
                       "Version upgrade must bypass the order=modified facet URL")
    }

    func testCrawl_PersistsCurrentAppVersion() async throws {
        let baseURL = URL(string: "https://registry.example.com/libraries")!
        let crawlableURL = URL(string: "https://registry.example.com/libraries/crawlable")!

        let sortFacet = makeSortFacet(
            modifiedHref: "https://example.com/crawlable?order=modified",
            modifiedActive: true
        )
        let page = makeFeedJSON(
            publications: [makePublicationJSON(id: "lib-1", updated: "2026-04-15T10:00:00Z")],
            facets: [sortFacet]
        )
        fetcher.responses[crawlableURL] = .success(page)

        let crawler = makeCrawler(currentAppVersion: "3.3.0")
        _ = await crawler.crawl(
            baseURL: baseURL,
            existingPublications: [],
            feedMetadata: makeCatalogMetadata()
        )

        let state = try readCrawlState()
        XCTAssertEqual(state.lastCrawlAppVersion, "3.3.0")
    }

    // MARK: - PP-4259: Periodic forced full crawl

    func testCrawl_WhenLastFullCrawlOlderThan7Days_HitsCrawlableURL() async throws {
        let now = Date()
        let baseURL = URL(string: "https://registry.example.com/libraries")!
        let crawlableURL = URL(string: "https://registry.example.com/libraries/crawlable")!
        let facetURL = URL(string: "https://registry.example.com/libraries/crawlable?order=modified")!

        try writeCrawlState(CrawlState(
            lastSuccessfulCrawlDate: now.addingTimeInterval(-60),
            orderModifiedFacetURL: facetURL,
            lastFullCrawlDate: now.addingTimeInterval(-8 * 24 * 60 * 60),
            lastCrawlAppVersion: "3.2.0"
        ))

        let sortFacet = makeSortFacet(modifiedHref: facetURL.absoluteString, modifiedActive: true)
        let page = makeFeedJSON(
            publications: [makePublicationJSON(id: "lib-1", updated: "2026-04-15T10:00:00Z")],
            facets: [sortFacet]
        )
        fetcher.responses[crawlableURL] = .success(page)

        let crawler = makeCrawler(currentAppVersion: "3.2.0", now: { now })
        _ = await crawler.crawl(
            baseURL: baseURL,
            existingPublications: [],
            feedMetadata: makeCatalogMetadata()
        )

        XCTAssertEqual(fetcher.fetchedURLs, [crawlableURL],
                       "7-day periodic forced-full-crawl must hit crawlable URL, not facet URL")
    }

    func testCrawl_WhenLastFullCrawlWithin7Days_UsesFacetURL() async throws {
        let now = Date()
        let baseURL = URL(string: "https://registry.example.com/libraries")!
        let facetURL = URL(string: "https://registry.example.com/libraries/crawlable?order=modified")!

        try writeCrawlState(CrawlState(
            lastSuccessfulCrawlDate: now.addingTimeInterval(-60),
            orderModifiedFacetURL: facetURL,
            lastFullCrawlDate: now.addingTimeInterval(-3 * 24 * 60 * 60),
            lastCrawlAppVersion: "3.2.0"
        ))

        let sortFacet = makeSortFacet(modifiedHref: facetURL.absoluteString, modifiedActive: true)
        let page = makeFeedJSON(
            publications: [makePublicationJSON(id: "lib-new", updated: "2026-04-15T10:00:00Z")],
            facets: [sortFacet]
        )
        fetcher.responses[facetURL] = .success(page)

        let crawler = makeCrawler(currentAppVersion: "3.2.0", now: { now })
        _ = await crawler.crawl(
            baseURL: baseURL,
            existingPublications: [],
            feedMetadata: makeCatalogMetadata()
        )

        XCTAssertEqual(fetcher.fetchedURLs, [facetURL],
                       "Fresh state should still use incremental facet URL")
    }

    // MARK: - PP-4259: Opportunistic deletion when incremental reaches end-of-feed

    func testIncrementalCrawl_ReachingEndOfFeed_ReconcilesDeletions() async throws {
        let now = Date()
        let baseURL = URL(string: "https://registry.example.com/libraries")!
        let facetURL = URL(string: "https://registry.example.com/libraries/crawlable?order=modified")!

        // Pre-seed: incremental possible, last crawl yesterday
        try writeCrawlState(CrawlState(
            lastSuccessfulCrawlDate: now.addingTimeInterval(-24 * 60 * 60),
            orderModifiedFacetURL: facetURL,
            lastFullCrawlDate: now.addingTimeInterval(-2 * 24 * 60 * 60),
            lastCrawlAppVersion: "3.2.0"
        ))

        // Feed: single page, no next-page link, contains lib-1 and lib-2
        // (older than cutoff so they'd normally be filtered in incremental mode).
        let sortFacet = makeSortFacet(modifiedHref: facetURL.absoluteString, modifiedActive: true)
        let page = makeFeedJSON(
            publications: [
                makePublicationJSON(id: "lib-1", updated: "2024-01-01T00:00:00Z"),
                makePublicationJSON(id: "lib-2", updated: "2024-01-02T00:00:00Z"),
            ],
            facets: [sortFacet]
        )
        fetcher.responses[facetURL] = .success(page)

        // Existing cache contains an orphan that no longer appears in the feed
        let existingPubs = [
            OPDS2Publication(links: [], metadata: OPDS2Publication.Metadata(id: "lib-1", title: "Lib 1"), images: nil),
            OPDS2Publication(links: [], metadata: OPDS2Publication.Metadata(id: "lib-orphan", title: "Orphan"), images: nil),
        ]

        let crawler = makeCrawler(currentAppVersion: "3.2.0", now: { now })
        let result = await crawler.crawl(
            baseURL: baseURL,
            existingPublications: existingPubs,
            feedMetadata: makeCatalogMetadata()
        )

        guard case .success(let data) = result else {
            XCTFail("Expected success, got \(result)")
            return
        }

        let feed = try OPDS2CatalogsFeed.fromData(data)
        let ids = Set(feed.catalogs.map(\.metadata.id))
        XCTAssertTrue(ids.contains("lib-1"))
        XCTAssertTrue(ids.contains("lib-2"))
        XCTAssertFalse(ids.contains("lib-orphan"),
                       "End-of-feed reached during incremental walk should reconcile deletions")

        // Promotion: state.lastFullCrawlDate must advance to `now`
        let state = try readCrawlState()
        let lastFull = try XCTUnwrap(state.lastFullCrawlDate)
        XCTAssertEqual(lastFull.timeIntervalSinceReferenceDate,
                       now.timeIntervalSinceReferenceDate,
                       accuracy: 0.1,
                       "End-of-feed incremental crawl must be promoted to a full crawl")
    }

    func testIncrementalCrawl_WhenNotReachingEndOfFeed_PreservesExistingEntries() async throws {
        let now = Date()
        let baseURL = URL(string: "https://registry.example.com/libraries")!
        let facetURL = URL(string: "https://registry.example.com/libraries/crawlable?order=modified")!
        let page2URL = URL(string: "https://registry.example.com/libraries/crawlable?order=modified&offset=1")!

        try writeCrawlState(CrawlState(
            lastSuccessfulCrawlDate: Date(timeIntervalSince1970: 1713160000),
            orderModifiedFacetURL: facetURL,
            lastFullCrawlDate: now.addingTimeInterval(-2 * 24 * 60 * 60),
            lastCrawlAppVersion: "3.2.0"
        ))

        // Page 1: one newer entry + rel=next; page 2: only OLD entries — incremental
        // should early-stop on page 2 (no rel=next still pointing forward),
        // i.e. NOT walk to true end-of-feed.
        let sortFacet = makeSortFacet(modifiedHref: facetURL.absoluteString, modifiedActive: true)
        let page1 = makeFeedJSON(
            publications: [makePublicationJSON(id: "lib-new", updated: "2026-04-15T10:00:00Z")],
            nextURL: page2URL.absoluteString,
            facets: [sortFacet]
        )
        let page2 = makeFeedJSON(
            publications: [makePublicationJSON(id: "lib-old", updated: "2024-04-14T06:00:00Z")],
            nextURL: page2URL.absoluteString + "&page=3",
            facets: [sortFacet]
        )
        fetcher.responses[facetURL] = .success(page1)
        fetcher.responses[page2URL] = .success(page2)

        let existingPubs = [
            OPDS2Publication(links: [], metadata: OPDS2Publication.Metadata(id: "lib-existing", title: "Existing"), images: nil)
        ]

        let crawler = makeCrawler(currentAppVersion: "3.2.0", now: { now })
        let result = await crawler.crawl(
            baseURL: baseURL,
            existingPublications: existingPubs,
            feedMetadata: makeCatalogMetadata()
        )

        guard case .success(let data) = result else {
            XCTFail("Expected success, got \(result)")
            return
        }

        let feed = try OPDS2CatalogsFeed.fromData(data)
        let ids = Set(feed.catalogs.map(\.metadata.id))
        XCTAssertTrue(ids.contains("lib-new"))
        XCTAssertTrue(ids.contains("lib-existing"),
                      "Early-stopped incremental walk must preserve existing entries (no deletion reconciliation)")
    }

    // MARK: - Cancellation responsiveness (WS0-DRAIN timeout fix)

    /// Regression for the CI `[WS0-DRAIN] cancelAndDrainBackgroundWork TIMED OUT
    /// after 3010ms ... crawl did not observe cancellation`: a cancelled crawl
    /// Task must short-circuit to a `CancellationError`-mapped `.failure`
    /// PROMPTLY and must NOT keep paginating. Deterministic — the gated fetcher
    /// suspends the crawl inside its first fetch, we cancel, then release, so the
    /// crawl resumes into an already-cancelled Task with no wall-clock race.
    func testCrawl_WhenTaskCancelledDuringFetch_StopsPromptlyWithFailure_AndDoesNotPaginate() async throws {
        let baseURL = URL(string: "https://registry.example.com/libraries")!
        let crawlableURL = URL(string: "https://registry.example.com/libraries/crawlable")!
        let page2URL = URL(string: "https://registry.example.com/libraries/crawlable?offset=1")!

        let gated = GatedCrawlerFetcher()
        // Page 1 carries a rel=next → absent cancellation the crawl WOULD fetch
        // page 2 (the "teeth": without the checks this test fails as `.success`
        // with fetchedURLs.count == 2).
        gated.responses[crawlableURL] = makeFeedJSON(
            publications: [makePublicationJSON(id: "lib-1")],
            nextURL: page2URL.absoluteString
        )
        gated.responses[page2URL] = makeFeedJSON(
            publications: [makePublicationJSON(id: "lib-2")]
        )

        let crawler = LibraryRegistryCrawler(
            fetcher: gated,
            hash: "test_hash",
            stateDirectory: tempDir,
            currentAppVersion: "3.2.0"
        )
        let box = CrawlerBox(crawler: crawler)
        let meta = makeCatalogMetadata()

        let crawlTask = Task { () -> CrawlOutcome in
            let result = await box.crawler.crawl(
                baseURL: baseURL,
                existingPublications: [],
                feedMetadata: meta
            )
            switch result {
            case .failure(let error):
                return (error is CancellationError) ? .cancelledFailure : .otherFailure("\(error)")
            case .success:
                return .success
            case .noChanges:
                return .noChanges
            }
        }

        // Suspend inside the first fetch, cancel, THEN release the fetch so the
        // crawl resumes into a cancelled Task.
        await gated.gate.waitUntilStarted()
        crawlTask.cancel()
        await gated.gate.release()

        let start = Date()
        let outcome = await crawlTask.value
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(outcome, .cancelledFailure,
                       "Cancelled crawl must resolve to a CancellationError-mapped .failure, got \(outcome)")
        XCTAssertEqual(gated.fetchedURLs.count, 1,
                       "Cancelled crawl must NOT paginate — only the first page should have been requested")
        XCTAssertEqual(gated.fetchedURLs, [crawlableURL],
                       "The only fetch should be the initial crawlable URL")
        XCTAssertLessThan(elapsed, 2.0,
                          "Cancelled crawl must resolve promptly, well under the 3s WS0-DRAIN timeout")
    }
}
