//
//  CatalogRepositoryMock.swift
//  PalaceTests
//
//  Mock implementation of CatalogRepositoryProtocol for testing.
//  Allows complete control over catalog feed responses without network calls.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
@testable import Palace

/// Mock implementation of CatalogRepositoryProtocol for isolated ViewModel testing
@MainActor
final class CatalogRepositoryTestMock: CatalogRepositoryProtocol {

    // MARK: - Configuration

    /// The result to return from loadTopLevelCatalog
    var loadTopLevelCatalogResult: CatalogFeed?

    /// Error to throw from loadTopLevelCatalog
    var loadTopLevelCatalogError: Error?

    /// The result to return from search(query:baseURL:)
    var searchResult: CatalogFeed?

    /// Error to throw from search
    var searchError: Error?

    /// The result to return from search(query:searchDescriptorURL:)
    var searchWithDescriptorResult: CatalogFeed?

    /// Error to throw from search(query:searchDescriptorURL:)
    var searchWithDescriptorError: Error?

    /// Entry points to return from fetchSearchEntryPoints
    var fetchSearchEntryPointsResult: [SearchFormatEntry] = []

    /// Error to throw from fetchSearchEntryPoints
    var fetchSearchEntryPointsError: Error?

    /// Delay to simulate network latency (in seconds)
    var simulatedDelay: TimeInterval = 0

    /// Whether to simulate a slow connection
    var simulateSlowConnection: Bool = false

    // MARK: - Call Tracking

    /// Number of times loadTopLevelCatalog was called
    private(set) var loadTopLevelCatalogCallCount = 0

    /// Number of times search(query:baseURL:) was called
    private(set) var searchCallCount = 0

    /// Number of times search(query:searchDescriptorURL:) was called
    private(set) var searchWithDescriptorCallCount = 0

    /// Number of times fetchSearchEntryPoints was called
    private(set) var fetchSearchEntryPointsCallCount = 0

    /// Number of times invalidateCache was called
    private(set) var invalidateCacheCallCount = 0

    /// The last URL passed to loadTopLevelCatalog
    private(set) var lastLoadURL: URL?

    /// The last query passed to search
    private(set) var lastSearchQuery: String?

    /// The last base URL passed to search(query:baseURL:)
    private(set) var lastSearchBaseURL: URL?

    /// The last descriptor URL passed to search(query:searchDescriptorURL:)
    private(set) var lastSearchDescriptorURL: URL?

    /// The last URL passed to invalidateCache
    private(set) var lastInvalidatedURL: URL?

    /// All URLs that were loaded
    private(set) var loadHistory: [URL] = []

    /// All search queries that were executed
    private(set) var searchHistory: [(query: String, url: URL)] = []

    // MARK: - CatalogRepositoryProtocol

    func loadTopLevelCatalog(at url: URL) async throws -> CatalogFeed? {
        loadTopLevelCatalogCallCount += 1
        lastLoadURL = url
        loadHistory.append(url)

        if simulatedDelay > 0 || simulateSlowConnection {
            let delay = simulateSlowConnection ? 2.0 : simulatedDelay
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }

        if let error = loadTopLevelCatalogError {
            throw error
        }

        return loadTopLevelCatalogResult
    }

    func search(query: String, baseURL: URL) async throws -> CatalogFeed? {
        searchCallCount += 1
        lastSearchQuery = query
        lastSearchBaseURL = baseURL
        searchHistory.append((query, baseURL))

        if simulatedDelay > 0 || simulateSlowConnection {
            let delay = simulateSlowConnection ? 2.0 : simulatedDelay
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }

        if let error = searchError {
            throw error
        }

        return searchResult
    }

    func search(query: String, searchDescriptorURL: URL) async throws -> CatalogFeed? {
        searchWithDescriptorCallCount += 1
        lastSearchQuery = query
        lastSearchDescriptorURL = searchDescriptorURL

        if simulatedDelay > 0 || simulateSlowConnection {
            let delay = simulateSlowConnection ? 2.0 : simulatedDelay
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }

        if let error = searchWithDescriptorError ?? searchError {
            throw error
        }

        return searchWithDescriptorResult ?? searchResult
    }

    func fetchSearchEntryPoints(from url: URL) async throws -> [SearchFormatEntry] {
        fetchSearchEntryPointsCallCount += 1

        if simulatedDelay > 0 || simulateSlowConnection {
            let delay = simulateSlowConnection ? 2.0 : simulatedDelay
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }

        if let error = fetchSearchEntryPointsError {
            throw error
        }

        return fetchSearchEntryPointsResult
    }

    func fetchFeed(at url: URL) async throws -> CatalogFeed? {
        // Reuse loadTopLevelCatalog logic for fetchFeed
        return try await loadTopLevelCatalog(at: url)
    }

    func invalidateCache(for url: URL) {
        invalidateCacheCallCount += 1
        lastInvalidatedURL = url
    }

    // MARK: - Test Helpers

    /// Resets all tracking state
    func reset() {
        loadTopLevelCatalogResult = nil
        loadTopLevelCatalogError = nil
        searchResult = nil
        searchError = nil
        searchWithDescriptorResult = nil
        searchWithDescriptorError = nil
        fetchSearchEntryPointsResult = []
        fetchSearchEntryPointsError = nil
        simulatedDelay = 0
        simulateSlowConnection = false
        loadTopLevelCatalogCallCount = 0
        searchCallCount = 0
        searchWithDescriptorCallCount = 0
        fetchSearchEntryPointsCallCount = 0
        invalidateCacheCallCount = 0
        lastLoadURL = nil
        lastSearchQuery = nil
        lastSearchBaseURL = nil
        lastSearchDescriptorURL = nil
        lastInvalidatedURL = nil
        loadHistory.removeAll()
        searchHistory.removeAll()
    }

    /// Creates a mock catalog feed with the given number of lanes
    func createMockFeed(laneCount: Int = 3, booksPerLane: Int = 5) -> CatalogFeed? {
        // This would require creating a mock TPPOPDSFeed which is complex
        // For now, return nil and let tests set up specific feeds as needed
        return nil
    }
}

// MARK: - Mock Errors

enum CatalogRepositoryMockError: Error, LocalizedError {
    case networkError
    case parsingError
    case serverError(Int)
    case timeout
    case unauthorized
    case notFound

    var errorDescription: String? {
        switch self {
        case .networkError:
            return "Network connection failed"
        case .parsingError:
            return "Failed to parse response"
        case .serverError(let code):
            return "Server returned error \(code)"
        case .timeout:
            return "Request timed out"
        case .unauthorized:
            return "Authentication required"
        case .notFound:
            return "Resource not found"
        }
    }
}
