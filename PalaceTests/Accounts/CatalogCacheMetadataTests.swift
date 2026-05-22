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

    // MARK: - isStale (default TTL = 6 hours)

    func testIsStale_TransitionsAtSixHourBoundary() {
        let justUnder = CatalogCacheMetadata(
            timestamp: Date().addingTimeInterval(-21599),
            hash: "abc"
        )
        let justOver = CatalogCacheMetadata(
            timestamp: Date().addingTimeInterval(-21601),
            hash: "abc"
        )
        XCTAssertFalse(justUnder.isStale, "5h59m59s old must be fresh")
        XCTAssertTrue(justOver.isStale, "6h00m01s old must be stale")
    }

    func testIsStale_FreshCache_StaysFreshAcrossSubSecondJitter() {
        let now = CatalogCacheMetadata(timestamp: Date(), hash: "abc")
        let oneSecondOld = CatalogCacheMetadata(
            timestamp: Date().addingTimeInterval(-1),
            hash: "abc"
        )
        XCTAssertFalse(now.isStale)
        XCTAssertFalse(now.isExpired)
        XCTAssertFalse(oneSecondOld.isStale)
    }

    func testIsStale_DeepInsideTTL_RemainsFresh() {
        // Sanity check: a 5-hour-old cache must not be stale, ruling out
        // an off-by-an-hour-unit bug (e.g. seconds vs minutes mix-up).
        let fiveHoursAgo = CatalogCacheMetadata(
            timestamp: Date().addingTimeInterval(-18000),
            hash: "abc"
        )
        XCTAssertFalse(fiveHoursAgo.isStale)
        XCTAssertFalse(fiveHoursAgo.isExpired)
    }

    // MARK: - staleTTL(serverMaxAge:) — half-of-server clamped to [5min, 12hr]

    func testStaleTTL_HalvesServerMaxAgeInMidRange() {
        // 12-hour server max-age → 6-hour stale window (default expectation)
        XCTAssertEqual(CatalogCacheMetadata.staleTTL(serverMaxAge: 43200), 21600)
        // 4-hour server max-age → 2-hour stale window
        XCTAssertEqual(CatalogCacheMetadata.staleTTL(serverMaxAge: 14400), 7200)
        // 1-hour server max-age → 30-minute stale window
        XCTAssertEqual(CatalogCacheMetadata.staleTTL(serverMaxAge: 3600), 1800)
    }

    func testStaleTTL_ClampsBelowFiveMinutesUpToFloor() {
        // Half of 60s would be 30s; floor pushes it to 5min (300s).
        XCTAssertEqual(CatalogCacheMetadata.staleTTL(serverMaxAge: 60), 300)
        // Half of 0 hits the nil-or-nonpositive guard and uses default.
        XCTAssertEqual(CatalogCacheMetadata.staleTTL(serverMaxAge: 0), 21600)
        // Half of 599s = 299.5s, clamped up to 300s.
        XCTAssertEqual(CatalogCacheMetadata.staleTTL(serverMaxAge: 599), 300)
    }

    func testStaleTTL_ClampsAboveTwelveHoursDownToCeiling() {
        // Half of 48h = 24h; ceiling caps at 12h (43200s).
        XCTAssertEqual(CatalogCacheMetadata.staleTTL(serverMaxAge: 172800), 43200)
        // Half of 24h = 12h, exactly at ceiling.
        XCTAssertEqual(CatalogCacheMetadata.staleTTL(serverMaxAge: 86400), 43200)
        // Just over the ceiling input — still clamped.
        XCTAssertEqual(CatalogCacheMetadata.staleTTL(serverMaxAge: 86401), 43200)
    }

    func testStaleTTL_NilOrNegativeServerMaxAge_UsesDefault() {
        XCTAssertEqual(CatalogCacheMetadata.staleTTL(serverMaxAge: nil), 21600)
        XCTAssertEqual(CatalogCacheMetadata.staleTTL(serverMaxAge: -100), 21600)
    }

    func testIsStale_WithServerMaxAge_RespectsOverride() {
        let sixMinutesAgo = CatalogCacheMetadata(
            timestamp: Date().addingTimeInterval(-360),
            hash: "abc"
        )
        // Custom server max-age 600s → 5-min TTL → 6-min-old IS stale
        XCTAssertTrue(sixMinutesAgo.isStale(serverMaxAge: 600))
        // Default 6-hour TTL → 6-min-old is NOT stale
        XCTAssertFalse(sixMinutesAgo.isStale(serverMaxAge: 43200))
        // Sanity: convenience property uses default, must agree
        XCTAssertFalse(sixMinutesAgo.isStale)
    }

    // MARK: - isExpired (always 24 hours)

    func testIsExpired_TransitionsAtTwentyFourHourBoundary() {
        let justUnder = CatalogCacheMetadata(
            timestamp: Date().addingTimeInterval(-86399),
            hash: "abc"
        )
        let justOver = CatalogCacheMetadata(
            timestamp: Date().addingTimeInterval(-86401),
            hash: "abc"
        )
        XCTAssertFalse(justUnder.isExpired, "23h59m59s old must not be expired")
        XCTAssertTrue(justOver.isExpired, "24h00m01s old must be expired")
        // Both sit comfortably past the 6h stale boundary
        XCTAssertTrue(justUnder.isStale)
        XCTAssertTrue(justOver.isStale)
    }

    // MARK: - Lifecycle invariants

    func testCacheLifecycle_FreshThenStaleThenExpired() {
        // Three checkpoints walking the same cache forward in time.
        let fresh = CatalogCacheMetadata(timestamp: Date(), hash: "h")
        let stale = CatalogCacheMetadata(
            timestamp: Date().addingTimeInterval(-25200), // 7h
            hash: "h"
        )
        let expired = CatalogCacheMetadata(
            timestamp: Date().addingTimeInterval(-90000), // 25h
            hash: "h"
        )
        XCTAssertFalse(fresh.isStale);   XCTAssertFalse(fresh.isExpired)
        XCTAssertTrue(stale.isStale);    XCTAssertFalse(stale.isExpired)
        XCTAssertTrue(expired.isStale);  XCTAssertTrue(expired.isExpired)
    }

    func testInvariant_ExpiredImpliesStale() {
        // Across a span of ages past 24h, isExpired must always imply isStale.
        // (Stale TTL ≤ 12h, expiry = 24h, so this is structural — but a
        // mutant flipping the comparison operator would break it.)
        for hoursOld in [25, 48, 168, 720] {
            let metadata = CatalogCacheMetadata(
                timestamp: Date().addingTimeInterval(-Double(hoursOld) * 3600),
                hash: "h"
            )
            XCTAssertTrue(metadata.isExpired, "\(hoursOld)h old must be expired")
            XCTAssertTrue(metadata.isStale, "\(hoursOld)h old must be stale")
        }
    }

    // MARK: - Encoding/Decoding

    func testEncodeDecode_PreservesAllProperties() throws {
        let original = CatalogCacheMetadata(
            timestamp: Date(),
            hash: "test-hash-12345"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CatalogCacheMetadata.self, from: data)
        XCTAssertEqual(
            decoded.timestamp.timeIntervalSince1970,
            original.timestamp.timeIntervalSince1970,
            accuracy: 1
        )
        XCTAssertEqual(decoded.hash, original.hash)
        // Round-tripped metadata must agree on freshness with the original.
        XCTAssertEqual(decoded.isStale, original.isStale)
        XCTAssertEqual(decoded.isExpired, original.isExpired)
    }

    // MARK: - Edge Cases

    func testIsStale_FutureTimestamp_TreatsAsFresh() {
        // Clock skew can produce a timestamp in the future; the type must
        // not crash or report stale (negative timeIntervalSince).
        let oneHourAhead = CatalogCacheMetadata(
            timestamp: Date().addingTimeInterval(3600),
            hash: "future"
        )
        XCTAssertFalse(oneHourAhead.isStale)
        XCTAssertFalse(oneHourAhead.isExpired)
        // Even with a tiny serverMaxAge override, future timestamp stays fresh.
        XCTAssertFalse(oneHourAhead.isStale(serverMaxAge: 60))
    }

    func testIsExpired_EpochTimestamp_IsAlwaysStaleAndExpired() {
        let epoch = CatalogCacheMetadata(
            timestamp: Date(timeIntervalSince1970: 0),
            hash: "epoch"
        )
        XCTAssertTrue(epoch.isStale)
        XCTAssertTrue(epoch.isExpired)
    }

    // MARK: - isBundled sentinel (force-stale on build-time snapshot writes)

    func testIsBundled_DefaultsFalse_ForBackCompat() {
        // Convenience initializer omits isBundled so existing call sites
        // and legacy decoded metadata continue to behave like network caches.
        let metadata = CatalogCacheMetadata(timestamp: Date(), hash: "h")
        XCTAssertFalse(metadata.isBundled)
    }

    func testIsBundled_True_ForcesStaleness_RegardlessOfFreshTimestamp() {
        // A bundled-origin cache MUST always trip refresh, even when the
        // timestamp says it was just written. The disk-cached bytes are
        // usable for immediate display but not authoritative.
        let justWritten = CatalogCacheMetadata(
            timestamp: Date(),
            hash: "h",
            isBundled: true
        )
        XCTAssertTrue(justWritten.isStale)
        XCTAssertTrue(justWritten.isStale(serverMaxAge: 43200))
        XCTAssertTrue(justWritten.isStale(serverMaxAge: nil))
    }

    func testIsBundled_True_ForcesStaleness_AcrossAllServerMaxAges() {
        // Sweep the bracketing values that affect the network-cache TTL
        // (the floor at 5min, mid-range, and the ceiling at 12h) — none
        // of them should override the bundled force-stale path.
        let bundled = CatalogCacheMetadata(
            timestamp: Date(),
            hash: "h",
            isBundled: true
        )
        for maxAge in [TimeInterval?.none, 60, 600, 3600, 43200, 86400] {
            XCTAssertTrue(
                bundled.isStale(serverMaxAge: maxAge),
                "isBundled=true must force stale for serverMaxAge=\(String(describing: maxAge))"
            )
        }
    }

    func testIsBundled_False_PreservesExistingStalenessBehavior() {
        // The opposite branch: a network-origin cache (isBundled=false)
        // must still respect the timestamp + serverMaxAge logic that
        // existed before the sentinel landed.
        let freshNetwork = CatalogCacheMetadata(
            timestamp: Date(),
            hash: "h",
            isBundled: false
        )
        let oldNetwork = CatalogCacheMetadata(
            timestamp: Date().addingTimeInterval(-25200), // 7h
            hash: "h",
            isBundled: false
        )
        XCTAssertFalse(freshNetwork.isStale)
        XCTAssertTrue(oldNetwork.isStale)
    }

    func testDecode_LegacyMetadataWithoutIsBundledField_DefaultsToFalse() throws {
        // On-disk metadata written before this field existed must still
        // decode cleanly and default to isBundled=false so legacy caches
        // continue to behave like the network-origin caches they were.
        let legacyJSON = #"""
        {"timestamp": 750000000, "hash": "legacy-hash"}
        """#.data(using: .utf8)!

        let metadata = try JSONDecoder().decode(CatalogCacheMetadata.self, from: legacyJSON)
        XCTAssertEqual(metadata.hash, "legacy-hash")
        XCTAssertFalse(metadata.isBundled,
                       "Legacy metadata without isBundled must default to false")
    }

    func testEncodeDecode_PreservesIsBundledTrue() throws {
        let original = CatalogCacheMetadata(
            timestamp: Date(),
            hash: "bundled-hash",
            isBundled: true
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CatalogCacheMetadata.self, from: data)
        XCTAssertTrue(decoded.isBundled)
        XCTAssertEqual(decoded.hash, original.hash)
        XCTAssertTrue(decoded.isStale,
                      "Round-tripped bundled cache must still report stale")
    }

    func testEncodeDecode_PreservesIsBundledFalse_Explicitly() throws {
        // Distinct from the legacy-decode case — when the field IS written
        // with `false`, the round-trip must preserve `false` (not flip to
        // some surprise default).
        let original = CatalogCacheMetadata(
            timestamp: Date(),
            hash: "network-hash",
            isBundled: false
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CatalogCacheMetadata.self, from: data)
        XCTAssertFalse(decoded.isBundled)
        XCTAssertFalse(decoded.isStale)
    }
}
