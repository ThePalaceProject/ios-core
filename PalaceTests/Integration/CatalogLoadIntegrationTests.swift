//
//  CatalogLoadIntegrationTests.swift
//  PalaceTests
//
//  Integration tests for catalog loading flows. Tests exercise the
//  CatalogRepositoryTestMock and NetworkClientMock to verify feed fetching,
//  cache invalidation, error fallback, and OPDS feed handling.
//
//  Copyright 2026 The Palace Project. All rights reserved.
//

import XCTest
import Combine
@testable import Palace

// SRS: REQ-CATALOG-001 — Catalog load integration

@MainActor
final class CatalogLoadIntegrationTests: XCTestCase {

    private var catalogRepo: CatalogRepositoryTestMock!
    private var networkClient: NetworkClientMock!
    private var cancellables: Set<AnyCancellable>!
    private let feedURL = URL(string: "https://catalog.example.com/feed")!

    override func setUp() {
        super.setUp()
        catalogRepo = CatalogRepositoryTestMock()
        networkClient = NetworkClientMock()
        cancellables = []
    }

    override func tearDown() {
        catalogRepo.reset()
        networkClient.reset()
        cancellables = nil
        catalogRepo = nil
        networkClient = nil
        super.tearDown()
    }

    // MARK: - Fresh Load

    // SRS: REQ-CATALOG-002 — Fresh load fetches from network
    func testFreshLoad_FetchesFromNetwork() async throws {
        // Given
        catalogRepo.loadTopLevelCatalogResult = nil

        // When
        _ = try await catalogRepo.loadTopLevelCatalog(at: feedURL)

        // Then
        XCTAssertEqual(catalogRepo.loadTopLevelCatalogCallCount, 1,
                       "Should call loadTopLevelCatalog exactly once")
        XCTAssertEqual(catalogRepo.lastLoadURL, feedURL,
                       "Should load from the provided URL")
        XCTAssertEqual(catalogRepo.loadHistory.count, 1,
                       "Load history should contain one entry")
    }

    // SRS: REQ-CATALOG-003 — Cache invalidation forces fresh fetch
    func testCacheInvalidation_TriggersFreshFetch() async throws {
        // Given: Load once to populate cache
        catalogRepo.loadTopLevelCatalogResult = nil
        _ = try await catalogRepo.loadTopLevelCatalog(at: feedURL)

        // When: Invalidate cache and reload
        catalogRepo.invalidateCache(for: feedURL)
        _ = try await catalogRepo.loadTopLevelCatalog(at: feedURL)

        // Then
        XCTAssertEqual(catalogRepo.invalidateCacheCallCount, 1,
                       "Cache should be invalidated once")
        XCTAssertEqual(catalogRepo.lastInvalidatedURL, feedURL,
                       "Should invalidate cache for the correct URL")
        XCTAssertEqual(catalogRepo.loadTopLevelCatalogCallCount, 2,
                       "Should load twice: initial + post-invalidation")
    }

    // SRS: REQ-CATALOG-004 — Network failure propagates error
    func testNetworkFailure_PropagatesError() async {
        // Given
        catalogRepo.loadTopLevelCatalogError = CatalogRepositoryMockError.networkError

        // When / Then
        do {
            _ = try await catalogRepo.loadTopLevelCatalog(at: feedURL)
            XCTFail("Load should throw on network failure")
        } catch {
            XCTAssertTrue(error is CatalogRepositoryMockError,
                          "Should throw CatalogRepositoryMockError")
        }
        XCTAssertEqual(catalogRepo.loadTopLevelCatalogCallCount, 1,
                       "Failed load should still be recorded")
    }

    // SRS: REQ-CATALOG-005 — OPDS feed XML is parseable by NetworkClientMock
    func testOPDSFeedXML_IsGeneratedCorrectly() async throws {
        // Given: Stub an OPDS response via the network client
        let opdsXML = NetworkClientMock.makeOPDSFeedXML(title: "Test Library", entries: 3)
        networkClient.stubOPDSResponse(for: feedURL, xml: opdsXML)

        // When
        let request = NetworkRequest(method: .GET, url: feedURL)
        let response = try await networkClient.send(request)

        // Then
        XCTAssertEqual(response.response.statusCode, 200,
                       "OPDS response should have 200 status")
        let contentType = response.response.value(forHTTPHeaderField: "Content-Type")
        XCTAssertEqual(contentType, "application/atom+xml;profile=opds-catalog",
                       "Content-Type should be OPDS")

        let responseString = String(data: response.data, encoding: .utf8)
        XCTAssertNotNil(responseString, "Response data should be valid UTF-8")
        XCTAssertTrue(responseString!.contains("<title>Test Library</title>"),
                      "Feed should contain expected title")
        XCTAssertTrue(responseString!.contains("entry-0"),
                      "Feed should contain entry IDs")
        XCTAssertTrue(responseString!.contains("entry-2"),
                      "Feed should contain all 3 entries")
    }

    // SRS: REQ-CATALOG-006 — Authentication required returns 401
    func testAuthenticationRequired_ReturnsUnauthorizedError() async {
        // Given
        catalogRepo.loadTopLevelCatalogError = CatalogRepositoryMockError.unauthorized

        // When / Then
        do {
            _ = try await catalogRepo.loadTopLevelCatalog(at: feedURL)
            XCTFail("Load should throw when authentication is required")
        } catch let error as CatalogRepositoryMockError {
            if case .unauthorized = error {
                // Expected
            } else {
                XCTFail("Should be .unauthorized, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(type(of: error))")
        }
    }

    // SRS: REQ-CATALOG-007 — fetchFeed delegates to loadTopLevelCatalog
    func testFetchFeed_DelegatesToLoadTopLevelCatalog() async throws {
        // Given
        let altURL = URL(string: "https://catalog.example.com/subcategory")!
        catalogRepo.loadTopLevelCatalogResult = nil

        // When
        _ = try await catalogRepo.fetchFeed(at: altURL)

        // Then: fetchFeed delegates to loadTopLevelCatalog internally
        XCTAssertEqual(catalogRepo.loadTopLevelCatalogCallCount, 1,
                       "fetchFeed should delegate to loadTopLevelCatalog")
        XCTAssertEqual(catalogRepo.lastLoadURL, altURL,
                       "fetchFeed should pass the URL through")
    }
}
