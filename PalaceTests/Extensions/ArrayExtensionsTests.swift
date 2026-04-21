//
//  ArrayExtensionsTests.swift
//  PalaceTests
//
//  Tests for Array+Extensions.swift safe subscript.
//

import XCTest
@testable import Palace

final class ArrayExtensionsTests: XCTestCase {

  // MARK: - Safe Subscript Getter

  /// SRS: EXT-ARR-001 — Safe subscript returns element at valid index
  func testSafeSubscriptGet_ValidIndex_ReturnsElement() {
    let array = [10, 20, 30]
    XCTAssertEqual(array[safe: 0], 10)
    XCTAssertEqual(array[safe: 1], 20)
    XCTAssertEqual(array[safe: 2], 30)
  }

  /// SRS: EXT-ARR-002 — Safe subscript returns nil for out-of-bounds index
  func testSafeSubscriptGet_OutOfBounds_ReturnsNil() {
    let array = [10, 20, 30]
    XCTAssertNil(array[safe: 3])
    XCTAssertNil(array[safe: 100])
  }

  /// SRS: EXT-ARR-003 — Safe subscript returns nil for negative index
  func testSafeSubscriptGet_NegativeIndex_ReturnsNil() {
    let array = [10, 20, 30]
    XCTAssertNil(array[safe: -1])
    XCTAssertNil(array[safe: -100])
  }

  /// SRS: EXT-ARR-004 — Safe subscript returns nil on empty array
  func testSafeSubscriptGet_EmptyArray_ReturnsNil() {
    let array: [Int] = []
    XCTAssertNil(array[safe: 0])
  }

  // MARK: - Safe Subscript Setter

  /// SRS: EXT-ARR-005 — Safe subscript setter updates value at valid index
  func testSafeSubscriptSet_ValidIndex_UpdatesValue() {
    var array = [10, 20, 30]
    array[safe: 1] = 99
    XCTAssertEqual(array, [10, 99, 30])
  }

  /// SRS: EXT-ARR-006 — Safe subscript setter ignores out-of-bounds index
  func testSafeSubscriptSet_OutOfBounds_NoChange() {
    var array = [10, 20, 30]
    array[safe: 5] = 99
    XCTAssertEqual(array, [10, 20, 30])
  }

  /// SRS: EXT-ARR-007 — Safe subscript setter ignores nil value
  func testSafeSubscriptSet_NilValue_NoChange() {
    var array = [10, 20, 30]
    array[safe: 1] = nil
    XCTAssertEqual(array, [10, 20, 30])
  }

  /// SRS: EXT-ARR-008 — Safe subscript works with String arrays
  func testSafeSubscriptGet_StringArray_ReturnsElement() {
    let array = ["a", "b", "c"]
    XCTAssertEqual(array[safe: 0], "a")
    XCTAssertNil(array[safe: 3])
  }
}
