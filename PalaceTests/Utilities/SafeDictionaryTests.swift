//
//  SafeDictionaryTests.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class SafeDictionaryTests: XCTestCase {

  // MARK: - Basic Operations

  func testSet_andGet_returnsValue() async {
    let dict = SafeDictionary<String, Int>()
    await dict.set("age", value: 25)

    let result = await dict.get("age")
    XCTAssertEqual(result, 25)
  }

  func testGet_missingKey_returnsNil() async {
    let dict = SafeDictionary<String, Int>()
    let result = await dict.get("nonexistent")
    XCTAssertNil(result)
  }

  func testSet_overwrite_updatesValue() async {
    let dict = SafeDictionary<String, String>()
    await dict.set("key", value: "old")
    await dict.set("key", value: "new")

    let result = await dict.get("key")
    XCTAssertEqual(result, "new")
  }

  // MARK: - Remove

  func testRemove_deletesEntry() async {
    let dict = SafeDictionary<String, Int>()
    await dict.set("key", value: 42)
    let removed = await dict.remove("key")

    XCTAssertEqual(removed, 42)
    let afterRemove = await dict.get("key")
    XCTAssertNil(afterRemove)
  }

  func testRemove_missingKey_returnsNil() async {
    let dict = SafeDictionary<String, Int>()
    let result = await dict.remove("nonexistent")
    XCTAssertNil(result)
  }

  func testRemoveAll_clearsEverything() async {
    let dict = SafeDictionary<String, Int>()
    await dict.set("a", value: 1)
    await dict.set("b", value: 2)
    await dict.removeAll()

    let empty = await dict.isEmpty()
    XCTAssertTrue(empty)
    let count = await dict.count()
    XCTAssertEqual(count, 0)
  }

  // MARK: - Contains / Count / isEmpty

  func testContains_existingKey_returnsTrue() async {
    let dict = SafeDictionary<String, String>()
    await dict.set("name", value: "Palace")

    let containsName = await dict.contains("name")
    XCTAssertTrue(containsName)
    let containsMissing = await dict.contains("missing")
    XCTAssertFalse(containsMissing)
  }

  func testCount_reflectsEntries() async {
    let dict = SafeDictionary<Int, String>()
    let initialCount = await dict.count()
    XCTAssertEqual(initialCount, 0)

    await dict.set(1, value: "one")
    await dict.set(2, value: "two")
    let afterCount = await dict.count()
    XCTAssertEqual(afterCount, 2)
  }

  func testIsEmpty_noEntries_returnsTrue() async {
    let dict = SafeDictionary<String, Int>()
    let emptyBefore = await dict.isEmpty()
    XCTAssertTrue(emptyBefore)

    await dict.set("key", value: 1)
    let emptyAfter = await dict.isEmpty()
    XCTAssertFalse(emptyAfter)
  }

  // MARK: - Snapshot Methods

  func testKeys_returnsAllKeys() async {
    let dict = SafeDictionary<String, Int>()
    await dict.set("a", value: 1)
    await dict.set("b", value: 2)

    let keys = await dict.keys()
    XCTAssertEqual(Set(keys), Set(["a", "b"]))
  }

  func testValues_returnsAllValues() async {
    let dict = SafeDictionary<String, Int>()
    await dict.set("a", value: 1)
    await dict.set("b", value: 2)

    let values = await dict.values()
    XCTAssertEqual(Set(values), Set([1, 2]))
  }

  func testAllPairs_returnsAllKeyValuePairs() async {
    let dict = SafeDictionary<String, Int>()
    await dict.set("x", value: 10)
    await dict.set("y", value: 20)

    let pairs = await dict.allPairs()
    XCTAssertEqual(pairs.count, 2)
  }

  // MARK: - Batch Operations

  func testUpdateMultiple_addsAllEntries() async {
    let dict = SafeDictionary<String, Int>()
    await dict.updateMultiple(["a": 1, "b": 2, "c": 3])

    let count = await dict.count()
    XCTAssertEqual(count, 3)
    let a = await dict.get("a")
    XCTAssertEqual(a, 1)
    let b = await dict.get("b")
    XCTAssertEqual(b, 2)
    let c = await dict.get("c")
    XCTAssertEqual(c, 3)
  }

  func testRemoveMultiple_removesSpecifiedKeys() async {
    let dict = SafeDictionary<String, Int>()
    await dict.updateMultiple(["a": 1, "b": 2, "c": 3])
    await dict.removeMultiple(["a", "c"])

    let count = await dict.count()
    XCTAssertEqual(count, 1)
    let a = await dict.get("a")
    XCTAssertNil(a)
    let b = await dict.get("b")
    XCTAssertEqual(b, 2)
    let c = await dict.get("c")
    XCTAssertNil(c)
  }

  // MARK: - Functional Operations

  func testMapValues_transformsValues() async {
    let dict = SafeDictionary<String, Int>()
    await dict.set("price", value: 10)

    let mapped = await dict.mapValues { $0 * 2 }
    XCTAssertEqual(mapped["price"], 20)
  }

  func testFilter_selectsMatchingEntries() async {
    let dict = SafeDictionary<String, Int>()
    await dict.updateMultiple(["a": 1, "b": 2, "c": 3, "d": 4])

    let evens = await dict.filter { _, v in v % 2 == 0 }
    XCTAssertEqual(evens.count, 2)
    XCTAssertEqual(evens["b"], 2)
    XCTAssertEqual(evens["d"], 4)
  }

  func testCompactMapValues_removesNils() async {
    let dict = SafeDictionary<String, String>()
    await dict.updateMultiple(["num": "42", "str": "abc", "zero": "0"])

    let ints = await dict.compactMapValues { Int($0) }
    XCTAssertEqual(ints.count, 2)
    XCTAssertEqual(ints["num"], 42)
    XCTAssertEqual(ints["zero"], 0)
  }

  // MARK: - Modify / UpdateValue

  func testModify_updatesExistingValue() async {
    let dict = SafeDictionary<String, Int>()
    await dict.set("counter", value: 5)

    await dict.modify("counter") { value in
      value = (value ?? 0) + 10
    }

    let result = await dict.get("counter")
    XCTAssertEqual(result, 15)
  }

  func testModify_createsNewValue() async {
    let dict = SafeDictionary<String, Int>()

    await dict.modify("new") { value in
      value = 99
    }

    let result = await dict.get("new")
    XCTAssertEqual(result, 99)
  }

  // MARK: - Initialization

  func testInit_withInitialValues() async {
    let dict = SafeDictionary<String, Int>(["x": 1, "y": 2])

    let count = await dict.count()
    XCTAssertEqual(count, 2)
    let x = await dict.get("x")
    XCTAssertEqual(x, 1)
    let y = await dict.get("y")
    XCTAssertEqual(y, 2)
  }

  // MARK: - Metrics

  func testGetMetrics_returnsMetricsDictionary() async {
    let dict = SafeDictionary<String, Int>()
    await dict.set("key", value: 1)

    let metrics = await dict.getMetrics()
    XCTAssertNotNil(metrics["count"])
  }
}
