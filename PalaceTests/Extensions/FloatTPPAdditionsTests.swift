//
//  FloatTPPAdditionsTests.swift
//  PalaceTests
//
//  Tests for Float+TPPAdditions.swift approximate equality and rounding.
//

import XCTest
@testable import Palace

final class FloatTPPAdditionsTests: XCTestCase {

  // MARK: - Approximate Equality Operator (=~=)

  /// SRS: EXT-FLT-001 — Identical floats are approximately equal
  func testApproxEqual_IdenticalValues_ReturnsTrue() {
    XCTAssertTrue(1.0 as Float =~= 1.0 as Float)
  }

  /// SRS: EXT-FLT-002 — Different floats are not approximately equal
  func testApproxEqual_DifferentValues_ReturnsFalse() {
    XCTAssertFalse(1.0 as Float =~= 2.0 as Float)
  }

  /// SRS: EXT-FLT-003 — Nil comparison returns false
  func testApproxEqual_NilValue_ReturnsFalse() {
    let nilFloat: Float? = nil
    XCTAssertFalse(1.0 as Float =~= nilFloat)
  }

  /// SRS: EXT-FLT-004 — Zero values are approximately equal
  func testApproxEqual_ZeroValues_ReturnsTrue() {
    XCTAssertTrue(0.0 as Float =~= 0.0 as Float)
  }

  /// SRS: EXT-FLT-005 — Very close floats within epsilon are equal
  func testApproxEqual_WithinEpsilon_ReturnsTrue() {
    let a: Float = 1.0
    let b: Float = 1.0 + Float.ulpOfOne / 2
    XCTAssertTrue(a =~= b)
  }

  // MARK: - roundTo

  /// SRS: EXT-FLT-006 — roundTo formats with specified decimal places
  func testRoundTo_TwoDecimalPlaces_FormatsCorrectly() {
    let value: Float = 3.14159
    let result = value.roundTo(decimalPlaces: 2)
    XCTAssertEqual(result, "3.14%")
  }

  /// SRS: EXT-FLT-007 — roundTo with zero decimal places
  func testRoundTo_ZeroDecimalPlaces_FormatsCorrectly() {
    let value: Float = 3.7
    let result = value.roundTo(decimalPlaces: 0)
    XCTAssertEqual(result, "4%")
  }

  /// SRS: EXT-FLT-008 — roundTo appends percent sign
  func testRoundTo_AppendsPercentSign() {
    let value: Float = 50.0
    let result = value.roundTo(decimalPlaces: 1)
    XCTAssertTrue(result.hasSuffix("%"))
  }

  /// SRS: EXT-FLT-009 — Negative floats are not approximately equal to positive
  func testApproxEqual_NegativeVsPositive_ReturnsFalse() {
    XCTAssertFalse(-1.0 as Float =~= 1.0 as Float)
  }

  /// SRS: EXT-FLT-010 — roundTo with three decimal places
  func testRoundTo_ThreeDecimalPlaces_FormatsCorrectly() {
    let value: Float = 99.9995
    let result = value.roundTo(decimalPlaces: 3)
    XCTAssertTrue(result.hasSuffix("%"))
    XCTAssertTrue(result.contains("."))
  }

  /// SRS: EXT-FLT-011 — Approximate equality is symmetric
  func testApproxEqual_Symmetry_WorksBothWays() {
    let a: Float = 42.0
    let b: Float = 42.0
    XCTAssertTrue(a =~= b)
    XCTAssertTrue(b =~= a)
  }
}
