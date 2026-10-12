//
//  StringDateComparisonTests.swift
//  PalaceTests
//
//  Covers `String.isDate(_:moreRecentThan:with:)` in PalaceUtilities, which
//  computes `date1 + with > date2`. The `with:` argument is therefore a
//  tolerance applied to the FIRST date, so a positive value lets a slightly
//  older `date1` still report as more recent — not a grace period protecting
//  `date2`. `BookDetailViewModel.chooseLocalLocation` passes the remote
//  position first, so the tolerance favours the server; that caller is covered
//  in BookDetailPositionSyncChoiceTests.
//

import XCTest
@testable import Palace
import PalaceUtilities

@MainActor
final class StringDateComparisonTests: XCTestCase {
    // MARK: - String.isDate(_:moreRecentThan:with:) — Core Sync Decision Logic

    func test_isDate_moreRecentThan_sameDate_notMoreRecent() {
        let date = "2026-03-30T12:00:00Z"
        XCTAssertFalse(String.isDate(date, moreRecentThan: date, with: 0))
        // Symmetry: comparing in both directions must both return false for same date
        XCTAssertFalse(String.isDate(date, moreRecentThan: date, with: 0),
                       "Same-date comparison is not strictly more recent in either direction")
        // But with any positive delay it becomes true
        XCTAssertTrue(String.isDate(date, moreRecentThan: date, with: 1),
                      "Positive delay breaks the tie — date+1s > date")
    }

    func test_isDate_moreRecentThan_newerDate_isMoreRecent() {
        let newer = "2026-03-31T12:00:00Z"
        let older = "2026-03-30T12:00:00Z"
        XCTAssertTrue(String.isDate(newer, moreRecentThan: older, with: 0))
        // Asymmetry: reversed comparison must be false
        XCTAssertFalse(String.isDate(older, moreRecentThan: newer, with: 0),
                       "Reversed comparison must be false — older is not more recent than newer")
    }

    func test_isDate_moreRecentThan_olderDate_notMoreRecent() {
        let older = "2026-03-29T12:00:00Z"
        let newer = "2026-03-30T12:00:00Z"
        XCTAssertFalse(String.isDate(older, moreRecentThan: newer, with: 0))
        // Opposite direction must be true
        XCTAssertTrue(String.isDate(newer, moreRecentThan: older, with: 0),
                      "newer is more recent than older")
    }

    func test_isDate_withPositiveDelay_makesOlderDatePassAsNewer() {
        let older = "2026-03-30T12:00:00Z"
        let newer = "2026-03-30T12:00:05Z"
        // Formula: older + 10 > newer => (older + 10s) > (older + 5s) => true
        XCTAssertTrue(String.isDate(older, moreRecentThan: newer, with: 10),
                      "With sufficient delay, even an older date passes the 'more recent' check")
        // With exact matching delay the older+delay == newer+0, so still false (not strictly greater)
        XCTAssertFalse(String.isDate(older, moreRecentThan: newer, with: 5),
                       "Delay equal to the gap makes them equal — not strictly more recent")
    }

    func test_isDate_withInsufficientDelay_olderDateStillFails() {
        let older = "2026-03-30T12:00:00Z"
        let newer = "2026-03-30T12:00:15Z"
        // Formula: older + 10 > newer => (older + 10s) > (older + 15s) => false
        XCTAssertFalse(String.isDate(older, moreRecentThan: newer, with: 10),
                       "With insufficient delay, an older date still fails")
        // Sufficient delay flips the result
        XCTAssertTrue(String.isDate(older, moreRecentThan: newer, with: 20),
                      "Delay exceeding the gap must make the older date 'more recent'")
    }

    func test_isDate_newerDateWithDelay_alwaysPasses() {
        let newer = "2026-03-30T12:00:15Z"
        let older = "2026-03-30T12:00:00Z"
        // newer + 10 > older => obviously true
        XCTAssertTrue(String.isDate(newer, moreRecentThan: older, with: 10))
        // Even delay of 0 is sufficient when newer > older
        XCTAssertTrue(String.isDate(newer, moreRecentThan: older, with: 0),
                      "A genuinely newer date passes regardless of delay")
    }

    func test_isDate_invalidDateStrings_returnsFalse() {
        XCTAssertFalse(String.isDate("not-a-date", moreRecentThan: "2026-03-30T12:00:00Z", with: 0))
        XCTAssertFalse(String.isDate("2026-03-30T12:00:00Z", moreRecentThan: "garbage", with: 0))
        XCTAssertFalse(String.isDate("", moreRecentThan: "", with: 0))
    }

    func test_isDate_emptyStrings_returnsFalse() {
        XCTAssertFalse(String.isDate("", moreRecentThan: "2026-03-30T12:00:00Z", with: 0))
        XCTAssertFalse(String.isDate("2026-03-30T12:00:00Z", moreRecentThan: "", with: 0))
        // Both empty also fails
        XCTAssertFalse(String.isDate("", moreRecentThan: "", with: 100),
                       "Empty strings with large delay must still return false")
    }

    func test_isDate_sameTimestamp_withSmallDelay_returnsTrue() {
        let date = "2026-03-30T12:00:00Z"
        // date + 1 > date => true (strictly greater by 1 second)
        XCTAssertTrue(String.isDate(date, moreRecentThan: date, with: 1),
                      "Same timestamp with positive delay should be considered 'more recent'")
        // delay of 0 must be false for same timestamp
        XCTAssertFalse(String.isDate(date, moreRecentThan: date, with: 0),
                       "Zero delay with same timestamp must not be 'more recent'")
    }

    func test_isDate_negativeDelay_makesNewerDateFail() {
        let newer = "2026-03-30T12:00:03Z"
        let older = "2026-03-30T12:00:00Z"
        // newer + (-5) > older => (newer - 5s) > older => (older - 2s) > older => false
        XCTAssertFalse(String.isDate(newer, moreRecentThan: older, with: -5),
                       "Negative delay makes dates appear older")
        // But with zero delay the newer is still newer
        XCTAssertTrue(String.isDate(newer, moreRecentThan: older, with: 0),
                      "Without negative delay, newer date remains more recent")
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
        // Reversed: year-end is not more recent than year-start
        XCTAssertFalse(String.isDate(endOfYear, moreRecentThan: startOfYear, with: 0),
                       "End of 2025 must not be more recent than start of 2026")
    }
}
