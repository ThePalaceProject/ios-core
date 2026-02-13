//
//  GeneralCacheTests.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class GeneralCacheTests: XCTestCase {

    private var cache: GeneralCache<String, String>!

    override func setUp() {
        super.setUp()
        cache = GeneralCache<String, String>(cacheName: "TestCache-\(UUID().uuidString)", mode: .memoryOnly)
    }

    override func tearDown() {
        cache.clear()
        super.tearDown()
    }

    // MARK: - Basic Get/Set

    func testSet_andGet_returnsValue() {
        cache.set("Hello World", for: "greeting")
        XCTAssertEqual(cache.get(for: "greeting"), "Hello World")
    }

    func testGet_unknownKey_returnsNil() {
        XCTAssertNil(cache.get(for: "nonexistent"))
    }

    func testSet_overwrite_updatesValue() {
        cache.set("Old", for: "key")
        cache.set("New", for: "key")
        XCTAssertEqual(cache.get(for: "key"), "New")
    }

    // MARK: - Remove

    func testRemove_deletesEntry() {
        cache.set("Value", for: "key")
        cache.remove(for: "key")
        XCTAssertNil(cache.get(for: "key"))
    }

    func testRemove_nonexistentKey_doesNotCrash() {
        cache.remove(for: "nonexistent")
    }

    // MARK: - Clear

    func testClear_removesAllEntries() {
        cache.set("A", for: "1")
        cache.set("B", for: "2")
        cache.set("C", for: "3")
        cache.clear()

        XCTAssertNil(cache.get(for: "1"))
        XCTAssertNil(cache.get(for: "2"))
        XCTAssertNil(cache.get(for: "3"))
    }

    func testClearMemory_removesMemoryEntries() {
        cache.set("Value", for: "key")
        cache.clearMemory()

        // For memoryOnly cache, this should remove the value
        XCTAssertNil(cache.get(for: "key"))
    }

    // MARK: - Expiration

    func testSet_withExpiration_isAvailableBeforeExpiry() {
        cache.set("Temporary", for: "key", expiresIn: 60)
        XCTAssertEqual(cache.get(for: "key"), "Temporary")
    }

    // MARK: - Multiple Types

    func testCache_withIntKeys() {
        let intCache = GeneralCache<Int, String>(cacheName: "IntKeyTest-\(UUID().uuidString)", mode: .memoryOnly)
        intCache.set("One", for: 1)
        intCache.set("Two", for: 2)

        XCTAssertEqual(intCache.get(for: 1), "One")
        XCTAssertEqual(intCache.get(for: 2), "Two")

        intCache.clear()
    }

    func testCache_withCodableValues() {
        struct Item: Codable, Equatable {
            let name: String
            let count: Int
        }

        let itemCache = GeneralCache<String, Item>(cacheName: "ItemTest-\(UUID().uuidString)", mode: .memoryOnly)
        let item = Item(name: "Book", count: 3)
        itemCache.set(item, for: "item1")

        XCTAssertEqual(itemCache.get(for: "item1"), item)

        itemCache.clear()
    }

    // MARK: - Disk Cache

    func testDiskCache_persistsValue() {
        // diskOnly mode uses the file modification date as an expiration marker,
        // so entries must have an explicit TTL to survive a read-back.
        let diskCache = GeneralCache<String, String>(cacheName: "DiskTest-\(UUID().uuidString)", mode: .diskOnly)
        diskCache.set("Persisted", for: "disk-key", expiresIn: 60)

        let retrieved = diskCache.get(for: "disk-key")
        XCTAssertEqual(retrieved, "Persisted")

        diskCache.clear()
    }

    func testMemoryAndDisk_persistsValue() {
        let bothCache = GeneralCache<String, String>(cacheName: "BothTest-\(UUID().uuidString)", mode: .memoryAndDisk)
        bothCache.set("Both", for: "both-key")

        XCTAssertEqual(bothCache.get(for: "both-key"), "Both")

        bothCache.clear()
    }

    // MARK: - None Mode

    func testNoneMode_doesNotStore() {
        let noneCache = GeneralCache<String, String>(cacheName: "NoneTest-\(UUID().uuidString)", mode: .none)
        noneCache.set("Ghost", for: "key")

        XCTAssertNil(noneCache.get(for: "key"), "None mode should not store values")
    }

    // MARK: - Cache Policy (async)

    func testCachePolicy_cacheFirst_usesCache_whenFetcherFails() async throws {
        cache.set("Cached Value", for: "policy-key")

        let result = try await cache.get("policy-key", policy: .cacheFirst) {
            throw NSError(domain: "TestDomain", code: 1, userInfo: nil)
        }

        XCTAssertEqual(result, "Cached Value", "cacheFirst should fall back to cache when fetcher fails")
    }

    func testCachePolicy_cacheFirst_returnsCachedValue_whenPresent() async throws {
        cache.set("Cached", for: "policy-key")

        let result = try await cache.get("policy-key", policy: .cacheFirst) {
            return "Fresh"
        }

        XCTAssertEqual(result, "Cached", "cacheFirst should return cached value when present, without calling fetcher")
    }

    func testCachePolicy_cacheFirst_callsFetcher_onCacheMiss() async throws {
        // No cached value for this key
        let result = try await cache.get("missing-key", policy: .cacheFirst) {
            return "Fetched"
        }

        XCTAssertEqual(result, "Fetched", "cacheFirst should fall through to fetcher on cache miss")
    }

    func testCachePolicy_noCache_alwaysFetches() async throws {
        cache.set("Old", for: "no-cache-key")

        let result = try await cache.get("no-cache-key", policy: .noCache) {
            return "Fresh"
        }

        XCTAssertEqual(result, "Fresh", "noCache should always use fetcher")
    }

    // MARK: - File URL

    func testFileURL_returnsURL() {
        let url = cache.fileURL(for: "some-key")
        XCTAssertFalse(url.absoluteString.isEmpty)
    }
}
