//
//  StringExtensionsTests.swift
//  PalaceTests
//
//  Tests for String+Extensions.swift utility functions.
//  Covers QAAtlas gap: isDate(_:moreRecentThan:with:)
//
//  Copyright 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class StringExtensionsTests: XCTestCase {

    // MARK: - isDate(_:moreRecentThan:with:) Tests

    func testIsDate_WhenDate1IsMoreRecent_ReturnsTrue() {
        // Date1 is 10 seconds after Date2
        let date1 = "2024-01-15T10:00:10Z"
        let date2 = "2024-01-15T10:00:00Z"

        // With 0 delay, date1 should be more recent
        XCTAssertTrue(String.isDate(date1, moreRecentThan: date2, with: 0))
    }

    func testIsDate_WhenDate1IsOlder_ReturnsFalse() {
        // Date1 is 10 seconds before Date2
        let date1 = "2024-01-15T10:00:00Z"
        let date2 = "2024-01-15T10:00:10Z"

        XCTAssertFalse(String.isDate(date1, moreRecentThan: date2, with: 0))
    }

    func testIsDate_WithDelay_AdjustsComparison() {
        // Date1 is exactly at Date2
        let date1 = "2024-01-15T10:00:00Z"
        let date2 = "2024-01-15T10:00:00Z"

        // With 5 second delay, date1 + 5s > date2, so should return true
        XCTAssertTrue(String.isDate(date1, moreRecentThan: date2, with: 5))

        // With 0 delay, they're equal, so date1 is NOT more recent (not strictly greater)
        XCTAssertFalse(String.isDate(date1, moreRecentThan: date2, with: 0))
    }

    func testIsDate_WithInvalidDate1_ReturnsFalse() {
        let date1 = "invalid-date"
        let date2 = "2024-01-15T10:00:00Z"

        XCTAssertFalse(String.isDate(date1, moreRecentThan: date2, with: 0))
    }

    func testIsDate_WithInvalidDate2_ReturnsFalse() {
        let date1 = "2024-01-15T10:00:00Z"
        let date2 = "not-a-date"

        XCTAssertFalse(String.isDate(date1, moreRecentThan: date2, with: 0))
    }

    func testIsDate_WithBothInvalidDates_ReturnsFalse() {
        XCTAssertFalse(String.isDate("invalid1", moreRecentThan: "invalid2", with: 0))
    }

    func testIsDate_WithEmptyStrings_ReturnsFalse() {
        XCTAssertFalse(String.isDate("", moreRecentThan: "", with: 0))
        XCTAssertFalse(String.isDate("2024-01-15T10:00:00Z", moreRecentThan: "", with: 0))
        XCTAssertFalse(String.isDate("", moreRecentThan: "2024-01-15T10:00:00Z", with: 0))
    }

    func testIsDate_DelayAtThreshold_WorksCorrectly() {
        // Date1 is exactly 5 seconds before Date2
        let date1 = "2024-01-15T09:59:55Z"
        let date2 = "2024-01-15T10:00:00Z"

        // With exactly 5.01 second delay, date1 + 5.01s > date2
        XCTAssertTrue(String.isDate(date1, moreRecentThan: date2, with: 5.01))

        // With exactly 5 second delay, date1 + 5s = date2 (not strictly greater)
        XCTAssertFalse(String.isDate(date1, moreRecentThan: date2, with: 5.0))

        // With 4.99 second delay, date1 + 4.99s < date2
        XCTAssertFalse(String.isDate(date1, moreRecentThan: date2, with: 4.99))
    }

    func testIsDate_WithDifferentDays_ComparesCorrectly() {
        let date1 = "2024-01-16T10:00:00Z" // Next day
        let date2 = "2024-01-15T10:00:00Z"

        XCTAssertTrue(String.isDate(date1, moreRecentThan: date2, with: 0))
    }

    func testIsDate_WithDifferentYears_ComparesCorrectly() {
        let date1 = "2025-01-15T10:00:00Z"
        let date2 = "2024-01-15T10:00:00Z"

        XCTAssertTrue(String.isDate(date1, moreRecentThan: date2, with: 0))
    }
}
