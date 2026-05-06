//
//  CatalogCacheMetadataTests.swift
//  PalaceTests
//
//  Unit tests for CatalogCacheMetadata struct.
//  Tests cache staleness and expiration calculations.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class CatalogCacheMetadataTests: XCTestCase {

    // MARK: - isStale Tests (default TTL = 6 hours)

    func testIsStale_WithFreshCache_ReturnsFalse() {
        let metadata = CatalogCacheMetadata(timestamp: Date(), hash: "abc123")
        XCTAssertFalse(metadata.isStale)
    }

    func testIsStale_WithCacheUnder6Hours_ReturnsFalse() {
        let fiveHoursAgo = Date().addingTimeInterval(-18000)
        let metadata = CatalogCacheMetadata(timestamp: fiveHoursAgo, hash: "abc123")
        XCTAssertFalse(metadata.isStale)
    }

    func testIsStale_WithCacheJustUnder6Hours_ReturnsFalse() {
        let justUnder = Date().addingTimeInterval(-21599)
        let metadata = CatalogCacheMetadata(timestamp: justUnder, hash: "abc123")
        XCTAssertFalse(metadata.isStale)
    }

    func testIsStale_WithCacheOver6Hours_ReturnsTrue() {
        let sevenHoursAgo = Date().addingTimeInterval(-25200)
        let metadata = CatalogCacheMetadata(timestamp: sevenHoursAgo, hash: "abc123")
        XCTAssertTrue(metadata.isStale)
    }

    func testIsStale_WithCacheJustOver6Hours_ReturnsTrue() {
        let justOver = Date().addingTimeInterval(-21601)
        let metadata = CatalogCacheMetadata(timestamp: justOver, hash: "abc123")
        XCTAssertTrue(metadata.isStale)
    }

    // MARK: - Dynamic TTL via serverMaxAge

    func testStaleTTL_UsesHalfOfServerMaxAge() {
        XCTAssertEqual(CatalogCacheMetadata.staleTTL(serverMaxAge: 43200), 21600)
    }

    func testStaleTTL_ClampsToMinimum5Minutes() {
        XCTAssertEqual(CatalogCacheMetadata.staleTTL(serverMaxAge: 60), 300)
    }

    func testStaleTTL_ClampsToMaximum12Hours() {
        XCTAssertEqual(CatalogCacheMetadata.staleTTL(serverMaxAge: 172800), 43200)
    }

    func testStaleTTL_NilServerMaxAge_UsesDefault() {
        XCTAssertEqual(CatalogCacheMetadata.staleTTL(serverMaxAge: nil), 21600)
    }

    func testIsStale_WithServerMaxAge_UsesCustomTTL() {
        let sixMinutesAgo = Date().addingTimeInterval(-360)
        let metadata = CatalogCacheMetadata(timestamp: sixMinutesAgo, hash: "abc123")
        XCTAssertTrue(metadata.isStale(serverMaxAge: 600), "6min > 5min custom TTL")
        XCTAssertFalse(metadata.isStale(serverMaxAge: 43200), "6min < 6hr default TTL")
    }

    // MARK: - isExpired Tests (always 24 hours)

    func testIsExpired_WithFreshCache_ReturnsFalse() {
        let metadata = CatalogCacheMetadata(timestamp: Date(), hash: "abc123")
        XCTAssertFalse(metadata.isExpired)
    }

    func testIsExpired_WithCacheUnder24Hours_ReturnsFalse() {
        let twentyThreeHoursAgo = Date().addingTimeInterval(-82800)
        let metadata = CatalogCacheMetadata(timestamp: twentyThreeHoursAgo, hash: "abc123")
        XCTAssertFalse(metadata.isExpired)
        XCTAssertTrue(metadata.isStale, "23-hour-old cache is stale but not expired")
    }

    func testIsExpired_WithCacheOver24Hours_ReturnsTrue() {
        let twentyFiveHoursAgo = Date().addingTimeInterval(-90000)
        let metadata = CatalogCacheMetadata(timestamp: twentyFiveHoursAgo, hash: "abc123")
        XCTAssertTrue(metadata.isExpired)
        XCTAssertTrue(metadata.isStale, "Expired cache is always stale")
    }

    func testIsExpired_WithCacheJustOver24Hours_ReturnsTrue() {
        let justOver = Date().addingTimeInterval(-86401)
        let metadata = CatalogCacheMetadata(timestamp: justOver, hash: "abc123")
        XCTAssertTrue(metadata.isExpired)
    }

    // MARK: - Combined State

    func testStaleAndExpired_FreshCache_NeitherStaleNorExpired() {
        let metadata = CatalogCacheMetadata(timestamp: Date(), hash: "abc123")
        XCTAssertFalse(metadata.isStale)
        XCTAssertFalse(metadata.isExpired)
    }

    func testStaleAndExpired_StaleButNotExpired() {
        let sevenHoursAgo = Date().addingTimeInterval(-25200)
        let metadata = CatalogCacheMetadata(timestamp: sevenHoursAgo, hash: "abc123")
        XCTAssertTrue(metadata.isStale)
        XCTAssertFalse(metadata.isExpired)
    }

    func testStaleAndExpired_ExpiredCacheIsAlsoStale() {
        let twentyFiveHoursAgo = Date().addingTimeInterval(-90000)
        let metadata = CatalogCacheMetadata(timestamp: twentyFiveHoursAgo, hash: "abc123")
        XCTAssertTrue(metadata.isStale)
        XCTAssertTrue(metadata.isExpired)
    }

    // MARK: - Encoding/Decoding

    func testEncodeDecode_PreservesAllProperties() throws {
        let original = CatalogCacheMetadata(timestamp: Date(), hash: "test-hash-12345")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CatalogCacheMetadata.self, from: data)
        XCTAssertEqual(decoded.timestamp.timeIntervalSince1970, original.timestamp.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(decoded.hash, original.hash)
    }

    // MARK: - Edge Cases

    func testIsStale_WithFutureTimestamp_ReturnsFalse() {
        let futureDate = Date().addingTimeInterval(3600)
        let metadata = CatalogCacheMetadata(timestamp: futureDate, hash: "future")
        XCTAssertFalse(metadata.isStale)
        XCTAssertFalse(metadata.isExpired)
    }

    func testIsExpired_WithVeryOldTimestamp() {
        let veryOldDate = Date(timeIntervalSince1970: 0)
        let metadata = CatalogCacheMetadata(timestamp: veryOldDate, hash: "old")
        XCTAssertTrue(metadata.isStale)
        XCTAssertTrue(metadata.isExpired)
    }
}
