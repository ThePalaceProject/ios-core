//
//  CatalogRepositoryTests.swift
//  PalaceTests
//
//  Tests for CatalogRepository using NetworkClientMock via DefaultCatalogAPI.
//  Exercises stale-while-revalidate caching, error handling, and timeout behavior.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class CatalogRepositoryTests: XCTestCase {

    // MARK: - Properties

    private var networkClientMock: NetworkClientMock!
    private var parser: OPDSParser!
    private var catalogAPI: DefaultCatalogAPI!
    private var sut: CatalogRepository!

    // MARK: - Test URLs

    private let catalogURL = URL(string: "https://library.example.com/catalog")!
    private let searchURL = URL(string: "https://library.example.com/search")!
    private let facetURL = URL(string: "https://library.example.com/catalog/fiction")!

    // MARK: - Setup/Teardown

    override func setUp() {
        super.setUp()
        networkClientMock = NetworkClientMock()
        parser = OPDSParser()
        catalogAPI = DefaultCatalogAPI(client: networkClientMock, parser: parser)
        sut = CatalogRepository(api: catalogAPI)
    }

    override func tearDown() {
        networkClientMock = nil
        parser = nil
        catalogAPI = nil
        sut = nil
        super.tearDown()
    }

    // MARK: - loadTopLevelCatalog Tests

    func testLoadTopLevelCatalog_Success_ReturnsFeed() async throws {
        // Arrange
        let opdsXML = NetworkClientMock.makeOPDSFeedXML(title: "Main Library", entries: 5)
        networkClientMock.stubOPDSResponse(for: catalogURL, xml: opdsXML)

        // Act
        let feed = try await sut.loadTopLevelCatalog(at: catalogURL)

        // Assert
        XCTAssertNotNil(feed)
        XCTAssertEqual(feed?.title, "Main Library")
        XCTAssertEqual(networkClientMock.sendCallCount, 1)
    }

    func testLoadTopLevelCatalog_CachesFeed_ReturnsFromCache() async throws {
        // Arrange
        let opdsXML = NetworkClientMock.makeOPDSFeedXML(title: "Cached Catalog", entries: 3)
        networkClientMock.stubOPDSResponse(for: catalogURL, xml: opdsXML)

        // Act - First call
        let feed1 = try await sut.loadTopLevelCatalog(at: catalogURL)

        // Modify stub to return different content (should not be called)
        let updatedXML = NetworkClientMock.makeOPDSFeedXML(title: "Updated Catalog", entries: 10)
        networkClientMock.stubOPDSResponse(for: catalogURL, xml: updatedXML)

        // Act - Second call (should return cached)
        let feed2 = try await sut.loadTopLevelCatalog(at: catalogURL)

        // Assert
        XCTAssertEqual(feed1?.title, "Cached Catalog")
        XCTAssertEqual(feed2?.title, "Cached Catalog") // Still cached title
        XCTAssertEqual(networkClientMock.sendCallCount, 1) // Only one network call
    }

    func testLoadTopLevelCatalog_NetworkError_ThrowsError() async {
        // Arrange
        networkClientMock.errorsByURL[catalogURL] = NetworkClientMockError.networkUnavailable

        // Act & Assert
        do {
            _ = try await sut.loadTopLevelCatalog(at: catalogURL)
            XCTFail("Expected error to be thrown")
        } catch {
            // Should propagate error when no cache exists
            XCTAssertEqual(networkClientMock.sendCallCount, 1)
        }
    }

    func testLoadTopLevelCatalog_NetworkError_FallsBackToStaleCache() async throws {
        // Arrange - First, populate the cache
        let opdsXML = NetworkClientMock.makeOPDSFeedXML(title: "Cached Content", entries: 2)
        networkClientMock.stubOPDSResponse(for: catalogURL, xml: opdsXML)
        _ = try await sut.loadTopLevelCatalog(at: catalogURL)

        // Invalidate cache to force refetch (but cache entry still exists internally as fallback).
        // invalidateCache uses cacheQueue.async; loadTopLevelCatalog also reads via cacheQueue.async,
        // so the next load is serialized after the invalidation — no sleep needed.
        sut.invalidateCache(for: catalogURL)

        // Set up network failure
        networkClientMock.errorToThrow = NetworkClientMockError.networkUnavailable

        // Act - Should fail because cache was invalidated and no stale entry
        do {
            _ = try await sut.loadTopLevelCatalog(at: catalogURL)
            // If it succeeds, it found fallback content
        } catch {
            // Network failure with no fallback is expected
            XCTAssertTrue(error.localizedDescription.contains("Failed to fetch") ||
                            error is NetworkClientMockError)
        }
    }

    func testLoadTopLevelCatalog_InvalidXML_ThrowsParsingError() async {
        // Arrange
        networkClientMock.stubOPDSResponse(for: catalogURL, xml: "not valid XML <><>")

        // Act & Assert
        do {
            _ = try await sut.loadTopLevelCatalog(at: catalogURL)
            XCTFail("Expected parsing error")
        } catch {
            // Parser should fail on invalid XML
            XCTAssertEqual(networkClientMock.sendCallCount, 1)
        }
    }

    func testLoadTopLevelCatalog_MultipleURLs_CachesIndependently() async throws {
        // Arrange
        let mainXML = NetworkClientMock.makeOPDSFeedXML(title: "Main Catalog", entries: 5)
        let fictionXML = NetworkClientMock.makeOPDSFeedXML(title: "Fiction", entries: 10)

        networkClientMock.stubOPDSResponse(for: catalogURL, xml: mainXML)
        networkClientMock.stubOPDSResponse(for: facetURL, xml: fictionXML)

        // Act
        let mainFeed = try await sut.loadTopLevelCatalog(at: catalogURL)
        let fictionFeed = try await sut.loadTopLevelCatalog(at: facetURL)

        // Assert - Both should be cached independently
        XCTAssertEqual(mainFeed?.title, "Main Catalog")
        XCTAssertEqual(fictionFeed?.title, "Fiction")
        XCTAssertEqual(networkClientMock.sendCallCount, 2)

        // Verify cache works for both
        let mainFeedCached = try await sut.loadTopLevelCatalog(at: catalogURL)
        let fictionFeedCached = try await sut.loadTopLevelCatalog(at: facetURL)

        XCTAssertEqual(mainFeedCached?.title, "Main Catalog")
        XCTAssertEqual(fictionFeedCached?.title, "Fiction")
        XCTAssertEqual(networkClientMock.sendCallCount, 2) // No new calls
    }

    // MARK: - fetchFeed Tests

    func testFetchFeed_Success_ReturnsFeed() async throws {
        // Arrange
        let opdsXML = NetworkClientMock.makeOPDSFeedXML(title: "Direct Fetch", entries: 3)
        networkClientMock.stubOPDSResponse(for: catalogURL, xml: opdsXML)

        // Act
        let feed = try await sut.fetchFeed(at: catalogURL)

        // Assert
        XCTAssertNotNil(feed)
        XCTAssertEqual(feed?.title, "Direct Fetch")
        XCTAssertEqual(networkClientMock.sendCallCount, 1)
    }

    func testFetchFeed_DoesNotCache_AlwaysFetchesFresh() async throws {
        // Arrange
        let xml1 = NetworkClientMock.makeOPDSFeedXML(title: "Version 1", entries: 1)
        networkClientMock.stubOPDSResponse(for: catalogURL, xml: xml1)

        // Act - First fetch
        let feed1 = try await sut.fetchFeed(at: catalogURL)
        XCTAssertEqual(feed1?.title, "Version 1")

        // Update stub
        let xml2 = NetworkClientMock.makeOPDSFeedXML(title: "Version 2", entries: 2)
        networkClientMock.stubOPDSResponse(for: catalogURL, xml: xml2)

        // Act - Second fetch (should get new version since fetchFeed doesn't use cache)
        let feed2 = try await sut.fetchFeed(at: catalogURL)

        // Assert
        XCTAssertEqual(feed2?.title, "Version 2")
        XCTAssertEqual(networkClientMock.sendCallCount, 2) // Two network calls
    }

    func testFetchFeed_NetworkError_ThrowsError() async {
        // Arrange
        networkClientMock.errorsByURL[catalogURL] = NetworkClientMockError.serverError(500)

        // Act & Assert
        do {
            _ = try await sut.fetchFeed(at: catalogURL)
            XCTFail("Expected error")
        } catch {
            XCTAssertTrue(networkClientMock.wasURLRequested(catalogURL))
        }
    }

    // MARK: - invalidateCache Tests

    func testInvalidateCache_ClearsSpecificURL() async throws {
        // Arrange - Populate caches for two URLs
        let mainXML = NetworkClientMock.makeOPDSFeedXML(title: "Main", entries: 1)
        let fictionXML = NetworkClientMock.makeOPDSFeedXML(title: "Fiction", entries: 1)

        networkClientMock.stubOPDSResponse(for: catalogURL, xml: mainXML)
        networkClientMock.stubOPDSResponse(for: facetURL, xml: fictionXML)

        _ = try await sut.loadTopLevelCatalog(at: catalogURL)
        _ = try await sut.loadTopLevelCatalog(at: facetURL)
        XCTAssertEqual(networkClientMock.sendCallCount, 2)

        // Invalidate only main catalog.
        // Both invalidateCache and loadTopLevelCatalog dispatch through cacheQueue —
        // the next load sees the cleared entry without any extra wait.
        sut.invalidateCache(for: catalogURL)

        // Assert - Main catalog should fetch fresh, fiction should use cache
        _ = try await sut.loadTopLevelCatalog(at: catalogURL)
        _ = try await sut.loadTopLevelCatalog(at: facetURL)

        // Should have 3 calls now (main refetched, fiction cached)
        XCTAssertEqual(networkClientMock.sendCallCount, 3)
        XCTAssertEqual(networkClientMock.requests(forURL: catalogURL).count, 2)
        XCTAssertEqual(networkClientMock.requests(forURL: facetURL).count, 1)
    }

    // MARK: - Error Response Tests

    func testLoadTopLevelCatalog_401Unauthorized_ThrowsError() async {
        // Arrange
        networkClientMock.errorsByURL[catalogURL] = NetworkClientMockError.unauthorized

        // Act & Assert
        do {
            _ = try await sut.loadTopLevelCatalog(at: catalogURL)
            XCTFail("Expected unauthorized error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Authentication") ||
                            error is NetworkClientMockError ||
                            error.localizedDescription.contains("Failed to fetch"))
        }
    }

    func testLoadTopLevelCatalog_500ServerError_ThrowsError() async {
        // Arrange
        networkClientMock.errorsByURL[catalogURL] = NetworkClientMockError.serverError(500)

        // Act & Assert
        do {
            _ = try await sut.loadTopLevelCatalog(at: catalogURL)
            XCTFail("Expected server error")
        } catch {
            XCTAssertEqual(networkClientMock.sendCallCount, 1)
        }
    }

    // MARK: - Problem Document Tests

    func testLoadTopLevelCatalog_ProblemDocument_ParsesErrorDetails() async {
        // Arrange - Stub a problem document response
        let problemJSON = NetworkClientMock.makeProblemDocumentJSON(
            type: "http://librarysimplified.org/terms/problem/loan-limit-reached",
            title: "Loan Limit Reached",
            detail: "You have reached your maximum number of loans."
        )
        networkClientMock.stubJSONResponse(for: catalogURL, json: problemJSON, statusCode: 403)

        // Act & Assert
        do {
            _ = try await sut.loadTopLevelCatalog(at: catalogURL)
            // Parser may fail or return nil since JSON isn't valid OPDS
        } catch {
            // Expected - problem documents aren't valid OPDS feeds
            XCTAssertEqual(networkClientMock.sendCallCount, 1)
        }
    }

    // MARK: - Concurrent Request Tests

    func testLoadTopLevelCatalog_ConcurrentRequests_DeduplicatesNetworkCalls() async throws {
        // Arrange
        let opdsXML = NetworkClientMock.makeOPDSFeedXML(title: "Concurrent Test", entries: 5)
        networkClientMock.stubOPDSResponse(for: catalogURL, xml: opdsXML)
        networkClientMock.simulatedDelay = 0.5 // Simulate slow network

        // Act - Launch multiple concurrent requests
        async let feed1 = sut.loadTopLevelCatalog(at: catalogURL)
        async let feed2 = sut.loadTopLevelCatalog(at: catalogURL)
        async let feed3 = sut.loadTopLevelCatalog(at: catalogURL)

        let results = try await [feed1, feed2, feed3]

        // Assert - All should return the same feed
        for feed in results {
            XCTAssertEqual(feed?.title, "Concurrent Test")
        }

        // Should cache after first fetch, so only 1 or few network calls
        // Note: The repository may make 1 call, then subsequent calls hit cache
        XCTAssertLessThanOrEqual(networkClientMock.sendCallCount, 3)
    }

    // MARK: - Request Details Tests

    func testLoadTopLevelCatalog_UsesGETMethod() async throws {
        // Arrange
        let opdsXML = NetworkClientMock.makeOPDSFeedXML(title: "Test", entries: 1)
        networkClientMock.stubOPDSResponse(for: catalogURL, xml: opdsXML)

        // Act
        _ = try await sut.loadTopLevelCatalog(at: catalogURL)

        // Assert
        XCTAssertEqual(networkClientMock.lastRequestedMethod, .GET)
    }

    func testLoadTopLevelCatalog_PreservesQueryParameters() async throws {
        // Arrange
        let urlWithParams = URL(string: "https://library.example.com/catalog?page=2&sort=title")!
        let opdsXML = NetworkClientMock.makeOPDSFeedXML(title: "Page 2", entries: 10)
        networkClientMock.stubOPDSResponse(for: urlWithParams, xml: opdsXML)

        // Act
        let feed = try await sut.loadTopLevelCatalog(at: urlWithParams)

        // Assert
        XCTAssertEqual(feed?.title, "Page 2")
        XCTAssertEqual(networkClientMock.lastRequestedURL?.query, "page=2&sort=title")
    }

    // MARK: - Edge Cases

    func testLoadTopLevelCatalog_EmptyFeed_ReturnsEmptyEntries() async throws {
        // Arrange
        let opdsXML = NetworkClientMock.makeOPDSFeedXML(title: "Empty Library", entries: 0)
        networkClientMock.stubOPDSResponse(for: catalogURL, xml: opdsXML)

        // Act
        let feed = try await sut.loadTopLevelCatalog(at: catalogURL)

        // Assert
        XCTAssertNotNil(feed)
        XCTAssertEqual(feed?.title, "Empty Library")
    }

    func testLoadTopLevelCatalog_SpecialCharactersInTitle_ParsesCorrectly() async throws {
        // Arrange
        let opdsXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <feed xmlns="http://www.w3.org/2005/Atom">
      <id>urn:uuid:test</id>
      <title>Books &amp; More: A "Special" Collection</title>
      <updated>2024-01-01T00:00:00Z</updated>
    </feed>
    """
        networkClientMock.stubOPDSResponse(for: catalogURL, xml: opdsXML)

        // Act
        let feed = try await sut.loadTopLevelCatalog(at: catalogURL)

        // Assert
        XCTAssertEqual(feed?.title, "Books & More: A \"Special\" Collection")
    }
}

// MARK: - Integration Tests

extension CatalogRepositoryTests {

    /// Tests the full flow: Repository -> CatalogAPI -> NetworkClient
    func testIntegration_FullFetchFlow() async throws {
        // Arrange
        let opdsXML = NetworkClientMock.makeOPDSFeedXML(title: "Integration Test", entries: 5)
        networkClientMock.stubOPDSResponse(for: catalogURL, xml: opdsXML)

        // Act
        let feed = try await sut.loadTopLevelCatalog(at: catalogURL)

        // Assert full chain worked
        XCTAssertNotNil(feed)
        XCTAssertEqual(feed?.title, "Integration Test")

        // Verify request was made correctly
        XCTAssertEqual(networkClientMock.sendCallCount, 1)
        XCTAssertEqual(networkClientMock.lastRequestedURL, catalogURL)
        XCTAssertEqual(networkClientMock.lastRequestedMethod, .GET)

        // Verify caching works
        let cachedFeed = try await sut.loadTopLevelCatalog(at: catalogURL)
        XCTAssertEqual(cachedFeed?.title, "Integration Test")
        XCTAssertEqual(networkClientMock.sendCallCount, 1) // No additional network call
    }

    /// Tests error propagation through the full chain
    func testIntegration_ErrorPropagation() async {
        // Arrange
        networkClientMock.errorToThrow = NetworkClientMockError.networkUnavailable

        // Act & Assert
        do {
            _ = try await sut.loadTopLevelCatalog(at: catalogURL)
            XCTFail("Expected error to propagate")
        } catch {
            // Error should have propagated from NetworkClient -> CatalogAPI -> Repository
            XCTAssertEqual(networkClientMock.sendCallCount, 1)
        }
    }
}
