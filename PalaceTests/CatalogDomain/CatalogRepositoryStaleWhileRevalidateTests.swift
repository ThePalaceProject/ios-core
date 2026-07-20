//
//  CatalogRepositoryStaleWhileRevalidateTests.swift
//  PalaceTests
//
//  Deep, mutation-killing tests for CatalogRepository's stale-while-revalidate
//  pattern and `cachedFeed(for:)` freshness windows. Time is driven via an
//  injected `now: @escaping () -> Date` clock seam — never via Task.sleep.
//
//  Coverage targets (each test pins one behavior; comments name the
//  mutant each kills):
//   • Fresh cache (< 10 min) → returns cached data, no network.
//   • Boundary at 10 min: 600s old is fresh, 601s is stale.
//   • Stale-but-usable (10 min - 24 hr) → returns cache AND triggers
//     a background refresh that updates the cache.
//   • Boundary at 24 hr: 86400s is still stale-but-usable, 86401s is too old.
//   • Too old (> 24 hr) → hits network, cache replaced with network result.
//   • Network failure with cached fallback → returns cached feed.
//   • Network failure with NO cache → throws.
//   • `cachedFeed(for:)` 24h boundary: <=86400 returns feed, >86400 returns nil.
//   • Concurrent stale reads → both get cache, refresh observed in cache.
//   • Explicit invalidate → next read fetches from network.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceCatalog
@testable import Palace

@MainActor
final class CatalogRepositoryStaleWhileRevalidateTests: XCTestCase {

    // MARK: - Fixtures

    private var api: CatalogAPIMock!
    private var defaults: UserDefaults!
    private let testURL = URL(string: "https://library.example.com/catalog")!
    private let secondURL = URL(string: "https://library.example.com/catalog/other")!

    /// Mutable test clock. Setting this updates the time returned by the
    /// closure passed to CatalogRepository at construction. Tests advance
    /// this directly rather than sleeping.
    private let testNow = LockIsolated<Date>(Date(timeIntervalSince1970: 1_700_000_000))

    /// UserDefaults key the repository uses for its last-launch heuristic.
    /// We clear it in setUp so `needsBackgroundRefresh` starts off `false`
    /// (no cross-test contamination from a previous run's persisted launch
    /// timestamp on the simulator).
    private static let lastAppLaunchKey = "CatalogRepository.lastAppLaunch"

    // MARK: - Setup / Teardown

    override func setUp() {
        super.setUp()
        // swarm_cd181acd D-cleanup: per-test isolated UserDefaults suite
        // for the `lastAppLaunchKey` heuristic — no `.standard` writes.
        // Each test starts with a fresh empty suite (lastLaunch defaults
        // to .distantPast inside checkStaleCacheStatus, which gives
        // `needsBackgroundRefresh = true`). Tests that need
        // `needsBackgroundRefresh = false` seed the key BEFORE
        // constructing the repository via `makeRepository`.
        defaults = Self.testUserDefaults()
        api = CatalogAPIMock()
    }

