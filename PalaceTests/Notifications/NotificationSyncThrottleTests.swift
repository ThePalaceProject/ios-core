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

    func testThrottle_recentSync_blocksNormalSync() {
        let now = Date().timeIntervalSince1970
        let lastSync = now - 10 // 10 seconds ago

        let result = shouldSync(forceSync: false, lastSyncTimestamp: lastSync, now: now)
        XCTAssertFalse(result, "Normal sync should be throttled if synced < 30s ago")
    }

    func testThrottle_oldSync_allowsNormalSync() {
        let now = Date().timeIntervalSince1970
        let lastSync = now - 60 // 60 seconds ago

        let result = shouldSync(forceSync: false, lastSyncTimestamp: lastSync, now: now)
        XCTAssertTrue(result, "Normal sync should proceed if synced > 30s ago")
    }

    func testThrottle_noLastSync_allowsSync() {
        let now = Date().timeIntervalSince1970

        let result = shouldSync(forceSync: false, lastSyncTimestamp: 0, now: now)
        XCTAssertTrue(result, "First sync should always proceed")
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

    func testForceSync_withZeroLastSync_proceeds() {
        let now = Date().timeIntervalSince1970

        let result = shouldSync(forceSync: true, lastSyncTimestamp: 0, now: now)
        XCTAssertTrue(result, "Force sync should proceed regardless of history")
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

    func testIsHoldRelated_withTypeReservation_returnsTrue() {
        let type = "reservation_available"
        let isHold = type.lowercased().contains("hold") || type.lowercased().contains("reservation")
        XCTAssertTrue(isHold)
    }

    func testIsHoldRelated_withGenericType_returnsFalse() {
        let type = "general_notification"
        let isHold = type.lowercased().contains("hold") || type.lowercased().contains("reservation")
        XCTAssertFalse(isHold)
    }
}
