//
//  DictionaryExtensionsTests.swift
//  PalaceTests
//
//  Tests for Dictionary+Extensions.swift mapKeys.
//

import XCTest
@testable import Palace

final class DictionaryExtensionsTests: XCTestCase {

  /// SRS: EXT-DICT-001 — mapKeys transforms keys while preserving values
  func testMapKeys_TransformsKeys_PreservesValues() {
    let dict = ["one": 1, "two": 2, "three": 3]
    let result = dict.mapKeys { $0.uppercased() }
    XCTAssertEqual(result["ONE"], 1)
    XCTAssertEqual(result["TWO"], 2)
    XCTAssertEqual(result["THREE"], 3)
  }

  /// SRS: EXT-DICT-002 — mapKeys on empty dictionary returns empty
  func testMapKeys_EmptyDictionary_ReturnsEmpty() {
    let dict: [String: Int] = [:]
    let result = dict.mapKeys { $0.uppercased() }
    XCTAssertTrue(result.isEmpty)
  }

  /// SRS: EXT-DICT-003 — mapKeys can change key type
  func testMapKeys_ChangesKeyType_StringToInt() {
    let dict = ["1": "a", "2": "b"]
    let result = dict.mapKeys { Int($0)! }
    XCTAssertEqual(result[1], "a")
    XCTAssertEqual(result[2], "b")
  }

  /// SRS: EXT-DICT-004 — mapKeys preserves count when keys are unique
  func testMapKeys_UniqueTransform_PreservesCount() {
    let dict = [1: "a", 2: "b", 3: "c"]
    let result = dict.mapKeys { $0 * 10 }
    XCTAssertEqual(result.count, 3)
    XCTAssertEqual(result[10], "a")
  }

  /// SRS: EXT-DICT-005 — mapKeys with colliding transforms keeps last-written value
  func testMapKeys_CollidingKeys_OverwritesValue() {
    let dict = ["abc": 1, "def": 2]
    // Both keys have count 3, so they collide
    let result = dict.mapKeys { $0.count }
    XCTAssertEqual(result.count, 1)
    XCTAssertNotNil(result[3])
  }
}
