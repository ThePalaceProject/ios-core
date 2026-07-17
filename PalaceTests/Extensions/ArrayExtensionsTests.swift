//
//  ArrayExtensionsTests.swift
//  PalaceTests
//
//  Tests for Array+Extensions.swift safe subscript.
//

import XCTest
@testable import Palace

@MainActor
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

  /// Empty-array reads: index 0, positive, and negative all return nil
  /// without crashing. A mutant that doesn't bounds-check the empty case
  /// would force-unwrap a missing element and crash.
  func testSafeSubscriptGet_emptyArray_returnsNilForAllIndices() {
    let array: [Int] = []
    XCTAssertNil(array[safe: 0],   "Index 0 on empty array must yield nil")
    XCTAssertNil(array[safe: 5],   "Positive index on empty array must yield nil")
    XCTAssertNil(array[safe: -1],  "Negative index on empty array must yield nil")
    XCTAssertNil(array[safe: 100], "Far out-of-bounds on empty array must yield nil")
  }

  // MARK: - Safe Subscript Setter

  /// Setter contract: writes at valid indices update the array; writes at
  /// invalid indices (out-of-bounds or nil value) leave the array
  /// untouched. Pin all four shapes (valid set, out-of-bounds set, nil
  /// at valid index, nil at invalid index) in one body.
  func testSafeSubscriptSet_updatesValidIndicesAndIgnoresInvalidWrites() {
    var array = [10, 20, 30]

    // Valid index: write applies.
    array[safe: 1] = 99
    XCTAssertEqual(array, [10, 99, 30],
                   "Valid-index write must mutate the array")

    // Out-of-bounds: write must be a no-op.
    array[safe: 5] = 42
    XCTAssertEqual(array, [10, 99, 30],
                   "Out-of-bounds write must NOT extend the array — guards against an array.append mutant")

    // Nil at a valid index: must be ignored (no removal, no crash).
    array[safe: 1] = nil
    XCTAssertEqual(array, [10, 99, 30],
                   "Nil at a valid index must NOT remove the element — setter ignores nil writes")

    // Negative index: also no-op.
    array[safe: -1] = 7
    XCTAssertEqual(array, [10, 99, 30],
                   "Negative-index write must NOT mutate — guards against a wraparound mutant")
  }

  /// SRS: EXT-ARR-008 — Safe subscript works with String arrays
  func testSafeSubscriptGet_StringArray_ReturnsElement() {
    let array = ["a", "b", "c"]
    XCTAssertEqual(array[safe: 0], "a")
    XCTAssertNil(array[safe: 3])
  }
}
