//
//  CountedCacheTests.swift
//  PalaceTests
//
//  PP-5509: NSCache cannot report its size, so `CountedCache` keeps a byte
//  count that the memory event line reads. The count must follow every way an
//  entry leaves the cache, or the device baseline is wrong.
//

import XCTest
@testable import Palace

final class CountedCacheTests: XCTestCase {

    func testSetObject_AddsBytesForEachKey() {
        let cache = CountedCache<String, NSString>()

        cache.setObject("a", forKey: "a", cost: 100)
        cache.setObject("b", forKey: "b", cost: 250)

        XCTAssertEqual(cache.byteCount, 350)
        XCTAssertEqual(cache.object(forKey: "b"), "b")
    }

    func testSetObject_WithExplicitBytes_CountsBytesNotCost() {
        let cache = CountedCache<Int, NSString>()

        cache.setObject("page", forKey: 1, cost: 0, bytes: 4_096)

        XCTAssertEqual(cache.byteCount, 4_096)
    }

    /// Replacing a key must count only the new value, whether or not NSCache
    /// reports the replaced object as evicted.
    func testSetObject_SameKeyTwice_CountsOnlyTheLatestValue() {
        let cache = CountedCache<String, NSString>()

        cache.setObject("old", forKey: "k", cost: 100)
        cache.setObject("new", forKey: "k", cost: 30)

        XCTAssertEqual(cache.byteCount, 30)
        XCTAssertEqual(cache.object(forKey: "k"), "new")
    }

    func testRemoveObject_SubtractsThatKeysBytes() {
        let cache = CountedCache<String, NSString>()
        cache.setObject("a", forKey: "a", cost: 100)
        cache.setObject("b", forKey: "b", cost: 250)

        cache.removeObject(forKey: "a")

        XCTAssertEqual(cache.byteCount, 250)
        XCTAssertNil(cache.object(forKey: "a"))
    }

    func testRemoveObject_UnknownKey_LeavesCountUnchanged() {
        let cache = CountedCache<String, NSString>()
        cache.setObject("a", forKey: "a", cost: 100)

        cache.removeObject(forKey: "missing")

        XCTAssertEqual(cache.byteCount, 100)
    }

    func testRemoveAllObjects_ResetsCountToZero() {
        let cache = CountedCache<String, NSString>()
        cache.setObject("a", forKey: "a", cost: 100)
        cache.setObject("b", forKey: "b", cost: 250)

        cache.removeAllObjects()

        XCTAssertEqual(cache.byteCount, 0)
        XCTAssertNil(cache.object(forKey: "b"))
    }

    /// NSCache drops entries on its own when a limit is passed; the delegate
    /// callback is the only signal, so the count must drop with it.
    func testCountLimitEviction_SubtractsTheEvictedEntrysBytes() {
        let cache = CountedCache<String, NSString>()
        cache.countLimit = 1

        cache.setObject("a", forKey: "a", cost: 100)
        cache.setObject("b", forKey: "b", cost: 250)

        XCTAssertNil(cache.object(forKey: "a"), "precondition: NSCache evicted the first entry")
        XCTAssertEqual(cache.byteCount, 250)
    }

    func testNegativeBytes_CountAsZero() {
        let cache = CountedCache<String, NSString>()

        cache.setObject("a", forKey: "a", cost: 0, bytes: -10)

        XCTAssertEqual(cache.byteCount, 0)
    }

    /// Caches made per screen share one counter, so a single registration
    /// covers all of them; a cache that goes away takes its bytes with it.
    func testSharedCounter_SumsLiveCachesAndDropsADeallocatedOne() {
        let counter = CacheByteCounter()
        let kept = CountedCache<Int, NSString>(counter: counter)
        var released: CountedCache<Int, NSString>? = CountedCache(counter: counter)

        kept.setObject("k", forKey: 1, cost: 100)
        released?.setObject("r", forKey: 1, cost: 40)
        XCTAssertEqual(counter.bytes, 140)

        released = nil

        XCTAssertEqual(counter.bytes, 100)
        XCTAssertEqual(kept.byteCount, 100)
    }

    func testConcurrentSetAndRemove_EndsWithCountOfRemainingEntries() {
        let cache = CountedCache<Int, Payload>()

        DispatchQueue.concurrentPerform(iterations: 200) { index in
            cache.setObject(Payload(index), forKey: index, cost: 10)
            if index.isMultiple(of: 2) {
                cache.removeObject(forKey: index)
            }
        }

        XCTAssertEqual(cache.byteCount, 100 * 10)
    }

    /// ImageCache and GeneralCache store one object under several keys; its
    /// memory is held once, so it counts once until the last key goes.
    func testOneObjectUnderTwoKeys_CountsOnceUntilBothKeysAreRemoved() {
        let cache = CountedCache<String, Payload>()
        let shared = Payload(1)

        cache.setObject(shared, forKey: "a", cost: 100)
        cache.setObject(shared, forKey: "b", cost: 100)
        XCTAssertEqual(cache.byteCount, 100)

        cache.removeObject(forKey: "a")
        XCTAssertEqual(cache.byteCount, 100, "key b still holds the object")

        cache.removeObject(forKey: "b")
        XCTAssertEqual(cache.byteCount, 0)
    }

    func testOneObjectUnderTwoKeys_ReplacingOneKeyKeepsTheSharedBytes() {
        let cache = CountedCache<String, Payload>()
        let shared = Payload(1)
        cache.setObject(shared, forKey: "a", cost: 100)
        cache.setObject(shared, forKey: "b", cost: 100)

        cache.setObject(Payload(2), forKey: "a", cost: 30)

        XCTAssertEqual(cache.byteCount, 130)
    }

    func testTotalCostLimitEviction_SubtractsTheEvictedEntrysBytes() {
        let cache = CountedCache<String, Payload>()
        cache.totalCostLimit = 100

        cache.setObject(Payload(1), forKey: "a", cost: 80)
        cache.setObject(Payload(2), forKey: "b", cost: 80)

        XCTAssertNil(cache.object(forKey: "a"), "precondition: NSCache evicted the first entry")
        XCTAssertEqual(cache.byteCount, 80)
    }

    /// Concurrent sets of one key: whichever value NSCache keeps, the count is
    /// that value's bytes. Many trials, because a bad interleaving is rare.
    func testConcurrentSetsOfOneKey_CountEqualsTheBytesOfTheHeldValue() {
        var mismatches = 0
        for _ in 0..<2_000 {
            let cache = CountedCache<String, Payload>()
            DispatchQueue.concurrentPerform(iterations: 8) { thread in
                for round in 0..<4 {
                    let bytes = thread * 10 + round + 1
                    cache.setObject(Payload(bytes), forKey: "k", cost: bytes)
                }
            }
            let held = cache.object(forKey: "k")?.id ?? 0
            if cache.byteCount != held {
                mismatches += 1
            }
        }

        XCTAssertEqual(mismatches, 0, "trials where the count did not match the held value")
    }

    /// A distinct object per value, so identity never merges two entries.
    private final class Payload {
        let id: Int
        init(_ id: Int) { self.id = id }
    }
}
