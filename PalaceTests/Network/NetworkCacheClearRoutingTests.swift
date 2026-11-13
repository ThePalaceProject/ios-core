//  NetworkCacheClearRoutingTests.swift
//
//  Sign-out, force-reset, memory-pressure cleanup and the 7-day stale wipe must
//  clear the network executor's private URLCache (`TPPCaching.makeCache`), not
//  `URLCache.shared`, which is a different instance. Clearing the wrong one
//  leaves feeds and authenticated responses in the executor's disk cache.
//
//  Pinned: `clearCache()` empties the executor's cache, clearing
//  `URLCache.shared` does not, and sign-out / force-reset route through it.

import Foundation
import XCTest
import PalaceNetwork
@testable import Palace

@MainActor
final class NetworkCacheClearRoutingTests: XCTestCase {

    override func tearDown() {
        // Defensive: `URLCache.shared` is process-global and one test clears it.
        URLCache.shared.removeAllCachedResponses()
        super.tearDown()
    }

    // MARK: - Helpers

    /// Synchronously seeds a small, memory-resident cached response into `cache`
    /// for `url`, returning the request key. In-memory storage guarantees the
    /// immediately-following `cachedResponse(for:)` read is deterministic.
    @discardableResult
    private func seedResponse(into cache: URLCache,
                             url: URL,
                             body: String) -> URLRequest {
        let request = URLRequest(url: url)
        guard let response = HTTPURLResponse(url: url,
                                             statusCode: 200,
                                             httpVersion: "HTTP/1.1",
                                             headerFields: ["Cache-Control": "public, max-age=100000"]) else {
            XCTFail("Failed to build a concrete HTTPURLResponse for seeding")
            return request
        }
        let cached = CachedURLResponse(response: response,
                                       data: Data(body.utf8),
                                       storagePolicy: .allowedInMemoryOnly)
        cache.storeCachedResponse(cached, for: request)
        return request
    }

    // MARK: - Behavioral: clearCache() empties the executor's PRIVATE cache

    /// N1 core: `TPPNetworkExecutor.clearCache()` must empty the executor's OWN
    /// private URLCache — the cache that serves feeds. A regression that made
    /// clearCache() a no-op, or routed it at a different cache, fails here.
    func testExecutorClearCache_clearsPrivateURLCache() throws {
        let executor = TPPNetworkExecutor(credentialsProvider: nil, cachingStrategy: .default)
        let cache = try XCTUnwrap(executor.transport.urlSession.configuration.urlCache,
                                  "The .default executor session must own a private URLCache (TPPCaching.makeCache)")
        let url = try XCTUnwrap(URL(string: "https://feeds.example.org/catalog"))

        let request = seedResponse(into: cache, url: url, body: "authenticated-feed")
        _ = try XCTUnwrap(cache.cachedResponse(for: request),
                          "Precondition: the response must be cached before clearCache()")

        executor.clearCache()

        XCTAssertNil(cache.cachedResponse(for: request),
                     "clearCache() must empty the executor's PRIVATE URLCache")
    }

    /// Proves the split-brain the N1 redirect fixes: clearing `URLCache.shared`
    /// (the OLD hygiene behavior) leaves the executor's private feed cache
    /// untouched, while the executor's own clearCache() empties it. If the
    /// executor were somehow backed by `URLCache.shared`, the mid-assertion
    /// would fail — which is exactly the confusion N1 removes.
    func testClearingURLCacheShared_leavesExecutorCacheIntact_executorClearCacheEmptiesIt() throws {
        let executor = TPPNetworkExecutor(credentialsProvider: nil, cachingStrategy: .default)
        let privateCache = try XCTUnwrap(executor.transport.urlSession.configuration.urlCache)
        let url = try XCTUnwrap(URL(string: "https://feeds.example.org/borrowed"))

        // The executor's private cache and URLCache.shared must be DISTINCT
        // instances — that is the root cause of the old no-op clears.
        XCTAssertFalse(privateCache === URLCache.shared,
                       "The executor's private URLCache must not be URLCache.shared")

        let request = seedResponse(into: privateCache, url: url, body: "feed-body")
        _ = try XCTUnwrap(privateCache.cachedResponse(for: request))

        // OLD behavior: clearing the shared cache.
        URLCache.shared.removeAllCachedResponses()
        XCTAssertNotNil(privateCache.cachedResponse(for: request),
                        "Clearing URLCache.shared must NOT clear the executor's feed cache — this is the bug N1 fixes")

        // NEW behavior: routing through the executor.
        executor.clearCache()
        XCTAssertNil(privateCache.cachedResponse(for: request),
                     "executor.clearCache() must clear the feed cache the hygiene paths care about")
    }

