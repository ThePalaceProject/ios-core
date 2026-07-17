//
//  GeneralCacheTests.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

@MainActor
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
        XCTAssertNil(cache.get(for: "farewell"), "Unset key must return nil")
    }

    func testGet_unknownKey_returnsNil() {
        XCTAssertNil(cache.get(for: "nonexistent"))
        // Setting a different key must not affect the unknown key
        cache.set("something", for: "other-key")
        XCTAssertNil(cache.get(for: "nonexistent"), "Unknown key must remain nil after setting an unrelated key")
    }

    func testSet_overwrite_updatesValue() {
        cache.set("Old", for: "key")
        cache.set("New", for: "key")
        XCTAssertEqual(cache.get(for: "key"), "New")
        XCTAssertNotEqual(cache.get(for: "key"), "Old", "Old value must not be accessible after overwrite")
    }

    // MARK: - Remove

    func testRemove_deletesEntry() {
        cache.set("Value", for: "key")
        cache.remove(for: "key")
        XCTAssertNil(cache.get(for: "key"))
        // The cache must still accept new entries after removal
        cache.set("NewValue", for: "key")
        XCTAssertEqual(cache.get(for: "key"), "NewValue", "Cache must accept new value after removal")
    }

    func testRemove_nonexistentKey_doesNotCrash() {
        cache.remove(for: "nonexistent")
        // After removing a non-existent key, cache should remain empty
        XCTAssertNil(cache.get(for: "nonexistent"), "Non-existent key should still return nil after remove")
        // Other keys should be unaffected
        cache.set("existing", for: "real-key")
        cache.remove(for: "nonexistent")
        XCTAssertEqual(cache.get(for: "real-key"), "existing", "Real key should survive removal of non-existent key")
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
        cache.set("Another", for: "key2")
        cache.clearMemory()

        // For memoryOnly cache, this should remove all values
        XCTAssertNil(cache.get(for: "key"), "clearMemory must remove previously cached values")
        XCTAssertNil(cache.get(for: "key2"), "clearMemory must remove all entries, not just the first")
    }

    // MARK: - Expiration

    func testSet_withExpiration_isAvailableBeforeExpiry() {
        cache.set("Temporary", for: "key", expiresIn: 60)
        XCTAssertEqual(cache.get(for: "key"), "Temporary")
        // A different key should still be nil
        XCTAssertNil(cache.get(for: "other-key"))
        // The value should be consistent across reads before expiry
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
        XCTAssertNil(bothCache.get(for: "missing-key"), "Unset key must return nil in memoryAndDisk mode")

        bothCache.clear()
        XCTAssertNil(bothCache.get(for: "both-key"), "clear() must remove memoryAndDisk entries")
    }

    // MARK: - None Mode

    func testNoneMode_doesNotStore() {
        let noneCache = GeneralCache<String, String>(cacheName: "NoneTest-\(UUID().uuidString)", mode: .none)
        noneCache.set("Ghost", for: "key")

        XCTAssertNil(noneCache.get(for: "key"), "None mode should not store values")
        // A second key must also not be stored
        noneCache.set("Phantom", for: "key2")
        XCTAssertNil(noneCache.get(for: "key2"), "None mode must not store any key")
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
        // Different keys must produce different file URLs
        let url2 = cache.fileURL(for: "another-key")
        XCTAssertNotEqual(url, url2, "Different keys must map to different file URLs")
    }

    // MARK: - Directory Recreation

    /// Regression: `clearCacheOnUpdate()` at launch wipes non-Adobe cache dirs
    /// including the cache's own directory. Subsequent `set()` must not fail
    /// with "The folder doesn't exist" — saveToDisk must recreate the dir.
    func testSet_afterExternalDirectoryDeletion_recreatesAndSucceeds() {
        let diskCache = GeneralCache<String, Data>(
            cacheName: "DirDeletionRegression-\(UUID().uuidString)",
            mode: .diskOnly
        )
        // Prime cache so we know the URL and directory exist
        let firstKey = "warmup"
        diskCache.set(Data("seed".utf8), for: firstKey)

        let firstURL = diskCache.fileURL(for: firstKey)
        let cacheDir = firstURL.deletingLastPathComponent()

        // Wait for the async barrier write to FULLY materialize — poll the
        // written FILE, not just the directory. The directory is created before
        // the file is written, so waiting on directory-existence alone returns
        // while the file write is still queued; that pending write then races
        // the `removeItem` below and recreates the directory, flaking the
        // "directory is gone" precondition. This surfaced once `MallocStackLogging`
        // (which slowed allocations enough to mask the race) was removed from the
        // test scheme. Polling the file makes the test timing-independent.
        awaitCondition(timeout: 5.0) {
            FileManager.default.fileExists(atPath: firstURL.path)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheDir.path),
                      "Precondition: cache directory exists after first write")

        // Simulate clearCacheOnUpdate() wiping the directory
        try? FileManager.default.removeItem(at: cacheDir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheDir.path),
                       "Precondition: cache directory is gone")

        // The new write must recreate the directory and succeed
        let payload = Data("after-delete".utf8)
        diskCache.set(payload, for: "recovered")

        let recoveredURL = diskCache.fileURL(for: "recovered")
        // Wait for the recovered write to materialize: the cache directory
        // must be recreated AND the recovered file must land. Poll both
        // conditions instead of sleeping for a fixed delay.
        awaitCondition(timeout: 5.0) {
            FileManager.default.fileExists(atPath: cacheDir.path)
                && FileManager.default.fileExists(atPath: recoveredURL.path)
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheDir.path),
                      "saveToDisk should recreate the cache directory")
        XCTAssertEqual(try? Data(contentsOf: recoveredURL), payload,
                       "Data should be written after directory recovery")

        try? FileManager.default.removeItem(at: cacheDir)
    }

    /// `clearAllCaches()` must preserve the app's bundle-id directory (which
    /// hosts the system `URLCache` Cache.db). Wiping it causes NSURLStorage
    /// errors on launch.
    func testClearAllCaches_preservesBundleIDDirectory() throws {
        guard let cachesDir = FileManager.default.urls(for: .cachesDirectory,
                                                       in: .userDomainMask).first,
              let bundleID = Bundle.main.bundleIdentifier
        else {
            XCTFail("Caches dir or bundle ID unavailable")
            return
        }

        let bundleDir = cachesDir.appendingPathComponent(bundleID, isDirectory: true)
        let createdForTest = !FileManager.default.fileExists(atPath: bundleDir.path)
        if createdForTest {
            try FileManager.default.createDirectory(at: bundleDir,
                                                    withIntermediateDirectories: true)
        }
        let sentinel = bundleDir.appendingPathComponent("sentinel.txt")
        try Data("sentinel".utf8).write(to: sentinel)

        GeneralCache<String, Data>.clearAllCaches()

        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleDir.path),
                      "Bundle-id dir must survive clearAllCaches (hosts URLCache)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path),
                      "Sentinel file must survive clearAllCaches")

        try? FileManager.default.removeItem(at: sentinel)
        if createdForTest {
            try? FileManager.default.removeItem(at: bundleDir)
        }
    }
}
