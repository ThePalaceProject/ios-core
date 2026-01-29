//
//  CatalogAPIMock.swift
//  PalaceTests
//
//  Mock implementation of CatalogAPI for testing.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import Foundation
@testable import Palace

/// Mock implementation of CatalogAPI for testing CatalogRepository
final class CatalogAPIMock: CatalogAPI {

  // MARK: - Stubbed Responses

  /// The feed to return from fetchFeed, keyed by URL
  var stubbedFeeds: [URL: CatalogFeed] = [:]

  /// The feed to return from search
  var stubbedSearchFeed: CatalogFeed?

  /// Error to throw from fetchFeed (if set, takes precedence over stubbedFeeds)
  var fetchFeedError: Error?

  /// Error to throw from search
  var searchError: Error?

  /// Default feed to return when no specific stub is set
  var defaultFeed: CatalogFeed?

  // MARK: - Call Tracking

  /// URLs that fetchFeed was called with
  private(set) var fetchFeedCalls: [URL] = []

  /// Search queries that search was called with
  private(set) var searchCalls: [(query: String, baseURL: URL)] = []

  /// Delay to simulate network latency (in seconds)
  var simulatedDelay: TimeInterval = 0

  /// Whether the mock should fail after a certain number of calls
  var failAfterCallCount: Int?

  // MARK: - CatalogAPI Implementation

  func fetchFeed(at url: URL) async throws -> CatalogFeed? {
    fetchFeedCalls.append(url)

    // Check if we should fail after N calls
    if let failAfter = failAfterCallCount, fetchFeedCalls.count > failAfter {
      throw NSError(domain: "CatalogAPIMock", code: -1,
                   userInfo: [NSLocalizedDescriptionKey: "Simulated failure after \(failAfter) calls"])
    }

    // Simulate network delay
    if simulatedDelay > 0 {
      try await Task.sleep(nanoseconds: UInt64(simulatedDelay * 1_000_000_000))
    }

    // Check for error stub
    if let error = fetchFeedError {
      throw error
    }

    // Return stubbed feed for URL, or default feed
    return stubbedFeeds[url] ?? defaultFeed
  }

  func search(query: String, baseURL: URL) async throws -> CatalogFeed? {
    searchCalls.append((query: query, baseURL: baseURL))

    // Simulate network delay
    if simulatedDelay > 0 {
      try await Task.sleep(nanoseconds: UInt64(simulatedDelay * 1_000_000_000))
    }

    // Check for error stub
    if let error = searchError {
      throw error
    }

    return stubbedSearchFeed
  }

  // MARK: - Test Helpers

  /// Reset all stubs and call tracking
  func reset() {
    stubbedFeeds = [:]
    stubbedSearchFeed = nil
    fetchFeedError = nil
    searchError = nil
    defaultFeed = nil
    fetchFeedCalls = []
    searchCalls = []
    simulatedDelay = 0
    failAfterCallCount = nil
  }

  /// Check if fetchFeed was called with a specific URL
  func wasFetchFeedCalled(with url: URL) -> Bool {
    fetchFeedCalls.contains(url)
  }

  /// Get the number of times fetchFeed was called
  var fetchFeedCallCount: Int {
    fetchFeedCalls.count
  }

  /// Check if search was called with a specific query
  func wasSearchCalled(with query: String) -> Bool {
    searchCalls.contains { $0.query == query }
  }

  /// Get the number of times search was called
  var searchCallCount: Int {
    searchCalls.count
  }
}

// MARK: - Test Feed Factory

extension CatalogAPIMock {

  /// Create a simple mock CatalogFeed for testing
  static func makeMockFeed(title: String = "Test Feed") -> CatalogFeed? {
    // Create minimal OPDS feed data
    let opdsFeedXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <feed xmlns="http://www.w3.org/2005/Atom" xmlns:opds="http://opds-spec.org/2010/catalog">
      <id>urn:uuid:test-feed</id>
      <title>\(title)</title>
      <updated>2024-01-01T00:00:00Z</updated>
    </feed>
    """

    guard let data = opdsFeedXML.data(using: .utf8),
          let xml = TPPXML(data: data) else {
      return nil
    }

    guard let opdsFeed = TPPOPDSFeed(xml: xml) else {
      return nil
    }

    return CatalogFeed(feed: opdsFeed)
  }

  /// Create a mock feed with lanes for testing
  static func makeMockFeedWithLanes(laneCount: Int = 3) -> CatalogFeed? {
    var entriesXML = ""
    for i in 0..<laneCount {
      entriesXML += """
      <entry>
        <id>urn:uuid:entry-\(i)</id>
        <title>Entry \(i)</title>
        <updated>2024-01-01T00:00:00Z</updated>
      </entry>
      """
    }

    let opdsFeedXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <feed xmlns="http://www.w3.org/2005/Atom" xmlns:opds="http://opds-spec.org/2010/catalog">
      <id>urn:uuid:test-feed-with-lanes</id>
      <title>Test Feed With Lanes</title>
      <updated>2024-01-01T00:00:00Z</updated>
      \(entriesXML)
    </feed>
    """

    guard let data = opdsFeedXML.data(using: .utf8),
          let xml = TPPXML(data: data) else {
      return nil
    }

    guard let opdsFeed = TPPOPDSFeed(xml: xml) else {
      return nil
    }

    return CatalogFeed(feed: opdsFeed)
  }
}
