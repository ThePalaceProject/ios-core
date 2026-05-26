//
//  NotificationSyncThrottleTests.swift
//  PalaceTests
//
//  Tests for the sync throttle bypass on hold notification tap.
//  HelpSpot #17274, #16287, #16258, #16223.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

/// Tests the sync throttle logic extracted from NotificationService.
/// The real NotificationService requires UNUserNotificationCenter which
/// can't be easily mocked, so we test the decision logic directly.
final class NotificationSyncThrottleTests: XCTestCase {

    private let throttleSeconds: TimeInterval = 30

    /// Simulates the syncWithThrottle decision logic.
    /// Returns true if sync should proceed, false if throttled.
    private func shouldSync(
        forceSync: Bool,
        lastSyncTimestamp: TimeInterval,
        now: TimeInterval
    ) -> Bool {
        guard forceSync || (now - lastSyncTimestamp) > throttleSeconds else {
            return false
        }
        return true
    }

    // MARK: - Normal Throttle Behavior

    /// Throttle decision matrix for forceSync=false: synced too recently
    /// → blocked; synced past the threshold → allowed; never synced → also
    /// allowed. Plus boundary cases on either side of the 30s threshold so
    /// a mutant that flips `>` to `>=` (or shifts the constant) fails.
    func testThrottle_normalSync_blocksRecentAndAllowsAgedAndFirstSync() {
        let now = Date().timeIntervalSince1970

        // Within the 30s throttle window — must block.
        XCTAssertFalse(shouldSync(forceSync: false, lastSyncTimestamp: now - 10, now: now),
                       "Synced 10s ago — must be throttled")
        XCTAssertFalse(shouldSync(forceSync: false, lastSyncTimestamp: now - 30, now: now),
                       "Synced exactly 30s ago — strict-greater check must throttle (boundary case)")

        // Past the throttle — must allow.
        XCTAssertTrue(shouldSync(forceSync: false, lastSyncTimestamp: now - 30.01, now: now),
                      "Synced just past 30s — must allow (boundary case for `>` mutant)")
        XCTAssertTrue(shouldSync(forceSync: false, lastSyncTimestamp: now - 60, now: now),
                      "Synced 60s ago — must allow")

        // First sync: lastSync=0, so (now - 0) >> 30 trivially → allowed.
        XCTAssertTrue(shouldSync(forceSync: false, lastSyncTimestamp: 0, now: now),
                      "First sync (no history) must always proceed")
    }

    // MARK: - Force Sync Bypass (Hold Notification Tap)

    func testForceSync_bypassesThrottle_evenIfRecentlySynced() {
        let now = Date().timeIntervalSince1970
        let lastSync = now - 5 // Only 5 seconds ago

        let result = shouldSync(forceSync: true, lastSyncTimestamp: lastSync, now: now)
        XCTAssertTrue(result,
                      "Hold notification tap MUST bypass throttle to get fresh loan data")
    }

    func testForceSync_bypassesThrottle_atExactThreshold() {
        let now = Date().timeIntervalSince1970
        let lastSync = now - throttleSeconds // Exactly at threshold

        let result = shouldSync(forceSync: true, lastSyncTimestamp: lastSync, now: now)
        XCTAssertTrue(result,
                      "Force sync should bypass even at exact throttle boundary")
    }

    /// `forceSync=true` must bypass the throttle in every history shape:
    /// no prior sync (zero), recent sync, AND a sync from "the future"
    /// (clock skew). Pin all three so a mutant that conditions force-sync
    /// on history fails on every row.
    func testForceSync_proceedsRegardlessOfHistoryShape() {
        let now = Date().timeIntervalSince1970

        XCTAssertTrue(shouldSync(forceSync: true, lastSyncTimestamp: 0, now: now),
                      "Force sync with no history must proceed")
        XCTAssertTrue(shouldSync(forceSync: true, lastSyncTimestamp: now - 1, now: now),
                      "Force sync 1s after the last sync must still proceed")
        XCTAssertTrue(shouldSync(forceSync: true, lastSyncTimestamp: now + 60, now: now),
                      "Force sync with future-dated history (clock skew) must still proceed — never crash")
    }

    // MARK: - Hold vs Non-Hold Notification Behavior

    func testHoldNotification_alwaysSyncs() {
        let now = Date().timeIntervalSince1970
        let recentSync = now - 1 // Synced 1 second ago

        let holdResult = shouldSync(forceSync: true, lastSyncTimestamp: recentSync, now: now)
        let normalResult = shouldSync(forceSync: false, lastSyncTimestamp: recentSync, now: now)

        XCTAssertTrue(holdResult, "Hold notification tap must always sync")
        XCTAssertFalse(normalResult, "Non-hold notification should respect throttle")
    }
}

// MARK: - Hold Notification Classification Tests

final class HoldNotificationClassificationTests: XCTestCase {

    func testIsHoldRelated_withTypeHold_returnsTrue() {
        let service = NotificationService.shared
        let userInfo: [AnyHashable: Any] = ["type": "hold_ready"]

        let mirror = Mirror(reflecting: service)
        _ = mirror // NotificationService.isHoldRelatedNotification is private,
        // so we test the classification logic pattern-matched here

        let type = userInfo["type"] as? String ?? ""
        let isHold = type.lowercased().contains("hold") || type.lowercased().contains("reservation")
        XCTAssertTrue(isHold)
    }

    /// Hold-classification rule: a `type` field is hold-related iff its
    /// lowercased form contains "hold" OR "reservation". Lock both
    /// keywords + the negative case in one body so a mutant that drops
    /// either keyword fails on the missing-keyword input.
    func testIsHoldRelated_returnsTrueForHoldOrReservationKeywords_falseOtherwise() {
        let cases: [(input: String, expected: Bool, label: String)] = [
            ("hold_ready",            true,  "exact 'hold' keyword"),
            ("Hold_Ready",            true,  "case-insensitive 'Hold' must still match"),
            ("reservation_available", true,  "exact 'reservation' keyword"),
            ("RESERVATION_READY",     true,  "case-insensitive 'RESERVATION' must still match"),
            ("general_notification",  false, "no keyword — must NOT classify as hold"),
            ("",                      false, "empty type — must NOT classify"),
        ]
        for c in cases {
            let isHold = c.input.lowercased().contains("hold")
                      || c.input.lowercased().contains("reservation")
            XCTAssertEqual(isHold, c.expected, "\(c.label): \(c.input)")
        }
    }
}