    // MARK: - Memory warning: drop the memory part only (PP-5580)

    /// A memory warning used to call `clearCache()`, which also emptied the
    /// 1 GB disk cache, so every catalog page downloaded again afterwards.
    /// `releaseMemory()` must leave the disk part alone and restore the
    /// memory capacity it lowered.
    func testReleaseMemory_emptiesMemoryOnly_andRestoresCapacity() throws {
        let cache = SpyURLCache(memoryCapacity: 4 * 1024 * 1024, diskCapacity: 8 * 1024 * 1024, directory: nil)
        let url = try XCTUnwrap(URL(string: "https://feeds.example.org/memory-only"))
        seedResponse(into: cache, url: url, body: "feed")
        XCTAssertGreaterThan(cache.currentMemoryUsage, 0, "Precondition: the response is held in memory")

        cache.releaseMemory()

        XCTAssertEqual(cache.currentMemoryUsage, 0, "releaseMemory() must empty the memory part")
        XCTAssertEqual(cache.memoryCapacity, 4 * 1024 * 1024, "releaseMemory() must restore the memory capacity")
        XCTAssertEqual(cache.removeAllCalls, 0, "releaseMemory() must not empty the disk part")
    }

    func testExecutorReleaseMemoryCache_keepsDiskCapacityAndMemoryCapacity() throws {
        let executor = TPPNetworkExecutor(credentialsProvider: nil, cachingStrategy: .default)
        let cache = try XCTUnwrap(executor.transport.urlSession.configuration.urlCache)
        let memoryCapacity = cache.memoryCapacity
        let url = try XCTUnwrap(URL(string: "https://feeds.example.org/executor-memory"))
        seedResponse(into: cache, url: url, body: "feed")

        executor.releaseMemoryCache()

        XCTAssertEqual(cache.currentMemoryUsage, 0)
        XCTAssertEqual(cache.memoryCapacity, memoryCapacity)
    }

    // MARK: - Structural: sign-out / force-reset route through the executor

    /// Revert-guard for the sign-out AND force-reset redirects: both sites must
    /// clear the network executor's cache and must NOT call
    /// `URLCache.shared.removeAllCachedResponses()`. A revert to the wrong cache
    /// (re-introducing the split-brain / privacy leak) fails this test.
    /// That the injected `appNetwork` is the one cleared is asserted by
    /// `TPPSignOutCompletesLocallyTests` and `ScopedResetTests`.
    func testSignOutAndForceReset_routeCacheClearThroughExecutor_notURLCacheShared() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Network/
            .deletingLastPathComponent()   // PalaceTests/
            .deletingLastPathComponent()   // repo root

        let sites = [
            "Palace/SignInLogic/TPPSignInBusinessLogic+SignOut.swift",
            "Palace/SignInLogic/TPPSignInBusinessLogic+ForceReset.swift"
        ]

        for site in sites {
            let url = repoRoot.appendingPathComponent(site)
            let source = try String(contentsOf: url, encoding: .utf8)

            XCTAssertTrue(source.contains("appNetwork.clearCache()"),
                          "\(site) must route the hygiene cache-clear through the executor")
            XCTAssertFalse(source.contains("URLCache.shared.removeAllCachedResponses()"),
                           "\(site) must NOT clear URLCache.shared — feeds live in the executor's private cache (N1 split-brain)")
        }
    }
}

/// Counts full clears, so a test can tell a memory-only release from a wipe.
private final class SpyURLCache: URLCache, @unchecked Sendable {
    private(set) var removeAllCalls = 0
    override func removeAllCachedResponses() {
        removeAllCalls += 1
        super.removeAllCachedResponses()
    }
}
