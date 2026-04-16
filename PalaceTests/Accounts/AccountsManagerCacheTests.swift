//
//  AccountsManagerCacheTests.swift
//  PalaceTests
//
//  TDD tests for stale-while-revalidate caching in AccountsManager
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class AccountsManagerCacheTests: XCTestCase {

    // MARK: - Properties

    private var tempCacheDirectory: URL!

    // MARK: - Setup / Teardown

    override func setUp() {
        super.setUp()
        // Create a temp directory for cache testing
        tempCacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AccountsManagerCacheTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempCacheDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        // Clean up temp directory
        try? FileManager.default.removeItem(at: tempCacheDirectory)
        tempCacheDirectory = nil
        super.tearDown()
    }

    // MARK: - CatalogCacheMetadata Tests

    func testCatalogCacheMetadata_IsStale_ReturnsFalseWhenFresh() {
        // Given: metadata created just now
        let metadata = CatalogCacheMetadata(timestamp: Date(), hash: "testhash")

        // Then: should not be stale (within 5 minute threshold)
        XCTAssertFalse(metadata.isStale, "Fresh metadata should not be stale")
        // Fresh metadata must also not be expired
        XCTAssertFalse(metadata.isExpired, "Fresh metadata must not be expired either")
    }

    func testCatalogCacheMetadata_IsStale_ReturnsTrueAfter6Hours() {
        // Given: metadata created just over 6 hours ago (staleTTL is 21600s = 6 hours)
        let justOverSixHours = Date().addingTimeInterval(-21601)
        let metadata = CatalogCacheMetadata(timestamp: justOverSixHours, hash: "testhash")

        // Then: should be stale but not yet expired
        XCTAssertTrue(metadata.isStale, "Metadata older than 6 hours should be stale")
        XCTAssertFalse(metadata.isExpired, "Metadata only ~6 hours old must not be expired (24-hour threshold)")
    }

    func testCatalogCacheMetadata_IsStale_ReturnsFalseJustUnder6Hours() {
        // Given: metadata created just under 6 hours ago (5 hrs 59 min 59 sec)
        let justUnderSixHours = Date().addingTimeInterval(-21599)
        let metadata = CatalogCacheMetadata(timestamp: justUnderSixHours, hash: "testhash")

        // Then: should not be stale and not expired
        XCTAssertFalse(metadata.isStale, "Metadata under 6 hours should not be stale")
        XCTAssertFalse(metadata.isExpired, "Metadata under 6 hours must also not be expired")
    }

    func testCatalogCacheMetadata_IsExpired_ReturnsFalseWhenRecent() {
        // Given: metadata created 12 hours ago
        let twelveHoursAgo = Date().addingTimeInterval(-43200)
        let metadata = CatalogCacheMetadata(timestamp: twelveHoursAgo, hash: "testhash")

        // Then: should not be expired (within 24 hour threshold) but must be stale
        XCTAssertFalse(metadata.isExpired, "Metadata less than 24 hours old should not be expired")
        XCTAssertTrue(metadata.isStale, "Metadata 12 hours old must be stale (past 5-minute threshold)")
    }

    func testCatalogCacheMetadata_IsExpired_ReturnsTrueAfter24Hours() {
        // Given: metadata created 25 hours ago
        let twentyFiveHoursAgo = Date().addingTimeInterval(-90000)
        let metadata = CatalogCacheMetadata(timestamp: twentyFiveHoursAgo, hash: "testhash")

        // Then: should be both stale and expired
        XCTAssertTrue(metadata.isExpired, "Metadata older than 24 hours should be expired")
        XCTAssertTrue(metadata.isStale, "Metadata older than 24 hours must also be stale")
    }

    func testCatalogCacheMetadata_IsExpired_ReturnsFalseJustUnder24Hours() {
        // Given: metadata created just under 24 hours ago (23 hrs 59 min)
        let justUnder24Hours = Date().addingTimeInterval(-86399)
        let metadata = CatalogCacheMetadata(timestamp: justUnder24Hours, hash: "testhash")

        // Then: should not be expired, but must be stale (past 5-minute threshold)
        XCTAssertFalse(metadata.isExpired, "Metadata under 24 hours should not be expired")
        XCTAssertTrue(metadata.isStale, "Metadata near 24 hours old must be stale (past 5-minute threshold)")
    }

    func testCatalogCacheMetadata_Codable_EncodesAndDecodes() throws {
        // Given: metadata
        let original = CatalogCacheMetadata(timestamp: Date(), hash: "testhash123")

        // When: encoded and decoded
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CatalogCacheMetadata.self, from: data)

        // Then: values should match
        XCTAssertEqual(decoded.hash, original.hash)
        XCTAssertEqual(
            decoded.timestamp.timeIntervalSince1970,
            original.timestamp.timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    // MARK: - Cache Read/Write Tests

    func testWriteAndReadCacheMetadata() throws {
        // Given: a metadata to save
        let hash = "testhash"
        let metadata = CatalogCacheMetadata(timestamp: Date(), hash: hash)

        // When: saved and read back
        saveCacheMetadata(metadata, hash: hash)
        let readMetadata = readCacheMetadata(hash: hash)

        // Then: should match
        XCTAssertNotNil(readMetadata)
        XCTAssertEqual(readMetadata?.hash, hash)
    }

    func testReadCacheMetadata_ReturnsNilWhenNotExists() {
        // Given: no cached metadata
        let hash = "nonexistent-\(UUID().uuidString)"

        // When: trying to read
        let metadata = readCacheMetadata(hash: hash)

        // Then: should return nil
        XCTAssertNil(metadata)
        // Also verify data file returns nil (not just metadata)
        XCTAssertNil(readCachedCatalogData(hash: hash), "Non-existent cache must also return nil data")
    }

    // MARK: - Stale-While-Revalidate Behavior Tests

    func testLoadCatalogs_WhenCacheExists_CompletesWithCachedData() {
        // Given: valid cached catalog data exists on disk
        let hash = setupCachedCatalogData()

        // When: checking if cache exists
        let cachedData = readCachedCatalogData(hash: hash)

        // Then: cached data should be available
        XCTAssertNotNil(cachedData, "Cached catalog data should exist")

        // And: should be parseable
        if let data = cachedData {
            XCTAssertNoThrow(try OPDS2CatalogsFeed.fromData(data), "Cached data should be valid")
        }
    }

    func testLoadCatalogs_WhenCacheExpired_ReturnsNil() {
        // Given: expired cached catalog data (older than 24 hours)
        let hash = setupExpiredCachedCatalogData()

        // When: checking cache validity
        let metadata = readCacheMetadata(hash: hash)

        // Then: metadata should be expired
        XCTAssertNotNil(metadata)
        XCTAssertTrue(metadata?.isExpired ?? false, "Cache metadata should be expired")
    }

    func testLoadCatalogs_WhenCacheStale_ReturnsDataButMarkedStale() {
        // Given: stale cached catalog data (older than 5 minutes but less than 24 hours)
        let hash = setupStaleCachedCatalogData()

        // When: checking cache validity
        let metadata = readCacheMetadata(hash: hash)
        let cachedData = readCachedCatalogData(hash: hash)

        // Then: should have data but be marked stale
        XCTAssertNotNil(cachedData, "Stale cache should still return data")
        XCTAssertNotNil(metadata)
        XCTAssertTrue(metadata?.isStale ?? false, "Cache metadata should be stale")
        XCTAssertFalse(metadata?.isExpired ?? true, "Cache metadata should not be expired")
    }

    // MARK: - Integration-Style Tests

    func testCacheDataAndMetadata_AreWrittenTogether() {
        // Given: catalog data to cache
        let hash = "integrationtest-\(UUID().uuidString.prefix(8))"
        let feedData = loadTestFeedData()

        // Verify nothing is cached yet (precondition)
        XCTAssertNil(readCachedCatalogData(hash: hash), "Precondition: no data cached before write")
        XCTAssertNil(readCacheMetadata(hash: hash), "Precondition: no metadata cached before write")

        // When: caching the data
        cacheCatalogData(feedData, hash: hash)

        // Then: both data and metadata must be present
        guard let data = readCachedCatalogData(hash: hash) else {
            XCTFail("Catalog data must be written to disk by cacheCatalogData")
            return
        }
        guard let metadata = readCacheMetadata(hash: hash) else {
            XCTFail("Cache metadata must be written alongside catalog data")
            return
        }

        // Data integrity: the cached bytes must be parseable as a valid catalog feed
        XCTAssertNoThrow(try OPDS2CatalogsFeed.fromData(data),
                         "Cached catalog data must parse as a valid OPDS2CatalogsFeed")
        // Metadata integrity
        XCTAssertEqual(metadata.hash, hash, "Cached metadata hash must match the key used during write")
        XCTAssertFalse(metadata.isStale, "Freshly written cache must not be considered stale")
        XCTAssertFalse(metadata.isExpired, "Freshly written cache must not be considered expired")
    }

    func testCacheExpiry_OldCacheIsNotUsed() {
        // Given: very old cached data
        let hash = "oldcache"
        let feedData = loadTestFeedData()

        // Cache with very old timestamp
        let oldTimestamp = Date().addingTimeInterval(-100000) // ~28 hours ago
        let metadata = CatalogCacheMetadata(timestamp: oldTimestamp, hash: hash)

        // Write data
        let dataURL = tempCacheDirectory.appendingPathComponent("accounts_catalog_\(hash).json")
        try? feedData.write(to: dataURL)

        // Write old metadata
        saveCacheMetadata(metadata, hash: hash)

        // When: checking validity
        let readMetadata = readCacheMetadata(hash: hash)

        // Then: should be expired and not usable
        XCTAssertTrue(readMetadata?.isExpired ?? false, "Old cache should be expired")
    }

    // MARK: - Notification Tests

    func testNotification_TPPCatalogDidLoad_IsDeliveredToObserver() {
        // Arrange: register an observer for the catalog-did-load notification
        let expectation = XCTestExpectation(description: "TPPCatalogDidLoad observer fires")
        var receivedNotification: Notification?

        let observer = NotificationCenter.default.addObserver(
            forName: .TPPCatalogDidLoad,
            object: nil,
            queue: nil
        ) { notification in
            receivedNotification = notification
            expectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        // Act: post the notification
        NotificationCenter.default.post(name: .TPPCatalogDidLoad, object: nil)

        // Assert: the observer fired and the received notification has the correct name
        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(receivedNotification?.name, .TPPCatalogDidLoad,
                       "Observer should receive a notification with the .TPPCatalogDidLoad name")
    }

    // MARK: - Test Helpers

    private func loadTestFeedData() -> Data {
        let feedURL = Bundle(for: type(of: self))
            .url(forResource: "OPDS2CatalogsFeed", withExtension: "json")!
        return try! Data(contentsOf: feedURL)
    }

    private func setupCachedCatalogData() -> String {
        let hash = "freshcache-\(UUID().uuidString.prefix(8))"
        let feedData = loadTestFeedData()
        cacheCatalogData(feedData, hash: hash)
        return hash
    }

    private func setupStaleCachedCatalogData() -> String {
        let hash = "stalecache-\(UUID().uuidString.prefix(8))"
        let feedData = loadTestFeedData()

        // Write data
        let dataURL = tempCacheDirectory.appendingPathComponent("accounts_catalog_\(hash).json")
        try? feedData.write(to: dataURL)

        // Write stale metadata (7 hours ago — past 6-hour staleTTL but under 24-hour expiry)
        let staleTimestamp = Date().addingTimeInterval(-25200)
        let metadata = CatalogCacheMetadata(timestamp: staleTimestamp, hash: hash)
        saveCacheMetadata(metadata, hash: hash)

        return hash
    }

    private func setupExpiredCachedCatalogData() -> String {
        let hash = "expiredcache-\(UUID().uuidString.prefix(8))"
        let feedData = loadTestFeedData()

        // Write data
        let dataURL = tempCacheDirectory.appendingPathComponent("accounts_catalog_\(hash).json")
        try? feedData.write(to: dataURL)

        // Write expired metadata (25 hours ago)
        let expiredTimestamp = Date().addingTimeInterval(-90000)
        let metadata = CatalogCacheMetadata(timestamp: expiredTimestamp, hash: hash)
        saveCacheMetadata(metadata, hash: hash)

        return hash
    }

    private func cacheCatalogData(_ data: Data, hash: String) {
        // Write catalog data
        let dataURL = tempCacheDirectory.appendingPathComponent("accounts_catalog_\(hash).json")
        try? data.write(to: dataURL)

        // Write fresh metadata
        let metadata = CatalogCacheMetadata(timestamp: Date(), hash: hash)
        saveCacheMetadata(metadata, hash: hash)
    }

    private func readCachedCatalogData(hash: String) -> Data? {
        let url = tempCacheDirectory.appendingPathComponent("accounts_catalog_\(hash).json")
        return try? Data(contentsOf: url)
    }

    private func saveCacheMetadata(_ metadata: CatalogCacheMetadata, hash: String) {
        let url = tempCacheDirectory.appendingPathComponent("accounts_catalog_metadata_\(hash).json")
        if let data = try? JSONEncoder().encode(metadata) {
            try? data.write(to: url)
        }
    }

    private func readCacheMetadata(hash: String) -> CatalogCacheMetadata? {
        let url = tempCacheDirectory.appendingPathComponent("accounts_catalog_metadata_\(hash).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CatalogCacheMetadata.self, from: data)
    }
}
