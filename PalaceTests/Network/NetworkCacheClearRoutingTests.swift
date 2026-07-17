//
//  NetworkCacheClearRoutingTests.swift
//  PalaceTests
//
//  N1 (swarm_27c181b5 — cache-clear split-brain): the app's hygiene paths
//  (sign-out, force-reset, memory-pressure cleanup, the 7-day stale wipe) must
//  clear the network executor's PRIVATE URLCache — the cache that actually
//  serves feeds (built by `TPPCaching.makeCache`) — NOT `URLCache.shared`.
//  Before N1 the clears hit `URLCache.shared`, which is a different instance, so
//  the wipe was a no-op for feeds AND signed-out authenticated responses could
//  persist in the executor's own disk cache.
//
//  These tests pin the redirect behaviorally + structurally:
//    1. `TPPNetworkExecutor.clearCache()` empties the executor's own URLCache.
//    2. Clearing `URLCache.shared` does NOT (the split-brain), while the
//       executor's clearCache() does — proving the redirect is both necessary
//       and correct.
//    3. The sign-out / force-reset source sites route through the executor and
//       no longer clear `URLCache.shared` — a revert to the wrong cache fails.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

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

    // MARK: - Structural: sign-out / force-reset route through the executor

    /// Revert-guard for the sign-out AND force-reset redirects: both sites must
    /// clear the network executor's cache and must NOT call
    /// `URLCache.shared.removeAllCachedResponses()`. A revert to the wrong cache
    /// (re-introducing the split-brain / privacy leak) fails this test.
    ///
    /// This is a source-structural test (like the MetaTests lints) because the
    /// production sites hardwire `AppContainer.production().networkExecutor` —
    /// there is no injection seam to spy without restructuring critical-path
    /// sign-out control flow (forbidden) or exercising real
    /// keychain / WKWebsiteDataStore singletons (banned by the TDD rules).
    func testSignOutAndForceReset_routeCacheClearThroughExecutor_notURLCacheShared() throws {
        let repoRoot = URL(fileURLWithPath: #file)
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

            XCTAssertTrue(source.contains("networkExecutor.clearCache()"),
                          "\(site) must route the hygiene cache-clear through the executor")
            XCTAssertFalse(source.contains("URLCache.shared.removeAllCachedResponses()"),
                           "\(site) must NOT clear URLCache.shared — feeds live in the executor's private cache (N1 split-brain)")
        }
    }
}
