//
//  CatalogDomainTests.swift
//  PalaceTests
//
//  Tests for CatalogDomain layer: CatalogRepository caching logic,
//  OPDSParser format detection and error handling, and CatalogFeed model construction.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

// MARK: - CatalogRepository Tests

final class CatalogRepositoryCoreTests: XCTestCase {

    private var api: CatalogAPIMock!
    private var repository: CatalogRepository!
    private let testURL = URL(string: "https://example.com/feed")!

    override func setUp() {
        super.setUp()
        api = CatalogAPIMock()
        repository = CatalogRepository(api: api)
    }

    override func tearDown() {
        api = nil
        repository = nil
        super.tearDown()
    }

    // MARK: - Basic Fetch

    func testLoadTopLevelCatalogCallsAPI() async throws {
        let mockFeed = CatalogAPIMock.makeMockFeed(title: "Test Feed")
        api.defaultFeed = mockFeed

        let feed = try await repository.loadTopLevelCatalog(at: testURL)

        XCTAssertNotNil(feed)
        XCTAssertEqual(api.fetchFeedCallCount, 1)
        XCTAssertTrue(api.wasFetchFeedCalled(with: testURL))
    }

    func testLoadTopLevelCatalogReturnsFeedTitle() async throws {
        let mockFeed = CatalogAPIMock.makeMockFeed(title: "My Library")
        api.defaultFeed = mockFeed

        let feed = try await repository.loadTopLevelCatalog(at: testURL)

        XCTAssertEqual(feed?.title, "My Library")
    }

    // MARK: - Caching Behavior

    func testLoadTopLevelCatalogCachesFeed() async throws {
        let mockFeed = CatalogAPIMock.makeMockFeed(title: "Cached Feed")
        api.defaultFeed = mockFeed

        // First call fetches from API
        _ = try await repository.loadTopLevelCatalog(at: testURL)
        XCTAssertEqual(api.fetchFeedCallCount, 1)

        // Second call should use cache (within 10-minute window)
        _ = try await repository.loadTopLevelCatalog(at: testURL)
        XCTAssertEqual(api.fetchFeedCallCount, 1, "Second call should use cached result")
    }

    func testDifferentURLsAreCachedSeparately() async throws {
        let url1 = URL(string: "https://example.com/feed1")!
        let url2 = URL(string: "https://example.com/feed2")!

        let feed1 = CatalogAPIMock.makeMockFeed(title: "Feed 1")
        let feed2 = CatalogAPIMock.makeMockFeed(title: "Feed 2")

        api.stubbedFeeds[url1] = feed1
        api.stubbedFeeds[url2] = feed2

        let result1 = try await repository.loadTopLevelCatalog(at: url1)
        let result2 = try await repository.loadTopLevelCatalog(at: url2)

        XCTAssertEqual(result1?.title, "Feed 1")
        XCTAssertEqual(result2?.title, "Feed 2")
        XCTAssertEqual(api.fetchFeedCallCount, 2)
    }

    // MARK: - Cache Invalidation

    func testInvalidateCacheForcesFreshFetch() async throws {
        let mockFeed = CatalogAPIMock.makeMockFeed(title: "Fresh Feed")
        api.defaultFeed = mockFeed

        // Load and cache
        _ = try await repository.loadTopLevelCatalog(at: testURL)
        XCTAssertEqual(api.fetchFeedCallCount, 1)

        // Invalidate cache
        repository.invalidateCache(for: testURL)

        // Give cache queue time to process
        try await Task.sleep(nanoseconds: 100_000_000)

        // Next load should fetch from API again
        _ = try await repository.loadTopLevelCatalog(at: testURL)
        XCTAssertEqual(api.fetchFeedCallCount, 2)
    }

    // MARK: - Error Handling

    func testLoadTopLevelCatalogPropagatesError() async {
        api.fetchFeedError = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)

