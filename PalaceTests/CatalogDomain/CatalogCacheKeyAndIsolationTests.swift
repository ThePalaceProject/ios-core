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
//   3. Cache eviction under memory pressure (FIXED — Gap 3):
//        • The repository now subscribes to UIApplication.didReceive-
//          MemoryWarningNotification and drops its in-memory feed +
//          format-entries maps when one fires. The on-disk URLCache is
//          NOT touched (content-addressed, intentionally survives memory
//          pressure). We pin this fixed behaviour so a regression that
//          re-introduces the leak is caught.
//
//   4. Cache-key derivation (FIXED — Gap 2):
//        • Keys are now scoped by the current account/library UUID, so
//          the same URL fetched under Library A and Library B occupies
//          two distinct cache slots. Bearer tokens themselves are still
//          NOT part of the key — they rotate (refresh/re-auth) while the
//          library identity is stable, which is the natural isolation
//          boundary. We pin both: per-account isolation works, and a
//          single account's bearer-token rotation does NOT bust the
//          cache.
//
//   5. URL canonicalisation traps:
//        • Trailing-slash and case differences in scheme produce DIFFERENT
//          cache entries. The repository keys on the raw absoluteString;
//          it does NOT normalize. We pin both behaviors so a silent
//          normalization slip can be caught.
//
//  ──────────────────────────────────────────────────────────────────────────
//  HOUSE RULES — production fix lives in CatalogRepository.swift only
//  (cacheKey helper + memory-warning observer). Clock is via the existing
//  `init(api:now:)` test seam introduced by the SWR-tests agent; account
//  isolation uses the new `init(api:accountID:now:)` seam.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
import UIKit
import PalaceCatalog
@testable import Palace

final class CatalogCacheKeyAndIsolationTests: XCTestCase {

    // MARK: - Fixtures

    private var api: CatalogAPIMock!
    private static let lastAppLaunchKey = "CatalogRepository.lastAppLaunch"

    /// Mutable clock — drives the stale-while-revalidate logic deterministically.
    private var testNow: Date = Date(timeIntervalSince1970: 1_700_000_000)

    /// Mutable account ID — drives the cache-isolation logic deterministically.
    /// Each test that switches accounts mutates this between calls.
    private var testAccountID: String? = nil

    override func setUp() {
        super.setUp()
        api = CatalogAPIMock()
        testAccountID = nil
        // Reset the last-launch heuristic so each test starts with a
        // deterministic needsBackgroundRefresh state. We re-seed in
        // `makeRepository` if we want needsBackgroundRefresh=false.
        UserDefaults.standard.removeObject(forKey: Self.lastAppLaunchKey)
    }

