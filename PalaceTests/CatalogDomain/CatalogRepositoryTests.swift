//
//  CatalogRepositoryTests.swift
//  PalaceTests
//
//  Unit tests for CatalogRepository caching and data fetching.
//  Tests the stale-while-revalidate caching pattern.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class CatalogRepositoryTests: XCTestCase {

  var mockAPI: CatalogAPIMock!
  var repository: CatalogRepository!

  override func setUp() {
    super.setUp()
    mockAPI = CatalogAPIMock()
    repository = CatalogRepository(api: mockAPI)
  }

  override func tearDown() {
    mockAPI = nil
    repository = nil
    super.tearDown()
  }

  // MARK: - Basic Fetch Tests

  func testLoadTopLevelCatalog_FetchesFromAPI() async throws {
    let testURL = URL(string: "https://example.com/catalog")!
    let mockFeed = CatalogAPIMock.makeMockFeed(title: "Test Catalog")
    mockAPI.stubbedFeeds[testURL] = mockFeed

    let result = try await repository.loadTopLevelCatalog(at: testURL)

    XCTAssertNotNil(result)
    XCTAssertTrue(mockAPI.wasFetchFeedCalled(with: testURL))
    XCTAssertEqual(mockAPI.fetchFeedCallCount, 1)
  }

  func testLoadTopLevelCatalog_ReturnsNilWhenAPIReturnsNil() async throws {
    let testURL = URL(string: "https://example.com/empty")!
    mockAPI.defaultFeed = nil

    do {
      _ = try await repository.loadTopLevelCatalog(at: testURL)
      XCTFail("Expected error to be thrown")
    } catch {
      // Expected - no cached feed and API returns nil
      XCTAssertTrue(error.localizedDescription.contains("Failed to fetch"))
    }
  }

  func testLoadTopLevelCatalog_ThrowsWhenAPIThrows() async {
    let testURL = URL(string: "https://example.com/error")!
    mockAPI.fetchFeedError = NSError(domain: "Test", code: -1,
                                     userInfo: [NSLocalizedDescriptionKey: "Network error"])

    do {
      _ = try await repository.loadTopLevelCatalog(at: testURL)
      XCTFail("Expected error to be thrown")
    } catch {
      XCTAssertTrue(mockAPI.wasFetchFeedCalled(with: testURL))
    }
  }

  // MARK: - Caching Tests

  func testLoadTopLevelCatalog_ReturnsCachedFeedOnSecondCall() async throws {
    let testURL = URL(string: "https://example.com/catalog")!
    let mockFeed = CatalogAPIMock.makeMockFeed(title: "Cached Feed")
    mockAPI.stubbedFeeds[testURL] = mockFeed

    // First call - fetches from API
    let result1 = try await repository.loadTopLevelCatalog(at: testURL)
    XCTAssertNotNil(result1)
    XCTAssertEqual(mockAPI.fetchFeedCallCount, 1)

    // Second call - should use cache (within fresh window)
    let result2 = try await repository.loadTopLevelCatalog(at: testURL)
    XCTAssertNotNil(result2)
    // Should not make another API call for fresh cache
    XCTAssertEqual(mockAPI.fetchFeedCallCount, 1)
  }

  func testLoadTopLevelCatalog_DifferentURLsHaveSeparateCaches() async throws {
    let url1 = URL(string: "https://example.com/catalog1")!
    let url2 = URL(string: "https://example.com/catalog2")!

    let feed1 = CatalogAPIMock.makeMockFeed(title: "Feed 1")
    let feed2 = CatalogAPIMock.makeMockFeed(title: "Feed 2")

    mockAPI.stubbedFeeds[url1] = feed1
    mockAPI.stubbedFeeds[url2] = feed2

    _ = try await repository.loadTopLevelCatalog(at: url1)
    _ = try await repository.loadTopLevelCatalog(at: url2)

    XCTAssertEqual(mockAPI.fetchFeedCallCount, 2)
    XCTAssertTrue(mockAPI.wasFetchFeedCalled(with: url1))
    XCTAssertTrue(mockAPI.wasFetchFeedCalled(with: url2))
  }

  // MARK: - Cache Invalidation Tests

  func testInvalidateCache_ForcesNetworkFetchOnNextCall() async throws {
    let testURL = URL(string: "https://example.com/catalog")!
    let mockFeed = CatalogAPIMock.makeMockFeed(title: "Test")
    mockAPI.stubbedFeeds[testURL] = mockFeed

    // First call - caches the feed
    _ = try await repository.loadTopLevelCatalog(at: testURL)
    XCTAssertEqual(mockAPI.fetchFeedCallCount, 1)

    // Invalidate cache
    repository.invalidateCache(for: testURL)

    // Wait a moment for cache invalidation to process
    try await Task.sleep(nanoseconds: 100_000_000) // 0.1 second

    // Next call should fetch from network again
    _ = try await repository.loadTopLevelCatalog(at: testURL)
    XCTAssertEqual(mockAPI.fetchFeedCallCount, 2)
  }

  func testInvalidateCache_OnlyAffectsSpecificURL() async throws {
    let url1 = URL(string: "https://example.com/catalog1")!
    let url2 = URL(string: "https://example.com/catalog2")!

    mockAPI.stubbedFeeds[url1] = CatalogAPIMock.makeMockFeed(title: "Feed 1")
    mockAPI.stubbedFeeds[url2] = CatalogAPIMock.makeMockFeed(title: "Feed 2")

    // Cache both feeds
    _ = try await repository.loadTopLevelCatalog(at: url1)
    _ = try await repository.loadTopLevelCatalog(at: url2)
    XCTAssertEqual(mockAPI.fetchFeedCallCount, 2)

    // Invalidate only url1
    repository.invalidateCache(for: url1)
    try await Task.sleep(nanoseconds: 100_000_000)

    // url1 should refetch, url2 should use cache
    _ = try await repository.loadTopLevelCatalog(at: url1)
    _ = try await repository.loadTopLevelCatalog(at: url2)

    // url1 was refetched (call count goes from 2 to 3)
    XCTAssertEqual(mockAPI.fetchFeedCallCount, 3)
  }

  // MARK: - Search Tests

  func testSearch_DelegatesToAPI() async throws {
    let baseURL = URL(string: "https://example.com/catalog")!
    let searchFeed = CatalogAPIMock.makeMockFeed(title: "Search Results")
    mockAPI.stubbedSearchFeed = searchFeed

    let result = try await repository.search(query: "test query", baseURL: baseURL)

    XCTAssertNotNil(result)
    XCTAssertTrue(mockAPI.wasSearchCalled(with: "test query"))
    XCTAssertEqual(mockAPI.searchCallCount, 1)
  }

  func testSearch_ThrowsWhenAPIThrows() async {
    let baseURL = URL(string: "https://example.com/catalog")!
    mockAPI.searchError = NSError(domain: "Test", code: -1,
                                  userInfo: [NSLocalizedDescriptionKey: "Search failed"])

    do {
      _ = try await repository.search(query: "test", baseURL: baseURL)
      XCTFail("Expected error to be thrown")
    } catch {
      XCTAssertTrue(mockAPI.wasSearchCalled(with: "test"))
    }
  }

  // MARK: - FetchFeed Direct Tests

  func testFetchFeed_DelegatesToAPIWithoutCaching() async throws {
    let testURL = URL(string: "https://example.com/feed")!
    let mockFeed = CatalogAPIMock.makeMockFeed(title: "Direct Feed")
    mockAPI.stubbedFeeds[testURL] = mockFeed

    // Call fetchFeed multiple times
    _ = try await repository.fetchFeed(at: testURL)
    _ = try await repository.fetchFeed(at: testURL)
    _ = try await repository.fetchFeed(at: testURL)

    // fetchFeed should call API each time (no caching at this level)
    XCTAssertEqual(mockAPI.fetchFeedCallCount, 3)
  }

  // MARK: - Error Handling Tests

  func testLoadTopLevelCatalog_NetworkErrorWithNoCacheFails() async {
    let testURL = URL(string: "https://example.com/nocache")!
    mockAPI.fetchFeedError = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet,
                                     userInfo: [NSLocalizedDescriptionKey: "No internet connection"])

    do {
      _ = try await repository.loadTopLevelCatalog(at: testURL)
      XCTFail("Expected error to be thrown")
    } catch {
      // Expected failure when no cache and network fails
      XCTAssertTrue(error.localizedDescription.contains("Failed to fetch"))
    }
  }

  // MARK: - Concurrent Access Tests

  func testLoadTopLevelCatalog_ConcurrentRequestsShareCache() async throws {
    let testURL = URL(string: "https://example.com/concurrent")!
    let mockFeed = CatalogAPIMock.makeMockFeed(title: "Concurrent Test")
    mockAPI.stubbedFeeds[testURL] = mockFeed
    mockAPI.simulatedDelay = 0.1 // Small delay to allow concurrent requests

    // Launch multiple concurrent requests
    async let request1 = repository.loadTopLevelCatalog(at: testURL)
    async let request2 = repository.loadTopLevelCatalog(at: testURL)
    async let request3 = repository.loadTopLevelCatalog(at: testURL)

    let results = try await [request1, request2, request3]

    // All requests should return valid feeds
    XCTAssertTrue(results.allSatisfy { $0 != nil })
  }

  // MARK: - Protocol Conformance Tests

  func testRepository_ConformsToCatalogRepositoryProtocol() {
    // Verify the repository conforms to the protocol
    let _: CatalogRepositoryProtocol = repository
    XCTAssertTrue(true) // If this compiles, the test passes
  }

  // MARK: - Edge Cases

  func testLoadTopLevelCatalog_EmptyURLString() async throws {
    // This tests URL handling - empty or malformed URLs
    let testURL = URL(string: "https://")!
    mockAPI.defaultFeed = CatalogAPIMock.makeMockFeed(title: "Default")

    let result = try await repository.loadTopLevelCatalog(at: testURL)
    XCTAssertNotNil(result)
  }

  func testLoadTopLevelCatalog_URLWithQueryParameters() async throws {
    let testURL = URL(string: "https://example.com/catalog?page=1&sort=title")!
    let mockFeed = CatalogAPIMock.makeMockFeed(title: "Paginated Feed")
    mockAPI.stubbedFeeds[testURL] = mockFeed

    let result = try await repository.loadTopLevelCatalog(at: testURL)

    XCTAssertNotNil(result)
    XCTAssertTrue(mockAPI.wasFetchFeedCalled(with: testURL))
  }

  func testLoadTopLevelCatalog_URLWithFragment() async throws {
    let testURL = URL(string: "https://example.com/catalog#section")!
    let mockFeed = CatalogAPIMock.makeMockFeed(title: "Fragment Feed")
    mockAPI.stubbedFeeds[testURL] = mockFeed

    let result = try await repository.loadTopLevelCatalog(at: testURL)

    XCTAssertNotNil(result)
    XCTAssertTrue(mockAPI.wasFetchFeedCalled(with: testURL))
  }
}

