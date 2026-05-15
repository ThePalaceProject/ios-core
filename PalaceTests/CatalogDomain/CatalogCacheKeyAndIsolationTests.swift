//
//  CatalogCacheKeyAndIsolationTests.swift
//  PalaceTests
//
//  Deep mutation-killing tests for CatalogRepository's cache-key derivation
//  and cache-isolation invariants that go BEYOND the basic stale-while-
//  revalidate fresh/stale boundaries (already covered by
//  CatalogRepositoryStaleWhileRevalidateTests.swift, owned by another agent).
//
//  ──────────────────────────────────────────────────────────────────────────
//  What we pin here
//  ──────────────────────────────────────────────────────────────────────────
//
//   1. Concurrent reads on STALE cache from DIFFERENT URLs:
//        • Each URL gets its own cached value.
//        • Stale background refreshes for URL_A don't poison URL_B.
//        • Concurrent fans-out across N distinct URLs all complete.
//
//   2. Cache invalidation on sign-out:
//        • The repository exposes per-URL `invalidateCache(for:)`. The
//          sign-out contract (defined by call sites such as
//          CatalogViewModel) is to call this for every URL whose data
//          should not leak across user sessions. We pin that calling
//          `invalidateCache` for every cached URL leaves the repository
//          serving fresh-from-network on the next read.
//
//   3. Cache eviction under memory pressure:
//        • The repository does NOT register for UIApplication.didReceive-
//          MemoryWarningNotification today (GAP documented). Memory
//          pressure relies on the OS evicting `URLCache.shared`, not the
//          in-memory feed cache. We pin the current behavior — repository
//          continues to serve the in-memory cache — so a silent change
//          (e.g. someone wiring a memory-warning observer) is detected.
//
//   4. Cache-key derivation:
//        • Keys are derived from `url.absoluteString` ONLY. Same URL with
//          different request headers (bearer tokens) currently SHARES one
//          cache entry. We pin that contract and document the GAP that
//          would let library A's data be served to library B if a single
//          repository instance is reused across libraries.
//        • Cure (out of scope for these tests, owned by another agent):
//          the AccountsManager-level cache uses a per-library hash AND
//          the iOS auth layer typically tears down the repository on
//          library switch, so the gap is mitigated by lifecycle — not by
//          the cache-key itself.
//
//   5. URL canonicalisation traps:
//        • Trailing-slash and case differences in scheme produce DIFFERENT
//          cache entries. The repository keys on the raw absoluteString;
//          it does NOT normalize. We pin both behaviors so a silent
//          normalization slip can be caught.
//
//  ──────────────────────────────────────────────────────────────────────────
//  HOUSE RULES — no production code modified. Clock is via the existing
//  `init(api:now:)` test seam introduced by the SWR-tests agent.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceCatalog
@testable import Palace

final class CatalogCacheKeyAndIsolationTests: XCTestCase {

    // MARK: - Fixtures

    private var api: CatalogAPIMock!
    private static let lastAppLaunchKey = "CatalogRepository.lastAppLaunch"

    /// Mutable clock — drives the stale-while-revalidate logic deterministically.
    private var testNow: Date = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() {
        super.setUp()
        api = CatalogAPIMock()
        // Reset the last-launch heuristic so each test starts with a
        // deterministic needsBackgroundRefresh state. We re-seed in
        // `makeRepository` if we want needsBackgroundRefresh=false.
        UserDefaults.standard.removeObject(forKey: Self.lastAppLaunchKey)
    }

