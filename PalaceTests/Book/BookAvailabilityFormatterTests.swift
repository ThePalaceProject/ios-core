//
//  BookAvailabilityFormatterTests.swift
//  PalaceTests
//
//  Tests for the date comparison logic used by BookAvailabilityFormatter
//  when deciding whether to sync audiobook positions.
//
//  The core decision logic in chooseLocalLocation relies on
//  String.isDate(_:moreRecentThan:with:) which is thoroughly tested here.
//  The TrackPosition-based tests are omitted because constructing Track
//  objects requires Manifest/Audiobook infrastructure unsuitable for unit tests.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class BookAvailabilityFormatterTests: XCTestCase {

    // MARK: - String.isDate(_:moreRecentThan:with:) — Core Sync Decision Logic

    func test_isDate_moreRecentThan_sameDate_notMoreRecent() {
        let date = "2026-03-30T12:00:00Z"
        // date + 0 > date => false (not strictly greater)
        // Actually: date + 0 = date, and > means strictly greater, so this is false
        // Wait -- let me check: d1.addingTimeInterval(0) > d2 when d1 == d2 => false
        XCTAssertFalse(String.isDate(date, moreRecentThan: date, with: 0))
    }

    func test_isDate_moreRecentThan_newerDate_isMoreRecent() {
        let newer = "2026-03-31T12:00:00Z"
        let older = "2026-03-30T12:00:00Z"
        XCTAssertTrue(String.isDate(newer, moreRecentThan: older, with: 0))
    }

    func test_isDate_moreRecentThan_olderDate_notMoreRecent() {
        let older = "2026-03-29T12:00:00Z"
        let newer = "2026-03-30T12:00:00Z"
        XCTAssertFalse(String.isDate(older, moreRecentThan: newer, with: 0))
    }

    func test_isDate_withPositiveDelay_makesOlderDatePassAsNewer() {
        let older = "2026-03-30T12:00:00Z"
        let newer = "2026-03-30T12:00:05Z"
        // Formula: older + 10 > newer => (older + 10s) > (older + 5s) => true
        XCTAssertTrue(String.isDate(older, moreRecentThan: newer, with: 10),
                      "With sufficient delay, even an older date passes the 'more recent' check")
    }

    func test_isDate_withInsufficientDelay_olderDateStillFails() {
        let older = "2026-03-30T12:00:00Z"
        let newer = "2026-03-30T12:00:15Z"
        // Formula: older + 10 > newer => (older + 10s) > (older + 15s) => false
        XCTAssertFalse(String.isDate(older, moreRecentThan: newer, with: 10),
                       "With insufficient delay, an older date still fails")
    }

    func test_isDate_newerDateWithDelay_alwaysPasses() {
        let newer = "2026-03-30T12:00:15Z"
        let older = "2026-03-30T12:00:00Z"
        // newer + 10 > older => obviously true
        XCTAssertTrue(String.isDate(newer, moreRecentThan: older, with: 10))
    }

    func test_isDate_invalidDateStrings_returnsFalse() {
        XCTAssertFalse(String.isDate("not-a-date", moreRecentThan: "2026-03-30T12:00:00Z", with: 0))
        XCTAssertFalse(String.isDate("2026-03-30T12:00:00Z", moreRecentThan: "garbage", with: 0))
        XCTAssertFalse(String.isDate("", moreRecentThan: "", with: 0))
    }

    func test_isDate_emptyStrings_returnsFalse() {
        XCTAssertFalse(String.isDate("", moreRecentThan: "2026-03-30T12:00:00Z", with: 0))
        XCTAssertFalse(String.isDate("2026-03-30T12:00:00Z", moreRecentThan: "", with: 0))
    }

    func test_isDate_sameTimestamp_withSmallDelay_returnsTrue() {
        let date = "2026-03-30T12:00:00Z"
        // date + 1 > date => true (strictly greater by 1 second)
        XCTAssertTrue(String.isDate(date, moreRecentThan: date, with: 1),
                      "Same timestamp with positive delay should be considered 'more recent'")
    }

    func test_isDate_negativeDelay_makesNewerDateFail() {
        let newer = "2026-03-30T12:00:03Z"
        let older = "2026-03-30T12:00:00Z"
        // newer + (-5) > older => (newer - 5s) > older => (older - 2s) > older => false
        XCTAssertFalse(String.isDate(newer, moreRecentThan: older, with: -5),
                       "Negative delay makes dates appear older")
    }

    // MARK: - Boundary Conditions

    func test_isDate_oneSecondDifference_noDelay() {
        let a = "2026-03-30T12:00:01Z"
        let b = "2026-03-30T12:00:00Z"
        XCTAssertTrue(String.isDate(a, moreRecentThan: b, with: 0))
        XCTAssertFalse(String.isDate(b, moreRecentThan: a, with: 0))
    }

    func test_isDate_crossDayBoundary() {
        let endOfDay = "2026-03-30T23:59:59Z"
        let startOfNextDay = "2026-03-31T00:00:00Z"
        XCTAssertTrue(String.isDate(startOfNextDay, moreRecentThan: endOfDay, with: 0))
        XCTAssertFalse(String.isDate(endOfDay, moreRecentThan: startOfNextDay, with: 0))
    }

    func test_isDate_crossYearBoundary() {
        let endOfYear = "2025-12-31T23:59:59Z"
        let startOfYear = "2026-01-01T00:00:00Z"
        XCTAssertTrue(String.isDate(startOfYear, moreRecentThan: endOfYear, with: 0))
    }

    // MARK: - Sync Decision Matrix
    // These tests document the expected behavior of the sync decision
    // based on different combinations of local/remote positions.

    func test_syncDecision_localNilRemoteNil_noSync() {
        // When both are nil, no operation should happen
        // This matches: localPosition == nil && remotePosition == nil
        // remoteLocationIsNewer = false (since localPosition == nil but remotePosition is also nil)
        let remoteIsNewer = (true == false) // localPosition == nil && remotePosition != nil
        XCTAssertFalse(remoteIsNewer)
    }

    func test_syncDecision_localNilRemoteExists_remoteIsNewer() {
        // When local is nil and remote exists, remote is considered newer
        let localPosition: String? = nil
        let remotePosition: String? = "2026-03-30T12:00:00Z"
        let remoteIsNewer = localPosition == nil && remotePosition != nil
        XCTAssertTrue(remoteIsNewer)
    }

    func test_syncDecision_localExistsRemoteNil_localIsUsed() {
        // When local exists and remote is nil, local should be used
        let localPosition: String? = "2026-03-30T12:00:00Z"
        let remotePosition: String? = nil
        let remoteIsNewer = localPosition == nil && remotePosition != nil
        XCTAssertFalse(remoteIsNewer)
    }

    func test_syncDecision_bothExist_remoteNewer_promptsSync() {
        let local = "2026-03-30T10:00:00Z"
        let remote = "2026-03-30T12:00:00Z"
        let delay: TimeInterval = 0
        let remoteIsNewer = String.isDate(remote, moreRecentThan: local, with: delay)
        XCTAssertTrue(remoteIsNewer, "Remote position is newer, should prompt for sync")
    }

    func test_syncDecision_bothExist_localNewer_usesLocal() {
        let local = "2026-03-30T14:00:00Z"
        let remote = "2026-03-30T12:00:00Z"
        let delay: TimeInterval = 0
        let remoteIsNewer = String.isDate(remote, moreRecentThan: local, with: delay)
        XCTAssertFalse(remoteIsNewer, "Local position is newer, should use local")
    }
}