    override func tearDown() {
        api = nil
        defaults = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// Build a repository whose clock is bound to `self.testNow`. Closure
    /// captures `self` weakly to honor whatever value `testNow` holds at
    /// the moment the repository asks for the current time.
    private func makeRepository(seedLastLaunchToNow: Bool = true) -> CatalogRepository {
        // Seed lastAppLaunch to "now" so checkStaleCacheStatus() sees
        // daysSinceLastLaunch == 0 and leaves `needsBackgroundRefresh = false`.
        // Without this, distantPast → huge day count → needsBackgroundRefresh=true,
        // which forces the stale-while-revalidate branch for fresh caches and
        // ruins the fresh-cache assertions below.
        if seedLastLaunchToNow {
            defaults.set(testNow.value, forKey: Self.lastAppLaunchKey)
        }
        return CatalogRepository(
            api: api,
            now: { [testNow] in testNow.value },
            defaults: defaults
        )
    }

    /// Poll an async predicate until it holds or the timeout elapses. Used
    /// to await the completion of `Task.detached` background refreshes
    /// without sleeping for a flat duration. NOT used to age out cache —
    /// the clock seam handles that.
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

    // MARK: - Fresh cache window (< 10 min)

    /// Mutant killed: removing the `!isExpired(entry)` early return — would
    /// re-fetch and bump call count to 2 on the second load.
    func testLoadTopLevelCatalog_FreshCacheWithinTenMinutes_ReturnsCacheAndSkipsNetwork() async throws {
        api.stubbedFeeds[testURL] = CatalogAPIMock.makeMockFeed(title: "Fresh")
        let sut = makeRepository()

        _ = try await sut.loadTopLevelCatalog(at: testURL)
        // Advance well inside the fresh window — 5 minutes in (300s < 600s).
        testNow.value = testNow.value.addingTimeInterval(300)
        // Swap the stub: if the cache hit is broken the second call will return "Other".
        api.stubbedFeeds[testURL] = CatalogAPIMock.makeMockFeed(title: "Other")
        let second = try await sut.loadTopLevelCatalog(at: testURL)

        XCTAssertEqual(second?.title, "Fresh", "Fresh cache must return cached title, not network swap")
        XCTAssertEqual(api.fetchFeedCallCount, 1, "Fresh cache must NOT touch the network")
    }

    /// Mutant killed: flipping `> 600` to `>= 600` in `isExpired` — that
    /// flip would treat 600s-old as expired and re-fetch.
    func testLoadTopLevelCatalog_AtExactlyTenMinuteBoundary_StillCountsAsFresh() async throws {
        api.stubbedFeeds[testURL] = CatalogAPIMock.makeMockFeed(title: "AtBoundary")
        let sut = makeRepository()

        _ = try await sut.loadTopLevelCatalog(at: testURL)
        // Exactly 600s later: code uses `> 600`, so 600 is NOT expired.
        testNow.value = testNow.value.addingTimeInterval(600)
        api.stubbedFeeds[testURL] = CatalogAPIMock.makeMockFeed(title: "OverwrittenButShouldNotShow")
        let second = try await sut.loadTopLevelCatalog(at: testURL)

        XCTAssertEqual(second?.title, "AtBoundary", "600s-old cache must still be fresh")
        XCTAssertEqual(api.fetchFeedCallCount, 1)
    }

    // MARK: - Stale-but-usable window (10 min - 24 hr)

    /// Mutant killed: flipping `> 600` to `>= 600` — at 601s the entry must
    /// now be stale (not fresh), which forces the stale-while-revalidate
    /// branch and a background refresh. If `>= 600` were used, at 601 the
    /// behavior would be the same — but combined with the 600-boundary test
    /// above (which DOES require 600 to be fresh), the pair pins the operator.
    func testLoadTopLevelCatalog_JustPastTenMinutes_ReturnsStaleAndSchedulesBackgroundRefresh() async throws {
        api.stubbedFeeds[testURL] = CatalogAPIMock.makeMockFeed(title: "Stale-original")
        let sut = makeRepository()
        _ = try await sut.loadTopLevelCatalog(at: testURL)
        XCTAssertEqual(api.fetchFeedCallCount, 1)

        // 601s later → just past the fresh boundary, well inside stale-but-usable.
        testNow.value = testNow.value.addingTimeInterval(601)
        api.stubbedFeeds[testURL] = CatalogAPIMock.makeMockFeed(title: "Refreshed")
        let second = try await sut.loadTopLevelCatalog(at: testURL)

        // Stale read returns the cached value IMMEDIATELY.
        XCTAssertEqual(second?.title, "Stale-original",
                       "Stale-but-usable must return cached value immediately")

        // And a background refresh must fire AND complete the cache write.
        // Poll the cache directly (not call count): the network bumps the
        // count slightly before the cache write lands.
        await awaitCondition {
            sut.cachedFeed(for: self.testURL)?.title == "Refreshed"
        }
        XCTAssertEqual(api.fetchFeedCallCount, 2, "Stale-but-usable must trigger ONE background refresh")

        // Subsequent read inside fresh window of the refreshed cache returns new title.
        // Cache was rewritten at testNow (601s post-original), so 5 minutes later
        // the new entry is fresh.
        testNow.value = testNow.value.addingTimeInterval(300)
        let third = try await sut.loadTopLevelCatalog(at: testURL)
        XCTAssertEqual(third?.title, "Refreshed",
                       "Background refresh must replace the cache with network result")
        XCTAssertEqual(api.fetchFeedCallCount, 2, "Third read of fresh post-refresh cache must NOT hit network")
    }

    /// Mutant killed: flipping `<= 86400` to `< 86400` in `isStaleButUsable`
    /// — that flip would treat exactly-24h as "too old" and skip the cache
    /// fallback path on this exact boundary, hitting the network instead.
    func testLoadTopLevelCatalog_AtExactly24HourBoundary_StillStaleButUsableNotTooOld() async throws {
        api.stubbedFeeds[testURL] = CatalogAPIMock.makeMockFeed(title: "Day-old-original")
        let sut = makeRepository()
        _ = try await sut.loadTopLevelCatalog(at: testURL)

        // Exactly 86400s (24h) later — `isStaleButUsable` uses `<= 86400`.
        testNow.value = testNow.value.addingTimeInterval(86400)
        api.stubbedFeeds[testURL] = CatalogAPIMock.makeMockFeed(title: "WouldBeNetwork")
        let result = try await sut.loadTopLevelCatalog(at: testURL)

        XCTAssertEqual(result?.title, "Day-old-original",
                       "At exactly 24h, cache is still stale-but-usable (returns immediately)")

        // Background refresh still fires from the stale-but-usable branch.
        // Poll the cache for the refreshed title (more reliable than call count).
        await awaitCondition {
            sut.cachedFeed(for: self.testURL)?.title == "WouldBeNetwork"
        }
    }

    // MARK: - Too-old / expired-beyond-24h

    /// Mutant killed: flipping `> 86400` to `>= 86400` in `isTooOld` would
    /// treat 86401s as identical to 86400s, but combined with the previous
    /// boundary test this would mis-classify. More directly: a mutant that
    /// removes the network-fetch branch entirely would return cached
    /// "Original" instead of "FromNetwork".
    func testLoadTopLevelCatalog_PastTwentyFourHours_FetchesFromNetworkAndReplacesCache() async throws {
        api.stubbedFeeds[testURL] = CatalogAPIMock.makeMockFeed(title: "Original")
        let sut = makeRepository()
        _ = try await sut.loadTopLevelCatalog(at: testURL)
        XCTAssertEqual(api.fetchFeedCallCount, 1)

        // 86401s later — one second past 24h → isTooOld returns true.
        testNow.value = testNow.value.addingTimeInterval(86401)
        api.stubbedFeeds[testURL] = CatalogAPIMock.makeMockFeed(title: "FromNetwork")
        let result = try await sut.loadTopLevelCatalog(at: testURL)

        XCTAssertEqual(result?.title, "FromNetwork",
                       "Too-old cache must NOT be returned; network result must.")
        XCTAssertEqual(api.fetchFeedCallCount, 2, "Too-old path must hit network synchronously")

        // Next read at the same clock returns fresh refreshed cache, no new fetch.
        let second = try await sut.loadTopLevelCatalog(at: testURL)
        XCTAssertEqual(second?.title, "FromNetwork")
        XCTAssertEqual(api.fetchFeedCallCount, 2, "Refreshed cache must be fresh after network replace")
    }

    // MARK: - Network failure paths

    /// Mutant killed: removing the `if let entry = cachedEntry { return
    /// entry.feed }` fallback inside the network-failure catch block.
    /// That removal would propagate the error instead of returning stale.
    func testLoadTopLevelCatalog_NetworkFailureWithTooOldCache_ReturnsCachedFallback() async throws {
        api.stubbedFeeds[testURL] = CatalogAPIMock.makeMockFeed(title: "Stale-fallback")
        let sut = makeRepository()
        _ = try await sut.loadTopLevelCatalog(at: testURL)

        // Age past 24h so the next call attempts a network fetch (not stale-but-usable
        // which would skip the failing fetch).
        testNow.value = testNow.value.addingTimeInterval(90_000)
        // Network errors out — must fall back to the cached entry.
        api.fetchFeedError = NSError(domain: "Test", code: -1, userInfo: nil)

        let result = try await sut.loadTopLevelCatalog(at: testURL)
        XCTAssertEqual(result?.title, "Stale-fallback",
                       "Network failure with ANY cached entry must return that cached entry")
    }

    /// Mutant killed: collapsing the network-failure branch to silently
    /// return nil instead of throwing. Or removing the throw of the wrapped
    /// NSError.
    func testLoadTopLevelCatalog_NetworkFailureWithNoCache_Throws() async {
        let sut = makeRepository()
        api.fetchFeedError = NSError(domain: "Test", code: -1, userInfo: nil)

        do {
            _ = try await sut.loadTopLevelCatalog(at: testURL)
            XCTFail("Expected throw when network fails and no cache exists")
        } catch {
            // Error must propagate — repository wraps as NSError(domain:
            // "CatalogRepository", ...). We don't pin the exact domain
            // because the wrap is implementation detail; throwing at all is
            // the contract.
            XCTAssertEqual(api.fetchFeedCallCount, 1, "Exactly one network attempt before failing")
        }
    }

    // MARK: - cachedFeed(for:) boundaries

    /// Mutant killed: flipping `!isTooOld(entry)` to `isTooOld(entry)` (or
    /// removing the guard) — would return a too-old feed instead of nil.
    func testCachedFeed_AtExactly24h_ReturnsFeed_PastBoundary_ReturnsNil() async throws {
        api.stubbedFeeds[testURL] = CatalogAPIMock.makeMockFeed(title: "WithinBoundary")
        let sut = makeRepository()
        _ = try await sut.loadTopLevelCatalog(at: testURL)

        // At exactly 24h, isTooOld is false (uses `> 86400`).
        testNow.value = testNow.value.addingTimeInterval(86400)
        XCTAssertEqual(sut.cachedFeed(for: testURL)?.title, "WithinBoundary",
                       "At 86400s-old cache must still be returned by cachedFeed")

        // 1 second over → too old → nil.
        testNow.value = testNow.value.addingTimeInterval(1)
        XCTAssertNil(sut.cachedFeed(for: testURL),
                     "At 86401s-old cache must be treated as too old and nil-returned")
    }

    /// Mutant killed: cachedFeed returning the wrong URL's entry (e.g.
    /// always returning the first cached). Pins keying by URL.
    func testCachedFeed_PerURLIsolation_DoesNotLeakBetweenURLs() async throws {
        api.stubbedFeeds[testURL] = CatalogAPIMock.makeMockFeed(title: "First")
        api.stubbedFeeds[secondURL] = CatalogAPIMock.makeMockFeed(title: "Second")
        let sut = makeRepository()
        _ = try await sut.loadTopLevelCatalog(at: testURL)
        _ = try await sut.loadTopLevelCatalog(at: secondURL)

        XCTAssertEqual(sut.cachedFeed(for: testURL)?.title, "First")
        XCTAssertEqual(sut.cachedFeed(for: secondURL)?.title, "Second")

        let unrelated = URL(string: "https://example.com/never-loaded")!
        XCTAssertNil(sut.cachedFeed(for: unrelated),
                     "URLs never loaded must return nil — no cross-contamination")
    }

    // MARK: - Cache invalidation

    /// Mutant killed: making `invalidateCache` a no-op — the next read
    /// would still be served by the fresh cache and skip the network.
    func testInvalidateCache_ExplicitInvalidate_ForcesNextReadToNetwork() async throws {
        api.stubbedFeeds[testURL] = CatalogAPIMock.makeMockFeed(title: "Original")
        let sut = makeRepository()
        _ = try await sut.loadTopLevelCatalog(at: testURL)
        XCTAssertEqual(api.fetchFeedCallCount, 1)

        // Sanity check: still inside fresh window — without invalidation,
        // the next read MUST be served from cache (call count stays 1).
        // We invalidate and then expect the next read to bump to 2.
        sut.invalidateCache(for: testURL)
        api.stubbedFeeds[testURL] = CatalogAPIMock.makeMockFeed(title: "Refetched")
        let second = try await sut.loadTopLevelCatalog(at: testURL)

        XCTAssertEqual(second?.title, "Refetched",
                       "After invalidate, next read must return fresh network result, not cache")
        XCTAssertEqual(api.fetchFeedCallCount, 2,
                       "Invalidate must force a fresh network call on next read")
    }

    /// Mutant killed: `invalidateCache` clearing ALL entries instead of just
    /// the requested URL. Pins per-URL invalidation.
    func testInvalidateCache_OnlyClearsRequestedURL_DoesNotClearOthers() async throws {
        api.stubbedFeeds[testURL] = CatalogAPIMock.makeMockFeed(title: "A")
        api.stubbedFeeds[secondURL] = CatalogAPIMock.makeMockFeed(title: "B")
        let sut = makeRepository()
        _ = try await sut.loadTopLevelCatalog(at: testURL)
        _ = try await sut.loadTopLevelCatalog(at: secondURL)
        XCTAssertEqual(api.fetchFeedCallCount, 2)

        // Invalidate ONLY testURL.
        sut.invalidateCache(for: testURL)

        // testURL re-fetches; secondURL stays cached.
        _ = try await sut.loadTopLevelCatalog(at: testURL)
        _ = try await sut.loadTopLevelCatalog(at: secondURL)
        XCTAssertEqual(api.fetchFeedCallCount, 3,
                       "Invalidating one URL must NOT clear another URL's cache")
    }

    // MARK: - Concurrent stale reads

    /// Mutant killed: making the background-refresh branch a no-op (no
    /// Task.detached fired) — the cache would stay stale forever and
    /// no fresh value would ever land. Also kills mutants that drop the
    /// detached refresh inside the `cachedEntry, isStaleButUsable || ...`
    /// branch.
    ///
    /// Note: the repository itself does not dedupe concurrent
    /// background refreshes — that is `DefaultCatalogAPI`'s job
    /// (see `CatalogAPIDedupeTests`). This test pins the weaker but
    /// real contract: both concurrent readers see cached data
    /// immediately AND the cache eventually contains the refreshed feed.
    func testLoadTopLevelCatalog_ConcurrentStaleReads_BothSeeCachedAndCacheGetsRefreshed() async throws {
        api.stubbedFeeds[testURL] = CatalogAPIMock.makeMockFeed(title: "Original-concurrent")
        let sut = makeRepository()
        _ = try await sut.loadTopLevelCatalog(at: testURL)
        XCTAssertEqual(api.fetchFeedCallCount, 1)

        // Move into stale-but-usable window.
        testNow.value = testNow.value.addingTimeInterval(1800) // 30 minutes
        api.stubbedFeeds[testURL] = CatalogAPIMock.makeMockFeed(title: "Refreshed-concurrent")

        // Sendable local so the async-let children capture it instead of reading
        // @MainActor `self.testURL` (which would send self). `sut` is already local.
        let testURL = testURL
        async let a = sut.loadTopLevelCatalog(at: testURL)
        async let b = sut.loadTopLevelCatalog(at: testURL)
        let (resultA, resultB) = try await (a, b)

        XCTAssertEqual(resultA?.title, "Original-concurrent",
                       "Concurrent stale read A must return cached value")
        XCTAssertEqual(resultB?.title, "Original-concurrent",
                       "Concurrent stale read B must return cached value")

        // First await the network signal (deterministic on the mock side):
        // both detached refreshes hit fetchFeed → callCount goes 1 → 2 or 3.
        // This decouples the "did the refresh fire" assertion (load-bearing
        // for the mutation kill) from the cache-write timing.
        await awaitCondition(timeout: 5.0) {
            self.api.fetchFeedCallCount >= 2
        }

        // Then wait for the cache write to land. The happy path completes in
        // <0.3s; 5s is plenty of head-room and still fails loudly if the
        // refresh is broken instead of hanging the suite.
        await awaitCondition(timeout: 5.0) {
            sut.cachedFeed(for: self.testURL)?.title == "Refreshed-concurrent"
        }

        // Assertion is implicit in awaitCondition (it XCTFails on timeout),
        // but make the success criterion explicit for readability.
        XCTAssertEqual(sut.cachedFeed(for: testURL)?.title, "Refreshed-concurrent",
                       "Background refresh must replace the cache with the new feed")
    }
}

// MARK: - CatalogCacheMetadata exact-boundary tests
//
// CatalogCacheMetadata (defined in Palace/Accounts/Library/AccountsManager.swift)
// has its own boundary tests in PalaceTests/Accounts/CatalogCacheMetadataTests.swift.
// The cases below close gaps the existing suite leaves open: specifically
// the `<` vs `<=` operator pin at the exact-second freshness boundary,
// using two ticks one nanosecond apart so the assertion is unambiguous about
// the operator's exclusivity.

@MainActor
final class CatalogCacheMetadataExactBoundaryTests: XCTestCase {

