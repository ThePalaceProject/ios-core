import XCTest
@testable import Palace

private struct TestValue: Codable, Equatable {
    let text: String
    let number: Int
}

final class GeneralCacheTests: XCTestCase {
    fileprivate var cache: GeneralCache<String, TestValue>!

    override func setUp() {
        super.setUp()
        cache = GeneralCache<String, TestValue>(cacheName: "GeneralCacheTest")
        cache.clear()
    }

    override func tearDown() {
        cache.clear()
        super.tearDown()
    }

    // MARK: - Basic Operations
    
    func testSetAndGetInMemory() {
        let value = TestValue(text: "hello", number: 42)
        cache.set(value, for: "key1")
        let result = cache.get(for: "key1")
        XCTAssertEqual(result, value)
    }

    func testSetAndGetFromDisk() {
        let value = TestValue(text: "disk", number: 99)
        cache.set(value, for: "key2")
        cache.clearMemory()
        let result = cache.get(for: "key2")
        XCTAssertEqual(result, value)
    }

    func testExpirationDateIsSet() {
        // Test that expiration is properly stored
        let value = TestValue(text: "expire", number: 1)
        let expirationInterval: TimeInterval = 3600 // 1 hour
        
        cache.set(value, for: "key3", expiresIn: expirationInterval)
        
        // Value should exist immediately after setting
        XCTAssertEqual(cache.get(for: "key3"), value)
        
        // Verify the file URL exists and has modification date set
        let fileURL = cache.fileURL(for: "key3")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        
        // Check that modification date (used as expiration) is in the future
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        if let modDate = attrs?[.modificationDate] as? Date {
            XCTAssertGreaterThan(modDate, Date(), "Expiration date should be in the future")
        }
    }
    
    func testExpiredEntriesAreRejected() {
        // Create a cache entry with past expiration by directly manipulating the file
        let value = TestValue(text: "expired", number: 1)
        cache.set(value, for: "expiredKey", expiresIn: 3600)
        
        // Manually set the file's modification date to the past
        let fileURL = cache.fileURL(for: "expiredKey")
        let pastDate = Date().addingTimeInterval(-60) // 1 minute ago
        try? FileManager.default.setAttributes([.modificationDate: pastDate], ofItemAtPath: fileURL.path)
        
        // Clear memory to force disk read
        cache.clearMemory()
        
        // Entry should be nil because it's expired
        XCTAssertNil(cache.get(for: "expiredKey"), "Expired entry should not be returned")
    }

    func testRemove() {
        let value = TestValue(text: "remove", number: 2)
        cache.set(value, for: "key4")
        cache.remove(for: "key4")
        XCTAssertNil(cache.get(for: "key4"))
    }

    func testClear() {
        cache.set(TestValue(text: "a", number: 1), for: "a")
        cache.set(TestValue(text: "b", number: 2), for: "b")
        cache.clear()
        XCTAssertNil(cache.get(for: "a"))
        XCTAssertNil(cache.get(for: "b"))
    }

    // MARK: - CachingMode Tests
    
    func testMemoryOnlyMode() {
        let cache = GeneralCache<String, TestValue>(cacheName: "MemoryOnlyTest", mode: .memoryOnly)
        let value = TestValue(text: "mem", number: 1)
        cache.set(value, for: "k")
        XCTAssertEqual(cache.get(for: "k"), value)
        cache.clearMemory()
        XCTAssertNil(cache.get(for: "k"))
    }

    func testDiskOnlyMode() {
        let cache = GeneralCache<String, TestValue>(cacheName: "DiskOnlyTest", mode: .diskOnly)
        let value = TestValue(text: "disk", number: 2)
        cache.set(value, for: "k")
        XCTAssertEqual(cache.get(for: "k"), value)
        cache.remove(for: "k")
        XCTAssertNil(cache.get(for: "k"))
    }

    func testMemoryAndDiskMode() {
        let cache = GeneralCache<String, TestValue>(cacheName: "MemDiskTest", mode: .memoryAndDisk)
        let value = TestValue(text: "both", number: 3)
        cache.set(value, for: "k")
        XCTAssertEqual(cache.get(for: "k"), value)
        cache.clearMemory()
        XCTAssertEqual(cache.get(for: "k"), value)
    }

    func testNoneMode() {
        let cache = GeneralCache<String, TestValue>(cacheName: "NoneTest", mode: .none)
        let value = TestValue(text: "none", number: 4)
        cache.set(value, for: "k")
        XCTAssertNil(cache.get(for: "k"))
    }

    // MARK: - CachePolicy Tests (async)
    
    func testCacheFirstPolicy() async throws {
        let cache = GeneralCache<String, TestValue>(cacheName: "CacheFirstTest")
        var fetchCount = 0
        let fetcher: () async throws -> TestValue = {
            fetchCount += 1
            return TestValue(text: "fetched", number: 1)
        }
        let v1 = try await cache.get("k", policy: .cacheFirst, fetcher: fetcher)
        XCTAssertEqual(v1, TestValue(text: "fetched", number: 1))
        XCTAssertEqual(fetchCount, 1)
        let v2 = try await cache.get("k", policy: .cacheFirst, fetcher: fetcher)
        XCTAssertEqual(v2, v1)
        XCTAssertEqual(fetchCount, 1, "Should use cached value, not fetch again")
    }

