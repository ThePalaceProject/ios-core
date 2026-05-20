//
//  CatalogAPIMock.swift
//  PalaceTests
//
//  Mock implementation of CatalogAPI for testing.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import Foundation
import PalaceCatalog
@testable import Palace

/// Mock implementation of CatalogAPI for testing CatalogRepository
final class CatalogAPIMock: CatalogAPI {

    // MARK: - Stubbed Responses

    /// The feed to return from fetchFeed, keyed by URL
    var stubbedFeeds: [URL: CatalogFeed] = [:]

    /// The feed to return from search(query:baseURL:)
    var stubbedSearchFeed: CatalogFeed?

    /// The feed to return from search(query:searchDescriptorURL:)
    var stubbedSearchWithDescriptorFeed: CatalogFeed?

    /// Entry points to return from fetchSearchEntryPoints
    var stubbedSearchEntryPoints: [SearchFormatEntry] = []

    /// Error to throw from fetchFeed (if set, takes precedence over stubbedFeeds)
    var fetchFeedError: Error?

    /// Error to throw from search
    var searchError: Error?

    /// Default feed to return when no specific stub is set
    var defaultFeed: CatalogFeed?

    // MARK: - Call Tracking

    /// Serialization for concurrent reads (CatalogRepository fires
    /// background refreshes on Task.detached, so two stale-read tests
    /// can call fetchFeed in parallel; Swift Array.append is not
    /// thread-safe and crashes under concurrent mutation).
    private let callsLock = NSLock()

    /// URLs that fetchFeed was called with. Guarded by `callsLock`.
    private var _fetchFeedCalls: [URL] = []
    var fetchFeedCalls: [URL] { callsLock.withLock { _fetchFeedCalls } }

    /// Search queries that search(query:baseURL:) was called with. Guarded by `callsLock`.
    private var _searchCalls: [(query: String, baseURL: URL)] = []
    var searchCalls: [(query: String, baseURL: URL)] { callsLock.withLock { _searchCalls } }

    /// Calls to search(query:searchDescriptorURL:). Guarded by `callsLock`.
    private var _searchWithDescriptorCalls: [(query: String, descriptorURL: URL)] = []
    var searchWithDescriptorCalls: [(query: String, descriptorURL: URL)] { callsLock.withLock { _searchWithDescriptorCalls } }

    /// Calls to fetchSearchEntryPoints. Guarded by `callsLock`.
    private var _fetchSearchEntryPointsCalls: [URL] = []
    var fetchSearchEntryPointsCalls: [URL] { callsLock.withLock { _fetchSearchEntryPointsCalls } }

    /// Delay to simulate network latency (in seconds)
    var simulatedDelay: TimeInterval = 0

    /// Whether the mock should fail after a certain number of calls
    var failAfterCallCount: Int?

    // MARK: - CatalogAPI Implementation

    func fetchFeed(at url: URL) async throws -> CatalogFeed? {
        let count = callsLock.withLock { () -> Int in
            _fetchFeedCalls.append(url)
            return _fetchFeedCalls.count
        }

        // Check if we should fail after N calls
        if let failAfter = failAfterCallCount, count > failAfter {
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
        callsLock.withLock { _searchCalls.append((query: query, baseURL: baseURL)) }

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

    func search(query: String, searchDescriptorURL: URL) async throws -> CatalogFeed? {
        callsLock.withLock { _searchWithDescriptorCalls.append((query: query, descriptorURL: searchDescriptorURL)) }

        if simulatedDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(simulatedDelay * 1_000_000_000))
        }

        if let error = searchError {
            throw error
        }

        return stubbedSearchWithDescriptorFeed ?? stubbedSearchFeed
    }

    func fetchSearchEntryPoints(from url: URL) async throws -> [SearchFormatEntry] {
        callsLock.withLock { _fetchSearchEntryPointsCalls.append(url) }

        if simulatedDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(simulatedDelay * 1_000_000_000))
        }

        if let error = fetchFeedError {
            throw error
        }

        return stubbedSearchEntryPoints
    }

    // MARK: - Test Helpers

    /// Reset all stubs and call tracking
    func reset() {
        stubbedFeeds = [:]
        stubbedSearchFeed = nil
        stubbedSearchWithDescriptorFeed = nil
        stubbedSearchEntryPoints = []
        fetchFeedError = nil
        searchError = nil
        defaultFeed = nil
        callsLock.withLock {
            _fetchFeedCalls = []
            _searchCalls = []
            _searchWithDescriptorCalls = []
            _fetchSearchEntryPointsCalls = []
        }
        simulatedDelay = 0
        failAfterCallCount = nil
    }

    /// Check if fetchFeed was called with a specific URL
    func wasFetchFeedCalled(with url: URL) -> Bool {
        callsLock.withLock { _fetchFeedCalls.contains(url) }
    }

    /// Get the number of times fetchFeed was called
    var fetchFeedCallCount: Int {
        callsLock.withLock { _fetchFeedCalls.count }
    }

    /// Check if search was called with a specific query
    func wasSearchCalled(with query: String) -> Bool {
        callsLock.withLock { _searchCalls.contains { $0.query == query } }
    }

    /// Get the number of times search was called
    var searchCallCount: Int {
        callsLock.withLock { _searchCalls.count }
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
