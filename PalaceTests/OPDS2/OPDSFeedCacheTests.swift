//
//  OPDSFeedCacheTests.swift
//  PalaceTests
//
//  Tests for OPDS feed caching with stale-while-revalidate
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class OPDSFeedCacheTests: XCTestCase {
  
  var sut: OPDS2FeedCache!
  
  override func setUp() async throws {
    try await super.setUp()
    // Use aggressive config for faster test execution
    sut = OPDS2FeedCache(configuration: .init(
      staleTTL: 1, // 1 second
      maxAge: 5,   // 5 seconds
      maxMemoryEntries: 10,
      persistToDisk: false
    ))
  }
  
  override func tearDown() async throws {
    await sut.clear()
    sut = nil
    try await super.tearDown()
  }
  
  // MARK: - Basic Cache Operations
  
  func testSetAndGet() async throws {
    let url = URL(string: "https://example.com/feed")!
    let feed = makeFeed(title: "Test Feed")
    let entry = OPDSCacheEntry(feed: feed)
    
    await sut.set(entry, for: url)
    let cached = await sut.get(for: url)
    
    XCTAssertNotNil(cached)
    XCTAssertEqual(cached?.feed.title, "Test Feed")
  }
  
  func testGetNonExistent() async {
    let url = URL(string: "https://example.com/nonexistent")!
    let cached = await sut.get(for: url)
    
    XCTAssertNil(cached)
  }
  
  func testRemove() async throws {
    let url = URL(string: "https://example.com/feed")!
    let feed = makeFeed(title: "Test Feed")
    let entry = OPDSCacheEntry(feed: feed)
    
    await sut.set(entry, for: url)
    await sut.remove(for: url)
    let cached = await sut.get(for: url)
    
    XCTAssertNil(cached)
  }
  
  func testClear() async throws {
    let url1 = URL(string: "https://example.com/feed1")!
    let url2 = URL(string: "https://example.com/feed2")!
    
    await sut.set(OPDSCacheEntry(feed: makeFeed(title: "Feed 1")), for: url1)
    await sut.set(OPDSCacheEntry(feed: makeFeed(title: "Feed 2")), for: url2)
    
    await sut.clear()
    
    let cached1 = await sut.get(for: url1)
    let cached2 = await sut.get(for: url2)
    
    XCTAssertNil(cached1)
    XCTAssertNil(cached2)
  }
  
  // MARK: - LRU Eviction
  
  func testLRUEviction() async throws {
    // Fill cache to capacity
    for i in 0..<10 {
      let url = URL(string: "https://example.com/feed\(i)")!
      await sut.set(OPDSCacheEntry(feed: makeFeed(title: "Feed \(i)")), for: url)
    }
    
    // Add one more to trigger eviction
    let newURL = URL(string: "https://example.com/newfeed")!
    await sut.set(OPDSCacheEntry(feed: makeFeed(title: "New Feed")), for: newURL)
    
    // The oldest should be evicted
    let oldest = await sut.get(for: URL(string: "https://example.com/feed0")!)
    let newest = await sut.get(for: newURL)
    
    XCTAssertNil(oldest, "Oldest entry should be evicted")
    XCTAssertNotNil(newest, "Newest entry should exist")
  }
  
  func testLRUUpdatesOnAccess() async throws {
    let url1 = URL(string: "https://example.com/feed1")!
    let url2 = URL(string: "https://example.com/feed2")!
    
    // Add two entries
    await sut.set(OPDSCacheEntry(feed: makeFeed(title: "Feed 1")), for: url1)
    await sut.set(OPDSCacheEntry(feed: makeFeed(title: "Feed 2")), for: url2)
    
    // Access the first one to make it more recent
    _ = await sut.get(for: url1)
    
    // Fill the rest of the cache
    for i in 3...10 {
      let url = URL(string: "https://example.com/feed\(i)")!
      await sut.set(OPDSCacheEntry(feed: makeFeed(title: "Feed \(i)")), for: url)
    }
    
    // Add one more to trigger eviction
    let newURL = URL(string: "https://example.com/newfeed")!
    await sut.set(OPDSCacheEntry(feed: makeFeed(title: "New Feed")), for: newURL)
    
    // feed1 should still exist (was accessed recently), feed2 should be evicted
    let cached1 = await sut.get(for: url1)
    let cached2 = await sut.get(for: url2)
    
    XCTAssertNotNil(cached1, "Recently accessed entry should not be evicted")
    XCTAssertNil(cached2, "Less recently accessed entry should be evicted")
  }
  
  // MARK: - Staleness and Expiration
  
  func testCacheEntryIsStale() async throws {
    let feed = makeFeed(title: "Test")
    let entry = OPDSCacheEntry(feed: feed, timestamp: Date().addingTimeInterval(-2)) // 2 seconds ago
    
    // With 1 second TTL, this should be stale
    XCTAssertTrue(entry.isStale(ttl: 1))
    XCTAssertFalse(entry.isStale(ttl: 5))
  }
  
  func testCacheEntryIsExpired() async throws {
    let feed = makeFeed(title: "Test")
    let entry = OPDSCacheEntry(feed: feed, timestamp: Date().addingTimeInterval(-10)) // 10 seconds ago
    
    // With 5 second max age, this should be expired
    XCTAssertTrue(entry.isExpired(maxAge: 5))
    XCTAssertFalse(entry.isExpired(maxAge: 15))
  }
  
  func testExpiredEntriesNotReturned() async throws {
    let url = URL(string: "https://example.com/feed")!
    let feed = makeFeed(title: "Old Feed")
    let entry = OPDSCacheEntry(feed: feed, timestamp: Date().addingTimeInterval(-10)) // Very old
    
    await sut.set(entry, for: url)
    
    // With 5 second max age, this should not be returned
    let cached = await sut.get(for: url)
    XCTAssertNil(cached, "Expired entries should not be returned")
  }
  
  // MARK: - Stale-While-Revalidate
  
  func testGetWithRevalidationReturnsFreshData() async throws {
    let url = URL(string: "https://example.com/feed")!
    let feed = makeFeed(title: "Fresh Feed")
    let entry = OPDSCacheEntry(feed: feed) // Fresh timestamp
    
    await sut.set(entry, for: url)
    
    var fetcherCalled = false
    let result = try await sut.getWithRevalidation(for: url) {
      fetcherCalled = true
      return (self.makeFeed(title: "New Feed"), nil, nil)
    }
    
    XCTAssertEqual(result.feed.title, "Fresh Feed")
    XCTAssertFalse(result.isStale)
    XCTAssertFalse(result.didTriggerRefresh)
    XCTAssertFalse(fetcherCalled, "Fetcher should not be called for fresh data")
  }
  
  func testGetWithRevalidationFetchesWhenNoCache() async throws {
    let url = URL(string: "https://example.com/newurl")!
    
    let result = try await sut.getWithRevalidation(for: url) {
      return (self.makeFeed(title: "Fetched Feed"), "etag123", "Mon, 01 Jan 2026 00:00:00 GMT")
    }
    
    XCTAssertEqual(result.feed.title, "Fetched Feed")
    XCTAssertFalse(result.isStale)
    XCTAssertFalse(result.didTriggerRefresh)
    
    // Should be cached now
    let cached = await sut.get(for: url)
    XCTAssertNotNil(cached)
    XCTAssertEqual(cached?.etag, "etag123")
  }
  
  // MARK: - Conditional Headers
  
  func testConditionalHeaders() async throws {
    let url = URL(string: "https://example.com/feed")!
    let feed = makeFeed(title: "Feed")
    let entry = OPDSCacheEntry(
      feed: feed,
      etag: "\"abc123\"",
      lastModified: "Mon, 01 Jan 2026 00:00:00 GMT"
    )
    
    await sut.set(entry, for: url)
    
    let headers = await sut.conditionalHeaders(for: url)
    
    XCTAssertEqual(headers["If-None-Match"], "\"abc123\"")
    XCTAssertEqual(headers["If-Modified-Since"], "Mon, 01 Jan 2026 00:00:00 GMT")
  }
  
  func testConditionalHeadersEmptyWhenNoCachedEntry() async {
    let url = URL(string: "https://example.com/nocache")!
    
    let headers = await sut.conditionalHeaders(for: url)
    
    XCTAssertTrue(headers.isEmpty)
  }
  
  // MARK: - Stats
  
  func testStats() async throws {
    let url = URL(string: "https://example.com/feed")!
    await sut.set(OPDSCacheEntry(feed: makeFeed(title: "Feed")), for: url)
    
    let stats = await sut.stats()
    
    XCTAssertEqual(stats.memoryCount, 1)
    XCTAssertFalse(stats.diskEnabled) // We disabled disk for tests
  }
  
  // MARK: - Helpers
  
  private func makeFeed(title: String) -> OPDS2Feed {
    OPDS2Feed(
      metadata: OPDS2FeedMetadata(title: title),
      links: [OPDS2Link(href: "https://example.com", rel: "self")]
    )
  }
}