    func testNetworkFirstPolicy() async throws {
        let cache = GeneralCache<String, TestValue>(cacheName: "NetworkFirstTest")
        var fetchCount = 0
        let fetcher: () async throws -> TestValue = {
            fetchCount += 1
            return TestValue(text: "net", number: fetchCount)
        }
        let v1 = try await cache.get("k", policy: .networkFirst, fetcher: fetcher)
        let v2 = try await cache.get("k", policy: .networkFirst, fetcher: fetcher)
        XCTAssertEqual(v1.text, "net")
        XCTAssertEqual(v2.text, "net")
        XCTAssertEqual(fetchCount, 2, "Should fetch each time with networkFirst")
    }

    func testCacheThenNetworkPolicy_ReturnsCache() async throws {
        let cache = GeneralCache<String, TestValue>(cacheName: "CacheThenNetworkTest")
        
        // Pre-populate cache
        let cachedValue = TestValue(text: "cached", number: 1)
        cache.set(cachedValue, for: "k")
        
        var fetchCount = 0
        let fetcher: () async throws -> TestValue = {
            fetchCount += 1
            return TestValue(text: "fresh", number: fetchCount)
        }
        
        // Should return cached value immediately
        let result = try await cache.get("k", policy: .cacheThenNetwork, fetcher: fetcher)
        XCTAssertEqual(result, cachedValue, "Should return cached value")
        
        // Fetcher runs in background, give it a moment to complete
        // But don't rely on the timing - just verify the cache hit behavior
    }
    
    func testCacheThenNetworkPolicy_FetchesWhenEmpty() async throws {
        let cache = GeneralCache<String, TestValue>(cacheName: "CacheThenNetworkEmptyTest")
        
        var fetchCount = 0
        let fetcher: () async throws -> TestValue = {
            fetchCount += 1
            return TestValue(text: "fresh", number: fetchCount)
        }
        
        // Cache is empty, should fetch
        let result = try await cache.get("k", policy: .cacheThenNetwork, fetcher: fetcher)
        XCTAssertEqual(result, TestValue(text: "fresh", number: 1))
        XCTAssertEqual(fetchCount, 1)
    }

    func testTimedCachePolicy_UsesCache() async throws {
        let cache = GeneralCache<String, TestValue>(cacheName: "TimedCacheTest")
        var fetchCount = 0
        let fetcher: () async throws -> TestValue = {
            fetchCount += 1
            return TestValue(text: "timed", number: fetchCount)
        }
        
        // First call fetches
        let v1 = try await cache.get("k", policy: .timedCache(3600), fetcher: fetcher)
        XCTAssertEqual(v1, TestValue(text: "timed", number: 1))
        XCTAssertEqual(fetchCount, 1)
        
        // Second call uses cache
        let v2 = try await cache.get("k", policy: .timedCache(3600), fetcher: fetcher)
        XCTAssertEqual(v2, v1)
        XCTAssertEqual(fetchCount, 1, "Should use cached value within expiration window")
    }
    
    func testTimedCachePolicy_RefetchesAfterExpiration() async throws {
        let cache = GeneralCache<String, TestValue>(cacheName: "TimedCacheExpireTest")
        var fetchCount = 0
        let fetcher: () async throws -> TestValue = {
            fetchCount += 1
            return TestValue(text: "timed", number: fetchCount)
        }
        
        // First call fetches with short expiration
        _ = try await cache.get("k", policy: .timedCache(3600), fetcher: fetcher)
        XCTAssertEqual(fetchCount, 1)
        
        // Manually expire the cache entry
        let fileURL = cache.fileURL(for: "k")
        let pastDate = Date().addingTimeInterval(-60)
        try? FileManager.default.setAttributes([.modificationDate: pastDate], ofItemAtPath: fileURL.path)
        cache.clearMemory()
        
        // Next call should refetch
        let v2 = try await cache.get("k", policy: .timedCache(3600), fetcher: fetcher)
        XCTAssertEqual(v2, TestValue(text: "timed", number: 2))
        XCTAssertEqual(fetchCount, 2)
    }

    func testNoCachePolicy() async throws {
        let cache = GeneralCache<String, TestValue>(cacheName: "NoCacheTest")
        var fetchCount = 0
        let fetcher: () async throws -> TestValue = {
            fetchCount += 1
            return TestValue(text: "no", number: fetchCount)
        }
        let v1 = try await cache.get("k", policy: .noCache, fetcher: fetcher)
        let v2 = try await cache.get("k", policy: .noCache, fetcher: fetcher)
        XCTAssertEqual(fetchCount, 2, "Should fetch every time with noCache")
        XCTAssertNotEqual(v1, v2)
    }
    
    // MARK: - Edge Cases
    
    func testConcurrentAccess() async {
        let cache = GeneralCache<String, TestValue>(cacheName: "ConcurrencyTest")
        
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    let value = TestValue(text: "concurrent", number: i)
                    cache.set(value, for: "key\(i)")
                    _ = cache.get(for: "key\(i)")
                }
            }
        }
        
        // Verify some values persisted correctly
        let result = cache.get(for: "key50")
        XCTAssertNotNil(result)
    }
    
    func testLargeValueCaching() {
        let largeText = String(repeating: "x", count: 100_000)
        let value = TestValue(text: largeText, number: 1)
        cache.set(value, for: "largeKey")
        
        cache.clearMemory()
        let result = cache.get(for: "largeKey")
        XCTAssertEqual(result?.text.count, 100_000)
    }
}
