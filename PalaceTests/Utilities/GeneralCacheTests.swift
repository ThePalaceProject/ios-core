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

    // MARK: - Thread-pool saturation (PP-5134)

    /// Cover loads call `get` from Swift-concurrency tasks, so on a busy catalog
    /// every thread in the shared pool can be inside `get` at once while
    /// lower-priority `set`/`clearMemory` writes keep arriving. The cache must
    /// keep making progress under that load. When it could not, the whole pool
    /// sat waiting on the cache forever and every other async job in the app —
    /// including the catalog feed fetch — stopped with it: the "All Fiction
    /// never loads" report.
    ///
    /// The priority split below is what makes this fail on the old design;
    /// with readers and writers at the same priority it passed.
    func testGetAndSet_fromSaturatedThreadPool_allComplete() {
        let diskCache = GeneralCache<String, Data>(
            cacheName: "PoolSaturation-\(UUID().uuidString)",
            mode: .memoryAndDisk
        )
        let keys = (0..<32).map { "cover-\($0)" }
        let payload = Data(repeating: 0xAB, count: 16_000)
        for key in keys {
            diskCache.set(payload, for: key, expiresIn: 3600)
        }

        // Twice the pool width, so every pool thread is a reader at some point.
        let readerCount = ProcessInfo.processInfo.activeProcessorCount * 2
        let finished = expectation(description: "every reader and writer returns")

        // Mirror production priorities: covers are read from tasks started by
        // the UI (user-initiated), while `ImageCache` writes from its
        // `.utility` processing queue.
        let writes = OperationQueue()
        writes.qualityOfService = .utility
        writes.maxConcurrentOperationCount = 4
        for i in 0..<400 {
            writes.addOperation {
                diskCache.set(payload, for: keys[i % keys.count], expiresIn: 3600)
                if i % 10 == 0 { diskCache.clearMemory() }
            }
        }

        Task.detached(priority: .userInitiated) {
            await withTaskGroup(of: Void.self) { group in
                for reader in 0..<readerCount {
                    group.addTask {
                        for i in 0..<400 {
                            _ = diskCache.get(for: keys[(reader + i) % keys.count])
                        }
                    }
                }
            }
            finished.fulfill()
        }

        // Deliberately no `writes.waitUntilAllOperationsAreFinished()`: if this
        // regresses, the writers are stuck too, and a blocking join would turn
        // a failed assertion into a hung test run. A healthy run takes well under
        // a second and a deadlock never finishes, so the timeout only needs
        // headroom for a loaded CI simulator.
        wait(for: [finished], timeout: 10)
        diskCache.clear()
    }

    /// A read must never resurrect a value that a later `remove` deleted.
    /// `get` reads from disk and then re-inserts into memory; if a `remove`
    /// lands between those two steps the stale value would be served from
    /// memory afterwards (e.g. an old library logo after its URL changed).
    func testRemove_afterConcurrentDiskReads_leavesNoValue() {
        let diskCache = GeneralCache<String, Data>(
            cacheName: "RemoveOrdering-\(UUID().uuidString)",
            mode: .memoryAndDisk
        )
        let key = "logo"
        let payload = Data(repeating: 0x01, count: 64_000)

        for _ in 0..<50 {
            diskCache.set(payload, for: key, expiresIn: 3600)
            diskCache.clearMemory()
            DispatchQueue.concurrentPerform(iterations: 8) { i in
                if i == 0 {
                    diskCache.remove(for: key)
                } else {
                    _ = diskCache.get(for: key)
                }
            }
            // Whatever order the readers ran in, the remove came after the set
            // and nothing set the key again, so it must be gone.
            XCTAssertNil(diskCache.get(for: key), "A removed key must not come back from memory")
        }
        diskCache.clear()
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

        // Poll the written FILE, not just the directory. Writes used to be
        // async barrier blocks, and waiting on directory-existence alone
        // returned while the file write was still queued, racing the
        // `removeItem` below. `set` now writes synchronously (PP-5134), so this
        // returns at once, but the poll stays correct if writes move off the
        // caller's thread again.
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