    /// Mutant killed: flipping `> defaultStaleTTL` (21600) to `>=
    /// defaultStaleTTL` in `isStale(serverMaxAge:)`. At exactly 21600s
    /// the existing default-TTL value must be FRESH (operator is `>`).
    /// Uses the injected-`now` overload so the boundary is exact, not
    /// drifted by microseconds between `Date()` calls.
    func testIsStale_AtExactlyDefaultStaleTTL_IsFresh() {
        let now = Date()
        let metadata = CatalogCacheMetadata(
            timestamp: now.addingTimeInterval(-21600), // exactly 6 hours old
            hash: "boundary"
        )
        XCTAssertFalse(metadata.isStale(serverMaxAge: nil, now: now),
                       "Exactly 21600s-old cache must NOT be stale (operator is `>` not `>=`)")
    }

    /// Mutant killed: flipping `> maxAge` (86400) to `>= maxAge` in
    /// `isExpired`. At exactly 86400s the cache must NOT be expired.
    /// Uses the injected-`now` overload so the boundary is exact, not
    /// drifted by microseconds between `Date()` calls.
    func testIsExpired_AtExactlyMaxAge_IsNotExpired() {
        let now = Date()
        let metadata = CatalogCacheMetadata(
            timestamp: now.addingTimeInterval(-86400), // exactly 24 hours old
            hash: "boundary"
        )
        XCTAssertFalse(metadata.isExpired(now: now),
                       "Exactly 86400s-old cache must NOT be expired (operator is `>` not `>=`)")
    }

    /// Mutant killed: flipping the `min(max(half, 300), 43200)` clamp to a
    /// simple `max(half, 300)` without the upper bound — would let a
    /// pathological server max-age leak through above the 12h ceiling.
    func testStaleTTL_ExtremelyLargeServerMaxAge_IsClampedToCeiling() {
        // 1 year of seconds — half is 6 months; clamp must cap at 12h.
        let oneYear: TimeInterval = 365 * 24 * 3600
        XCTAssertEqual(CatalogCacheMetadata.staleTTL(serverMaxAge: oneYear), 43200,
                       "staleTTL must clamp absurdly large server hints to 12h ceiling")
    }

    /// Mutant killed: flipping the floor logic from `max(half, 300)` to
    /// `half` alone — would allow a sub-5-minute stale TTL through.
    func testStaleTTL_ServerMaxAgeJustBelowFloor_IsClampedToFiveMinutes() {
        // Half of 300 = 150 < 300 floor → must clamp up to 300.
        XCTAssertEqual(CatalogCacheMetadata.staleTTL(serverMaxAge: 300), 300,
                       "staleTTL must floor sub-5-minute halves to 300s")
    }
}