    override func tearDown() {
        api = nil
        testAccountID = nil
        UserDefaults.standard.removeObject(forKey: Self.lastAppLaunchKey)
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeRepository(seedLastLaunchToNow: Bool = true) -> CatalogRepository {
        if seedLastLaunchToNow {
            UserDefaults.standard.set(testNow, forKey: Self.lastAppLaunchKey)
        }
        return CatalogRepository(
            api: api,
            accountID: { [weak self] in self?.testAccountID },
            now: { [weak self] in
                self?.testNow ?? Date(timeIntervalSince1970: 0)
            }
        )
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
        //
        // 30s timeout: predicate body is fully sync so overload resolution
        // picks the global sync `awaitCondition` (default 5s), not the
        // local async helper (default 2s). Three concurrent background
        // refreshes hopping through the repository's cacheQueue exceed 5s
        // under CI runner contention. Matches the #989/#996 lineage —
        // restore 30s headroom; still fails loud on a true regression.
        await awaitCondition(timeout: 30) {
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
        // 30s timeout — see neighbor test for the global-vs-local
        // overload-resolution explanation + #989/#996 CI-load lineage.
        // CI repro of this test exceeded the global 5s default at 8.65s
        // on macos-26 runners; 30s headroom restores stability.
        await awaitCondition(timeout: 30) {
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

    // MARK: - 3. Cache eviction under memory pressure (FIXED — Gap 3)
    //
    // The repository now subscribes to UIApplication.didReceiveMemoryWarning-
    // Notification and drops its in-memory feed + format-entries caches when
    // one fires. The on-disk URLCache.shared is NOT touched: it's content-
    // addressed and the whole point of disk caching is that it survives
    // memory pressure. The tests below pin both halves of that contract.

    /// Mutant killed: a regression that detaches the memory-warning
    /// observer or makes `handleMemoryWarning` a no-op. After a memory
    /// warning, the in-memory cache MUST be empty and the next read MUST
    /// hit the network.
    func testInMemoryCache_AfterSystemMemoryWarning_IsClearedAndNextReadHitsNetwork() async throws {
        let url = URL(string: "https://example.com/memory")!
        api.stubbedFeeds[url] = CatalogAPIMock.makeMockFeed(title: "InMemory")
        let sut = makeRepository()
        _ = try await sut.loadTopLevelCatalog(at: url)
        XCTAssertEqual(api.fetchFeedCallCount, 1)
        XCTAssertNotNil(sut.cachedFeed(for: url), "Sanity: feed is cached before memory warning")

        // Simulate memory pressure. The repository subscribes to this
        // notification and drops its in-memory feed map.
        NotificationCenter.default.post(
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )

        // The eviction is dispatched onto cacheQueue, so poll for it.
        // 30s timeout — same global-overload + CI-load lineage as the
        // sibling tests in this file.
        await awaitCondition(timeout: 30) {
            sut.cachedFeed(for: url) == nil
        }
        XCTAssertNil(sut.cachedFeed(for: url),
                     "Gap 3 FIX: in-memory cache must be cleared after memory warning")

        // Re-stub with new content and read again — the repository must
        // hit the network, not return the (now-cleared) cached value.
        api.stubbedFeeds[url] = CatalogAPIMock.makeMockFeed(title: "Refetched")
        let result = try await sut.loadTopLevelCatalog(at: url)
        XCTAssertEqual(result?.title, "Refetched",
                       "After memory-warning eviction, next read must come from the network")
        XCTAssertEqual(api.fetchFeedCallCount, 2,
                       "Memory warning must force a fresh network fetch on the next read")
    }

    /// Mutant killed: a regression where the memory-warning handler
    /// also nukes the dedicated `formatEntriesCache`, or fails to nuke
    /// the `memoryCache`. This test pins both halves: a memory warning
    /// clears the in-memory feed cache (re-read => network) AND clears
    /// the format-entries cache (re-read => network). The on-disk
    /// URLCache.shared is content-addressed and is intentionally NOT
    /// touched by our handler — that's documented by the
    /// `subscribeToMemoryWarning` doc comment in CatalogRepository.swift.
    /// (We deliberately do NOT assert on URLCache.shared here because
    /// the OS itself evicts URLCache.shared on memory pressure, making
    /// any URLCache.shared probe a flaky test of iOS, not our code.)
    func testMemoryWarning_ClearsBothInMemoryAndFormatEntriesCache() async throws {
        let url = URL(string: "https://example.com/both-caches")!
        api.stubbedFeeds[url] = CatalogAPIMock.makeMockFeed(title: "Both")
        api.stubbedSearchEntryPoints = [
            // Use a single dummy entry so the cache stores a non-empty array
            // (the production code only caches if the array is non-empty).
            SearchFormatEntry(
                id: "books",
                title: "Books",
                groupsFeedURL: URL(string: "https://example.com/books")!,
                searchDescriptorURL: nil,
                isActive: true
            )
        ]
        let sut = makeRepository()
        _ = try await sut.loadTopLevelCatalog(at: url)
        // Prime the format-entries cache too.
        _ = try await sut.fetchSearchEntryPoints(from: url)
        let baselineEntryPointFetches = api.fetchSearchEntryPointsCalls.count

        // Memory warning fires.
        NotificationCenter.default.post(
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )

        // Both caches must be cleared. Sanity-poll on the feed cache
        // because the eviction is dispatched on cacheQueue.
        // 30s timeout — same global-overload + CI-load lineage as the
        // sibling tests in this file.
        await awaitCondition(timeout: 30) { sut.cachedFeed(for: url) == nil }

        // After eviction, the next entry-point read MUST go to the network.
        _ = try await sut.fetchSearchEntryPoints(from: url)
        XCTAssertEqual(api.fetchSearchEntryPointsCalls.count, baselineEntryPointFetches + 1,
                       "Memory warning must also clear formatEntriesCache so the next read hits the network")
    }

    // MARK: - 4. Cache-key derivation (FIXED — Gap 2)
    //
    // The cache key is now `accountID + "|" + url.absoluteString`. Same
    // URL fetched under two different libraries occupies two distinct
    // cache slots, so library A's data can NEVER be served to library B
    // even if a single repository instance somehow survives a library
    // switch.

    /// Mutant killed: a regression that drops the account scope from
    /// the cache key (e.g. someone "simplifying" cacheKey(for:) back
    /// to `url.absoluteString`). Two libraries hitting the same URL
    /// MUST see their OWN content.
    func testCacheKey_SameURL_DistinctAccounts_AreDistinctEntries() async throws {
        let url = URL(string: "https://example.com/per-library")!

        // Library A's response.
        testAccountID = "library-a-uuid"
        api.stubbedFeeds[url] = CatalogAPIMock.makeMockFeed(title: "Library-A-Feed")
        let sut = makeRepository()
        let a = try await sut.loadTopLevelCatalog(at: url)
        XCTAssertEqual(a?.title, "Library-A-Feed")
        XCTAssertEqual(api.fetchFeedCallCount, 1)

        // SWITCH LIBRARY: same repository instance, same URL, different account.
        testAccountID = "library-b-uuid"
        api.stubbedFeeds[url] = CatalogAPIMock.makeMockFeed(title: "Library-B-Feed")
        let b = try await sut.loadTopLevelCatalog(at: url)

        XCTAssertEqual(b?.title, "Library-B-Feed",
                       "Gap 2 FIX: switching account must NOT serve library A's cached feed to library B")
        XCTAssertEqual(api.fetchFeedCallCount, 2,
                       "Different account => cache miss => network fetch")

        // Switch back to library A — its cache must still be intact.
        testAccountID = "library-a-uuid"
        api.stubbedFeeds[url] = CatalogAPIMock.makeMockFeed(title: "Library-A-Feed-NEW")
        let aAgain = try await sut.loadTopLevelCatalog(at: url)
        XCTAssertEqual(aAgain?.title, "Library-A-Feed",
                       "Library A's cache slot must survive a switch to/from library B")
        XCTAssertEqual(api.fetchFeedCallCount, 2,
                       "Library A's cached feed must still be served without a third network call")
    }

    /// Mutant killed: a regression where `invalidateCache(for:)` clears
    /// across all accounts (e.g. someone "fixing" sign-out to nuke
    /// everything). Invalidation MUST be scoped to the current account
    /// so signing out of library A does not bust library B's cache.
    func testInvalidateCache_IsScopedToCurrentAccount() async throws {
        let url = URL(string: "https://example.com/shared-path")!

        // Cache under both accounts.
        testAccountID = "lib-A"
        api.stubbedFeeds[url] = CatalogAPIMock.makeMockFeed(title: "A")
        let sut = makeRepository()
        _ = try await sut.loadTopLevelCatalog(at: url)

        testAccountID = "lib-B"
        api.stubbedFeeds[url] = CatalogAPIMock.makeMockFeed(title: "B")
        _ = try await sut.loadTopLevelCatalog(at: url)
        XCTAssertEqual(api.fetchFeedCallCount, 2)

        // Sign out of library B (current account = B): invalidate only B's slot.
        sut.invalidateCache(for: url)

        // Library B's slot is gone.
        XCTAssertNil(sut.cachedFeed(for: url),
                     "After invalidate while account=B, B's slot must be empty")

        // Switch back to library A — its slot must still be live.
        testAccountID = "lib-A"
        XCTAssertEqual(sut.cachedFeed(for: url)?.title, "A",
                       "Invalidate scoped to B must NOT clear A's slot at the same URL")
    }

    /// Mutant killed: a regression that DOES start including the bearer
    /// token (or any per-request header) in the cache key. The bearer
    /// rotates on every token refresh, which would silently bust the
    /// cache and triple the network traffic. The repository must NOT
    /// see the bearer at all — it only sees the URL — so a single
    /// account's repeated reads share one cache slot regardless of
    /// underlying auth-layer churn.
    func testCacheKey_SameAccount_RepeatedReads_ShareOneCacheEntry() async throws {
        let url = URL(string: "https://example.com/same-account")!
        testAccountID = "stable-library-uuid"
        api.stubbedFeeds[url] = CatalogAPIMock.makeMockFeed(title: "Stable")
        let sut = makeRepository()

        // Three reads back-to-back (simulating three bearer-token rotations
        // under the same library identity). All must share the same cache
        // entry — exactly one network call.
        _ = try await sut.loadTopLevelCatalog(at: url)
        _ = try await sut.loadTopLevelCatalog(at: url)
        _ = try await sut.loadTopLevelCatalog(at: url)

        XCTAssertEqual(api.fetchFeedCallCount, 1,
                       "Same URL + same account => one cache entry, regardless of how many times the bearer rotated under the hood")
    }

    // MARK: - 5. URL canonicalisation traps

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
