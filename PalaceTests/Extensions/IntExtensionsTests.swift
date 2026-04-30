//
//  IntExtensionsTests.swift
//  PalaceTests
//
//  Tests for Int+Extensions.swift ordinal formatter.
//

import XCTest
@testable import Palace

final class IntExtensionsTests: XCTestCase {

  /// `Int.ordinal()` follows English ordinal rules: 1st/2nd/3rd, then
  /// `th` for 4+ (with the special-case "teen" exception for 11-13).
  /// Lock the entire 1-13 range plus the 21st-24th wrap-around. A mutant
  /// flipping any single suffix branch fails on a distinct assertion.
  func testOrdinal_followsEnglishOrdinalRules_includingTeenExceptions() {
    // Single-digit cases: 1st, 2nd, 3rd, 4-9 → th.
    XCTAssertEqual(1.ordinal(),  "1st")
    XCTAssertEqual(2.ordinal(),  "2nd")
    XCTAssertEqual(3.ordinal(),  "3rd")
    XCTAssertEqual(4.ordinal(),  "4th")
    XCTAssertEqual(5.ordinal(),  "5th")
    XCTAssertEqual(9.ordinal(),  "9th")

    // The teen exception: 11/12/13 use "th", NOT 11st/12nd/13rd.
    XCTAssertEqual(10.ordinal(), "10th")
    XCTAssertEqual(11.ordinal(), "11th",
                   "11 must use 'th' (English teen exception), NOT '11st'")
    XCTAssertEqual(12.ordinal(), "12th",
                   "12 must use 'th', NOT '12nd' — guards against modulo-only logic")
    XCTAssertEqual(13.ordinal(), "13th",
                   "13 must use 'th', NOT '13rd'")
  }

  /// SRS: EXT-INT-004 — ordinal returns "th" suffix for 4-20
  func testOrdinal_FourAndAbove_ReturnsTh() {
    XCTAssertEqual(4.ordinal(), "4th")
    XCTAssertEqual(11.ordinal(), "11th")
    XCTAssertEqual(12.ordinal(), "12th")
    XCTAssertEqual(13.ordinal(), "13th")
  }

  /// SRS: EXT-INT-005 — ordinal handles 21st, 22nd, 23rd pattern
  func testOrdinal_TwentyFirstPattern_ReturnsCorrectSuffix() {
    XCTAssertEqual(21.ordinal(), "21st")
    XCTAssertEqual(22.ordinal(), "22nd")
    XCTAssertEqual(23.ordinal(), "23rd")
    XCTAssertEqual(24.ordinal(), "24th")
  }

  /// SRS: EXT-INT-006 — ordinal handles zero
  func testOrdinal_Zero_ReturnsZeroth() {
    let result = 0.ordinal()
    XCTAssertFalse(result.isEmpty)
    XCTAssertEqual(result, "0th")
  }
}
