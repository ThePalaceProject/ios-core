//
//  SafeDictionarySyncMirrorTests.swift
//  PalaceTests
//
//  Tests for SafeDictionary's synchronous mirror — verifies that syncGet
//  returns fresh data after set/remove/removeAll without async access.
//

import XCTest
@testable import Palace

@MainActor
final class SafeDictionarySyncMirrorTests: XCTestCase {

    // MARK: - syncGet mirrors async set

    func testSyncGet_afterSet_returnsFreshValue() async {
        let dict = SafeDictionary<String, Int>()
        await dict.set("key", value: 42)

        // syncGet is nonisolated — call from outside async context
        let result = dict.syncGet("key")
        XCTAssertEqual(result, 42, "syncGet must return value written by set()")
    }

    func testSyncGet_missingKey_returnsNil() {
        let dict = SafeDictionary<String, Int>()
        let result = dict.syncGet("missing")
        XCTAssertNil(result)
    }

    func testSyncGet_afterRemove_returnsNil() async {
        let dict = SafeDictionary<String, String>()
        await dict.set("key", value: "hello")
        await dict.remove("key")

        let result = dict.syncGet("key")
        XCTAssertNil(result, "syncGet must return nil after remove()")
    }

    func testSyncGet_afterRemoveAll_returnsNil() async {
        let dict = SafeDictionary<String, Int>()
        await dict.set("a", value: 1)
        await dict.set("b", value: 2)
        await dict.removeAll()

        XCTAssertNil(dict.syncGet("a"))
        XCTAssertNil(dict.syncGet("b"))
    }

    func testSyncGet_afterOverwrite_returnsLatestValue() async {
        let dict = SafeDictionary<String, Int>()
        await dict.set("counter", value: 1)
        await dict.set("counter", value: 99)

        XCTAssertEqual(dict.syncGet("counter"), 99)
    }

    func testSyncGet_afterUpdateMultiple_returnsAllValues() async {
        let dict = SafeDictionary<String, Int>()
        await dict.updateMultiple(["x": 10, "y": 20, "z": 30])

        XCTAssertEqual(dict.syncGet("x"), 10)
        XCTAssertEqual(dict.syncGet("y"), 20)
        XCTAssertEqual(dict.syncGet("z"), 30)
    }

    func testSyncGet_afterRemoveMultiple_returnsNilForRemoved() async {
        let dict = SafeDictionary<String, Int>()
        await dict.updateMultiple(["a": 1, "b": 2, "c": 3])
        await dict.removeMultiple(["a", "c"])

        XCTAssertNil(dict.syncGet("a"))
        XCTAssertEqual(dict.syncGet("b"), 2)
        XCTAssertNil(dict.syncGet("c"))
    }

    // MARK: - Concurrent safety

    func testSyncGet_concurrentReads_duringWrites_noCrash() async {
        let dict = SafeDictionary<String, Int>()

        // Write from async context while reading from sync context concurrently
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    await dict.set("key-\(i)", value: i)
                }
                group.addTask {
                    // Sync read from concurrent task — must not crash
                    _ = dict.syncGet("key-\(i)")
                }
            }
        }

        // After all writes complete, all values should be readable
        for i in 0..<100 {
            XCTAssertEqual(dict.syncGet("key-\(i)"), i)
        }
    }
}