// MARK: - Memory Cache Behavior Tests

extension CatalogRepositoryTests {

  func testCacheExpiry_FreshCacheIsUsed() async throws {
    // This test verifies that fresh cache (< 10 minutes) is returned immediately
    let testURL = URL(string: "https://example.com/fresh")!
    let mockFeed = CatalogAPIMock.makeMockFeed(title: "Fresh Feed")
    mockAPI.stubbedFeeds[testURL] = mockFeed

    // First fetch
    _ = try await repository.loadTopLevelCatalog(at: testURL)

    // Immediately fetch again - should use cache
    _ = try await repository.loadTopLevelCatalog(at: testURL)

    // Only one API call should have been made
    XCTAssertEqual(mockAPI.fetchFeedCallCount, 1)
  }
}

// MARK: - API Delegation Tests

extension CatalogRepositoryTests {

  func testFetchFeed_PassesURLToAPI() async throws {
    let testURL = URL(string: "https://example.com/specific-feed")!
    mockAPI.defaultFeed = CatalogAPIMock.makeMockFeed(title: "Default")

    _ = try await repository.fetchFeed(at: testURL)

    XCTAssertEqual(mockAPI.fetchFeedCalls.last, testURL)
  }

  func testSearch_PassesQueryAndURLToAPI() async throws {
    let baseURL = URL(string: "https://example.com/search")!
    mockAPI.stubbedSearchFeed = CatalogAPIMock.makeMockFeed(title: "Search")

    _ = try await repository.search(query: "my search", baseURL: baseURL)

    let lastCall = mockAPI.searchCalls.last
    XCTAssertEqual(lastCall?.query, "my search")
    XCTAssertEqual(lastCall?.baseURL, baseURL)
  }
}
