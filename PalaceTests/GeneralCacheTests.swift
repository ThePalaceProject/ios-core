import XCTest
@testable import Palace

// MARK: - TestValue

private struct TestValue: Codable, Equatable {
  let text: String
  let number: Int
}

// MARK: - GeneralCacheTests

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

  func testExpiration() {
    let value = TestValue(text: "expire", number: 1)
    cache.set(value, for: "key3", expiresIn: 1)
    XCTAssertEqual(cache.get(for: "key3"), value)
    sleep(2)
    XCTAssertNil(cache.get(for: "key3"))
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
    XCTAssertEqual(fetchCount, 1)
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
    XCTAssertEqual(fetchCount, 2)
  }

  func testCacheThenNetworkPolicy() async throws {
    let cache = GeneralCache<String, TestValue>(cacheName: "CacheThenNetworkTest")
    var fetchCount = 0
    let fetcher: () async throws -> TestValue = {
      fetchCount += 1
      return TestValue(text: "ctn", number: fetchCount)
    }
    let v1 = try await cache.get("k", policy: .cacheThenNetwork, fetcher: fetcher)
    XCTAssertEqual(v1, TestValue(text: "ctn", number: 1))
    let v2 = try await cache.get("k", policy: .cacheThenNetwork, fetcher: fetcher)
    XCTAssertEqual(v2, v1)
    let exp = expectation(description: "Background update")
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
      exp.fulfill()
    }
    await fulfillment(of: [exp], timeout: 2)
    let v3 = cache.get(for: "k")
    XCTAssertEqual(v3, TestValue(text: "ctn", number: 2))
  }

  func testTimedCachePolicy() async throws {
    let cache = GeneralCache<String, TestValue>(cacheName: "TimedCacheTest")
    var fetchCount = 0
    let fetcher: () async throws -> TestValue = {
      fetchCount += 1
      return TestValue(text: "timed", number: fetchCount)
    }
    let v1 = try await cache.get("k", policy: .timedCache(1), fetcher: fetcher)
    XCTAssertEqual(v1, TestValue(text: "timed", number: 1))
    let v2 = try await cache.get("k", policy: .timedCache(1), fetcher: fetcher)
    XCTAssertEqual(v2, v1)
    sleep(2)
    let v3 = try await cache.get("k", policy: .timedCache(1), fetcher: fetcher)
    XCTAssertEqual(v3, TestValue(text: "timed", number: 2))
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
    XCTAssertEqual(fetchCount, 2)
    XCTAssertNotEqual(v1, v2)
  }
}
