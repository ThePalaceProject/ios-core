//
//  StringExtensionsTests.swift
//  PalaceTests
//
//  Tests for String+Extensions.swift utility functions.
//  Covers coverage gap: isDate(_:moreRecentThan:with:)
//
//  Copyright 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

@MainActor
final class StringExtensionsTests: XCTestCase {

    // MARK: - isDate(_:moreRecentThan:with:) — happy paths

    /// `isDate(_:moreRecentThan:with:)` is true iff
    /// `parse(date1) + delay > parse(date2)`. Lock the temporal-direction
    /// contract at three magnitudes (seconds, days, years) and both
    /// directions in one body so a mutant that flips `>` to `<` (or to
    /// `>=`, since the strict-greater behaviour matters) fails on the
    /// equal-time case.
    func testIsDate_temporalDirection_acrossSecondsDaysAndYears() {
        // Seconds-apart, both directions
        XCTAssertTrue(String.isDate("2024-01-15T10:00:10Z",
                                    moreRecentThan: "2024-01-15T10:00:00Z",
                                    with: 0),
                      "10 seconds later → more recent")
        XCTAssertFalse(String.isDate("2024-01-15T10:00:00Z",
                                     moreRecentThan: "2024-01-15T10:00:10Z",
                                     with: 0),
                       "10 seconds earlier → not more recent")

        // Days-apart
        XCTAssertTrue(String.isDate("2024-01-16T10:00:00Z",
                                    moreRecentThan: "2024-01-15T10:00:00Z",
                                    with: 0),
                      "Next-day timestamp must be more recent")

        // Years-apart
        XCTAssertTrue(String.isDate("2025-01-15T10:00:00Z",
                                    moreRecentThan: "2024-01-15T10:00:00Z",
                                    with: 0),
                      "Next-year timestamp must be more recent")

        // Equal-time, zero delay: NOT more recent (strict greater).
        let identical = "2024-01-15T10:00:00Z"
        XCTAssertFalse(String.isDate(identical,
                                     moreRecentThan: identical,
                                     with: 0),
                       "Identical timestamps with zero delay are NOT strictly more recent — guards against `>=` mutant")
    }

    /// Delay shifts date1 forward; comparison is strict. Pin the boundary:
    /// at exactly the delay value the predicate is false (equal); just past
    /// it is true; just under it is false. This catches `>` ↔ `>=` mutants
    /// directly on the comparison.
    func testIsDate_delayBoundary_isStrictGreaterThan() {
        let date1 = "2024-01-15T09:59:55Z"
        let date2 = "2024-01-15T10:00:00Z"  // exactly 5s after date1

        XCTAssertTrue(String.isDate(date1, moreRecentThan: date2, with: 5.01),
                      "date1 + 5.01s > date2 → true")
        XCTAssertFalse(String.isDate(date1, moreRecentThan: date2, with: 5.0),
                       "date1 + 5.0s = date2 → false (strict greater) — boundary case for `>=` mutant")
        XCTAssertFalse(String.isDate(date1, moreRecentThan: date2, with: 4.99),
                       "date1 + 4.99s < date2 → false")
    }

    // MARK: - Invalid input

    /// Invalid input on either side (and on both sides) MUST return false —
    /// never crash, never default to true. Lock all four invalid-input
    /// shapes (invalid d1, invalid d2, both invalid, empty strings) in one
    /// table-driven test. A mutant that defaults to true on a parse failure
    /// fails on every row.
    func testIsDate_invalidOrEmptyStrings_returnFalse() {
        let validDate = "2024-01-15T10:00:00Z"
        let cases: [(d1: String, d2: String, label: String)] = [
            ("invalid-date", validDate,    "invalid date1"),
            (validDate,    "not-a-date",   "invalid date2"),
            ("invalid1",   "invalid2",     "both invalid"),
            ("",           "",             "both empty"),
            (validDate,    "",             "empty date2"),
            ("",           validDate,      "empty date1"),
        ]
        for c in cases {
            XCTAssertFalse(
                String.isDate(c.d1, moreRecentThan: c.d2, with: 0),
                "isDate must be false on invalid input: \(c.label)"
            )
            // And with a non-zero delay (rule out a mutant that only fails
            // the parse check when delay is 0).
            XCTAssertFalse(
                String.isDate(c.d1, moreRecentThan: c.d2, with: 100),
                "isDate must remain false on invalid input even with positive delay: \(c.label)"
            )
        }
    }
}