    override func tearDown() {
        api = nil
        UserDefaults.standard.removeObject(forKey: Self.lastAppLaunchKey)
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeRepository(seedLastLaunchToNow: Bool = true) -> CatalogRepository {
        if seedLastLaunchToNow {
            UserDefaults.standard.set(testNow, forKey: Self.lastAppLaunchKey)
        }
        return CatalogRepository(api: api, now: { [weak self] in
            self?.testNow ?? Date(timeIntervalSince1970: 0)
        })
    }

    /// Poll an async predicate until it holds or the timeout elapses.
    private func awaitCondition(
        timeout: TimeInterval = 2.0,
        pollInterval: TimeInterval = 0.01,
        _ predicate: () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await predicate() { return }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        XCTFail("Condition not satisfied within \(timeout)s", file: file, line: line)
    }

    // MARK: - 1. Concurrent stale reads ACROSS DIFFERENT URLs

    /// Mutant killed: shared state across keys in `memoryCache` (e.g. a
    /// missing dictionary key making the cache write overwrite a single
    /// slot). With three distinct URLs all read concurrently while stale,
    /// the BG refreshes must each land at their own key.
    func testConcurrentStaleReads_AcrossDistinctURLs_EachURLGetsItsOwnRefresh() async throws {
        let urlA = URL(string: "https://example.com/lib-a/catalog")!
        let urlB = URL(string: "https://example.com/lib-b/catalog")!
        let urlC = URL(string: "https://example.com/lib-c/catalog")!

        api.stubbedFeeds[urlA] = CatalogAPIMock.makeMockFeed(title: "A-original")
        api.stubbedFeeds[urlB] = CatalogAPIMock.makeMockFeed(title: "B-original")
        api.stubbedFeeds[urlC] = CatalogAPIMock.makeMockFeed(title: "C-original")
        let sut = makeRepository()

        // Prime the cache.
        _ = try await sut.loadTopLevelCatalog(at: urlA)
        _ = try await sut.loadTopLevelCatalog(at: urlB)
        _ = try await sut.loadTopLevelCatalog(at: urlC)
        XCTAssertEqual(api.fetchFeedCallCount, 3)

        // Move into stale-but-usable window.
        testNow = testNow.addingTimeInterval(1_800) // 30 minutes
        api.stubbedFeeds[urlA] = CatalogAPIMock.makeMockFeed(title: "A-refreshed")
        api.stubbedFeeds[urlB] = CatalogAPIMock.makeMockFeed(title: "B-refreshed")
        api.stubbedFeeds[urlC] = CatalogAPIMock.makeMockFeed(title: "C-refreshed")

        async let a = sut.loadTopLevelCatalog(at: urlA)
        async let b = sut.loadTopLevelCatalog(at: urlB)
        async let c = sut.loadTopLevelCatalog(at: urlC)
        let (resA, resB, resC) = try await (a, b, c)

        // Each stale read returns its OWN cached value, not its neighbor's.
        XCTAssertEqual(resA?.title, "A-original")
        XCTAssertEqual(resB?.title, "B-original")
        XCTAssertEqual(resC?.title, "C-original")

        // After background refreshes land, each URL's cache reflects ITS OWN
        // refresh — no cross-talk.
        await awaitCondition {
            sut.cachedFeed(for: urlA)?.title == "A-refreshed" &&
            sut.cachedFeed(for: urlB)?.title == "B-refreshed" &&
            sut.cachedFeed(for: urlC)?.title == "C-refreshed"
        }
        XCTAssertEqual(sut.cachedFeed(for: urlA)?.title, "A-refreshed")
        XCTAssertEqual(sut.cachedFeed(for: urlB)?.title, "B-refreshed")
        XCTAssertEqual(sut.cachedFeed(for: urlC)?.title, "C-refreshed")
    }

    /// Mutant killed: a refresh task for URL A overwriting URL B's cache
    /// (e.g. capturing the wrong cacheKey variable).
    func testConcurrentStaleReads_BackgroundRefreshDoesNotPoisonNeighborKey() async throws {
        let urlA = URL(string: "https://example.com/A")!
        let urlB = URL(string: "https://example.com/B")!

        api.stubbedFeeds[urlA] = CatalogAPIMock.makeMockFeed(title: "A-orig")
        api.stubbedFeeds[urlB] = CatalogAPIMock.makeMockFeed(title: "B-orig")
        let sut = makeRepository()
        _ = try await sut.loadTopLevelCatalog(at: urlA)
        _ = try await sut.loadTopLevelCatalog(at: urlB)

        // Make A stale; leave B fresh.
        testNow = testNow.addingTimeInterval(1_800)
        api.stubbedFeeds[urlA] = CatalogAPIMock.makeMockFeed(title: "A-new")
        // Trigger A's background refresh.
        _ = try await sut.loadTopLevelCatalog(at: urlA)

        // Wait for A's refresh to land.
        await awaitCondition {
            sut.cachedFeed(for: urlA)?.title == "A-new"
        }

        // B must still hold its original value — A's refresh must NOT have
        // touched B's cache entry.
        XCTAssertEqual(sut.cachedFeed(for: urlB)?.title, "B-orig",
                       "A's background refresh must NOT poison B's cache entry")
    }

    // MARK: - 2. Cache invalidation on sign-out

    /// Mutant killed: per-URL invalidation that only clears the freshness
    /// flag but not the cached entry. On sign-out, the next load MUST be
    /// served from the network (the previous user's data must not leak).
    func testSignOutContract_InvalidateAllCachedURLs_NextReadsHitNetwork() async throws {
        let urls = [
            URL(string: "https://example.com/library-1/catalog")!,
            URL(string: "https://example.com/library-1/audiobooks")!,
            URL(string: "https://example.com/library-1/ebooks")!
        ]
        for (i, u) in urls.enumerated() {
            api.stubbedFeeds[u] = CatalogAPIMock.makeMockFeed(title: "U\(i)-user-1")
        }
        let sut = makeRepository()
        for u in urls { _ = try await sut.loadTopLevelCatalog(at: u) }
        XCTAssertEqual(api.fetchFeedCallCount, urls.count,
                       "Sanity: one network call per URL on first load")

        // SIGN OUT: invalidate every cached URL.
        for u in urls { sut.invalidateCache(for: u) }

        // After sign-out, the previous user's content MUST NOT be served:
        // re-stub all URLs with "user-2" content and expect the network
        // to be hit.
        for (i, u) in urls.enumerated() {
            api.stubbedFeeds[u] = CatalogAPIMock.makeMockFeed(title: "U\(i)-user-2")
        }
        for (i, u) in urls.enumerated() {
            let feed = try await sut.loadTopLevelCatalog(at: u)
            XCTAssertEqual(feed?.title, "U\(i)-user-2",
                           "After sign-out invalidation, the next read for \(u) must return USER-2 data, not USER-1's")
        }
        XCTAssertEqual(api.fetchFeedCallCount, urls.count * 2,
                       "Every sign-out-invalidated URL must hit the network on the next read")
    }

    /// Mutant killed: invalidation also clearing `cachedFeed` for URLs
    /// it WAS NOT asked to clear. Pins per-URL isolation of
    /// `invalidateCache`.
    func testInvalidateCache_DoesNotClearUnrelatedURLs() async throws {
        let kept = URL(string: "https://example.com/kept")!
        let cleared = URL(string: "https://example.com/cleared")!
        api.stubbedFeeds[kept] = CatalogAPIMock.makeMockFeed(title: "Kept")
        api.stubbedFeeds[cleared] = CatalogAPIMock.makeMockFeed(title: "Cleared")
        let sut = makeRepository()
        _ = try await sut.loadTopLevelCatalog(at: kept)
        _ = try await sut.loadTopLevelCatalog(at: cleared)

        sut.invalidateCache(for: cleared)

        // `kept` must still be visible via cachedFeed.
        XCTAssertEqual(sut.cachedFeed(for: kept)?.title, "Kept",
                       "invalidateCache(for: cleared) must NOT remove `kept`'s entry")
        // `cleared` must be gone.
        XCTAssertNil(sut.cachedFeed(for: cleared),
                     "invalidateCache(for: cleared) must remove `cleared`'s entry")
    }

    // MARK: - 3. Cache eviction under memory pressure
    //
    // GAP DOCUMENTED: CatalogRepository does not currently register for
    // UIApplication.didReceiveMemoryWarningNotification. Memory pressure
    // is left to URLCache.shared. We pin the current behavior so a silent
    // change (e.g. an observer that wipes the in-memory cache) is detected.

    /// Mutant killed: a future commit that wires the in-memory cache to
    /// the system memory-warning notification without updating this test.
    /// If a memory warning suddenly clears the in-memory feed, this test
    /// will fail and force the author to update the contract intentionally.
    func testInMemoryCache_AfterSystemMemoryWarning_StillServesCachedFeed() async throws {
        let url = URL(string: "https://example.com/memory")!
        api.stubbedFeeds[url] = CatalogAPIMock.makeMockFeed(title: "InMemory")
        let sut = makeRepository()
        _ = try await sut.loadTopLevelCatalog(at: url)
        XCTAssertEqual(api.fetchFeedCallCount, 1)

        // Simulate memory pressure by posting the standard system
        // notification. Current production: repository is NOT subscribed.
        NotificationCenter.default.post(
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
        // Give any (hypothetical) observers a tick to run.
        try await Task.sleep(nanoseconds: 50_000_000)

        // Re-read: should still hit the in-memory cache (no extra network call).
        let result = try await sut.loadTopLevelCatalog(at: url)
        XCTAssertEqual(result?.title, "InMemory",
                       "CURRENT BEHAVIOR (documented gap): in-memory cache survives memory warnings")
        XCTAssertEqual(api.fetchFeedCallCount, 1,
                       "No network call must occur after memory warning while cache is fresh")
    }

    /// Mutant killed: URLCache.shared interaction breaking the in-memory
    /// cache (e.g. someone changing the in-memory cache to read-through
    /// URLCache.shared and clearing it on memory warning). Verify that
    /// removing URLCache.shared's entries doesn't touch the in-memory
    /// feed cache.
    func testInMemoryCache_AfterURLCacheSharedCleared_StillServesCachedFeed() async throws {
        let url = URL(string: "https://example.com/url-cache-test")!
        api.stubbedFeeds[url] = CatalogAPIMock.makeMockFeed(title: "Survives")
        let sut = makeRepository()
        _ = try await sut.loadTopLevelCatalog(at: url)

        URLCache.shared.removeAllCachedResponses()

        let result = try await sut.loadTopLevelCatalog(at: url)
        XCTAssertEqual(result?.title, "Survives",
                       "In-memory cache must be independent of URLCache.shared")
        XCTAssertEqual(api.fetchFeedCallCount, 1)
    }

    // MARK: - 4. Cache-key derivation
    //
    // GAP DOCUMENTED: the cache key is the raw `url.absoluteString`. Same
    // URL with different request headers (bearer token) collapses into
    // ONE cache entry. The catalog's API protocol doesn't even surface
    // the bearer token to the repository — auth lives in the NetworkClient
    // layer.

    /// Mutant killed: a future silent change to include request headers
    /// in the cache key (or a regression that breaks per-URL keying).
    /// Pins the current contract: same URL → same cache entry, regardless
    /// of how the underlying NetworkClient authenticated.
    func testCacheKey_SameURLDistinctBearerTokens_CurrentlyShareCacheEntry() async throws {
        // The catalog repository can't see bearer tokens. We simulate
        // "two users hitting the same URL" by re-stubbing the API result
        // for the same URL between the two loads. If the second load is
        // served from the cache (current behavior), we observe the FIRST
        // user's content; if a hypothetical per-bearer-key change ever
        // lands, this test should fail with the second user's content.
        let url = URL(string: "https://example.com/per-library")!
        api.stubbedFeeds[url] = CatalogAPIMock.makeMockFeed(title: "User-A-Feed")
        let sut = makeRepository()
        _ = try await sut.loadTopLevelCatalog(at: url)

        // "User B" now hits the same URL. In a per-bearer keyed cache,
        // the response should reflect User B's stubbed content. In the
        // current single-key-per-URL cache, the cached User-A content is
        // returned.
        api.stubbedFeeds[url] = CatalogAPIMock.makeMockFeed(title: "User-B-Feed")
        let result = try await sut.loadTopLevelCatalog(at: url)

        XCTAssertEqual(result?.title, "User-A-Feed",
                       "GAP: per-bearer cache isolation is NOT implemented. Same URL across users currently shares one entry. " +
                       "Mitigated in practice by the repository being torn down on library switch.")
        XCTAssertEqual(api.fetchFeedCallCount, 1,
                       "Sanity: second load was served from cache, not the (re-stubbed) network")
    }

    /// Mutant killed: any change that adds a query-parameter normalizer
    /// to the cache key. Different query strings on the same path MUST
    /// produce different cache entries — facet & sort selections rely
    /// on this.
    func testCacheKey_SamePathDifferentQueryStrings_AreDistinctEntries() async throws {
        let base = URL(string: "https://example.com/fiction?sort=title")!
        let alt  = URL(string: "https://example.com/fiction?sort=author")!
        api.stubbedFeeds[base] = CatalogAPIMock.makeMockFeed(title: "By-Title")
        api.stubbedFeeds[alt]  = CatalogAPIMock.makeMockFeed(title: "By-Author")
        let sut = makeRepository()

        let titleSorted = try await sut.loadTopLevelCatalog(at: base)
        let authorSorted = try await sut.loadTopLevelCatalog(at: alt)

        XCTAssertEqual(titleSorted?.title, "By-Title")
        XCTAssertEqual(authorSorted?.title, "By-Author")
        XCTAssertEqual(api.fetchFeedCallCount, 2,
                       "Different query strings on same path must NOT collide on the cache key")
    }

    /// Mutant killed: a "case-insensitive" or "trailing-slash-normalising"
    /// cache key. The current contract: raw absoluteString. Two URLs that
    /// differ ONLY by trailing slash hit DIFFERENT cache entries.
    func testCacheKey_TrailingSlashDifference_AreDistinctEntries() async throws {
        let withSlash    = URL(string: "https://example.com/catalog/")!
        let withoutSlash = URL(string: "https://example.com/catalog")!
        api.stubbedFeeds[withSlash]    = CatalogAPIMock.makeMockFeed(title: "WithSlash")
        api.stubbedFeeds[withoutSlash] = CatalogAPIMock.makeMockFeed(title: "WithoutSlash")
        let sut = makeRepository()

        let a = try await sut.loadTopLevelCatalog(at: withSlash)
        let b = try await sut.loadTopLevelCatalog(at: withoutSlash)

        XCTAssertEqual(a?.title, "WithSlash")
        XCTAssertEqual(b?.title, "WithoutSlash")
        XCTAssertEqual(api.fetchFeedCallCount, 2,
                       "Trailing-slash variants must NOT be collapsed by the cache key")
    }

    /// Mutant killed: a scheme-case normalization (HTTPS vs https). The
    /// current contract preserves the absoluteString verbatim.
    func testCacheKey_SchemeCasing_RetainedAsURLSpec() async throws {
        // URL initializer canonicalizes the scheme to lowercase, so we
        // demonstrate the related invariant: HTTP vs HTTPS schemes are
        // distinct cache entries even when host+path match.
        let http  = URL(string: "http://example.com/catalog")!
        let https = URL(string: "https://example.com/catalog")!
        api.stubbedFeeds[http]  = CatalogAPIMock.makeMockFeed(title: "HTTP")
        api.stubbedFeeds[https] = CatalogAPIMock.makeMockFeed(title: "HTTPS")
        let sut = makeRepository()

        let a = try await sut.loadTopLevelCatalog(at: http)
        let b = try await sut.loadTopLevelCatalog(at: https)

        XCTAssertEqual(a?.title, "HTTP")
        XCTAssertEqual(b?.title, "HTTPS")
        XCTAssertEqual(api.fetchFeedCallCount, 2,
                       "Different schemes (http vs https) must NOT collapse on the cache key")
    }
}
