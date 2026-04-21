//
//  IntExtensionsTests.swift
//  PalaceTests
//
//  Tests for Int+Extensions.swift ordinal formatter.
//

import XCTest
@testable import Palace

final class IntExtensionsTests: XCTestCase {

  /// SRS: EXT-INT-001 — ordinal returns "1st" for 1
  func testOrdinal_One_ReturnsFirst() {
    XCTAssertEqual(1.ordinal(), "1st")
  }

  /// SRS: EXT-INT-002 — ordinal returns "2nd" for 2
  func testOrdinal_Two_ReturnsSecond() {
    XCTAssertEqual(2.ordinal(), "2nd")
  }

  /// SRS: EXT-INT-003 — ordinal returns "3rd" for 3
  func testOrdinal_Three_ReturnsThird() {
    XCTAssertEqual(3.ordinal(), "3rd")
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