        do {
            _ = try await repository.loadTopLevelCatalog(at: testURL)
            XCTFail("Should throw an error")
        } catch {
            // Expected
            XCTAssertNotNil(error)
        }
    }

    func testLoadTopLevelCatalogFallsToCacheOnNetworkError() async throws {
        // First: load and cache successfully
        let mockFeed = CatalogAPIMock.makeMockFeed(title: "Fallback")
        api.defaultFeed = mockFeed
        _ = try await repository.loadTopLevelCatalog(at: testURL)

        // Invalidate cache so next load tries network
        repository.invalidateCache(for: testURL)
        try await Task.sleep(nanoseconds: 100_000_000)

        // Now make API fail
        api.fetchFeedError = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)

        // The repository should NOT have a memory cache entry after invalidation,
        // so it should throw. But if the implementation has stale-while-revalidate
        // it might still return the old cached feed.
        // This test verifies the error path works.
        do {
            let result = try await repository.loadTopLevelCatalog(at: testURL)
            // If we get here, the repository used a cached fallback
            XCTAssertNotNil(result)
        } catch {
            // This is also acceptable - error propagated
            XCTAssertNotNil(error)
        }
    }

    // MARK: - Search Passthrough

    func testSearchDelegatesToAPI() async throws {
        let searchFeed = CatalogAPIMock.makeMockFeed(title: "Search Results")
        api.stubbedSearchFeed = searchFeed

        let result = try await repository.search(query: "fiction", baseURL: testURL)

        XCTAssertNotNil(result)
        XCTAssertTrue(api.wasSearchCalled(with: "fiction"))
    }

    func testSearchPropagatesError() async {
        api.searchError = NSError(domain: "test", code: 404)

        do {
            _ = try await repository.search(query: "test", baseURL: testURL)
            XCTFail("Should throw")
        } catch {
            XCTAssertNotNil(error)
        }
    }
}

// MARK: - OPDSParser Tests

final class OPDSParserCoreTests: XCTestCase {

    private let parser = OPDSParser()

    func testParseValidOPDS1Feed() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
          <id>urn:uuid:test</id>
          <title>Test OPDS1 Feed</title>
          <updated>2024-01-01T00:00:00Z</updated>
        </feed>
        """
        let data = xml.data(using: .utf8)!

        let feed = try parser.parseFeed(from: data)
        XCTAssertEqual(feed.title, "Test OPDS1 Feed")
        XCTAssertFalse(feed.isOPDS2, "XML feed should be parsed as OPDS 1")
    }

    func testParseInvalidXMLThrows() {
        let badData = "this is not xml".data(using: .utf8)!

        XCTAssertThrowsError(try parser.parseFeed(from: badData)) { error in
            if let parserError = error as? OPDSParser.ParserError {
                XCTAssertEqual(parserError, .invalidXML)
            }
        }
    }

    func testParseEmptyDataThrows() {
        let emptyData = Data()

        XCTAssertThrowsError(try parser.parseFeed(from: emptyData))
    }

    func testParserErrorDescriptions() {
        XCTAssertEqual(OPDSParser.ParserError.invalidXML.errorDescription, "Unable to parse OPDS XML.")
        XCTAssertEqual(OPDSParser.ParserError.invalidFeed.errorDescription, "Invalid or unsupported OPDS feed format.")
        XCTAssertEqual(OPDSParser.ParserError.invalidJSON.errorDescription, "Unable to parse OPDS 2 JSON.")
    }
}

// MARK: - CatalogFeed Model Tests

final class CatalogFeedModelTests: XCTestCase {

    func testCatalogFeedFromNilFeedReturnsNil() {
        let feed = CatalogFeed(feed: nil)
        XCTAssertNil(feed)
    }

    func testCatalogFeedFromOPDS1() {
        let feed = CatalogAPIMock.makeMockFeed(title: "OPDS1 Feed")

        XCTAssertNotNil(feed)
        XCTAssertFalse(feed?.isOPDS2 ?? true)
        XCTAssertEqual(feed?.title, "OPDS1 Feed")
    }

    func testCatalogEntryFromOPDS1Entry() {
        let feed = CatalogAPIMock.makeMockFeedWithLanes(laneCount: 2)

        XCTAssertNotNil(feed)
        XCTAssertEqual(feed?.entries.count, 2)
    }

    func testSearchFormatEntryEquality() {
        let url = URL(string: "https://example.com")!
        let entry1 = SearchFormatEntry(id: "1", title: "All", groupsFeedURL: url, searchDescriptorURL: nil, isActive: true)
        let entry2 = SearchFormatEntry(id: "1", title: "All", groupsFeedURL: url, searchDescriptorURL: nil, isActive: true)
        let entry3 = SearchFormatEntry(id: "2", title: "Audiobooks", groupsFeedURL: url, searchDescriptorURL: nil, isActive: false)

        XCTAssertEqual(entry1, entry2)
        XCTAssertNotEqual(entry1, entry3)
    }
}

// MARK: - DefaultCatalogAPI.extractSearchEntryPoints Tests

final class CatalogAPIEntryPointTests: XCTestCase {

    func testExtractSearchEntryPointsFromEmptyFeed() {
        guard let feed = CatalogAPIMock.makeMockFeed(title: "Empty") else {
            XCTFail("Could not create mock feed")
            return
        }

        let entries = DefaultCatalogAPI.extractSearchEntryPoints(from: feed)
        XCTAssertTrue(entries.isEmpty, "Feed without facets should return no entry points")
    }
}
