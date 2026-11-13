//
//  CatalogRepository keeps feeds the patron has read up to one limit and
//  preloaded facet feeds up to a smaller one. A preload never evicts a read
//  feed, so a long browse stops growing memory while going back to a recent
//  feed stays a memory hit (PP-5585).
//

import XCTest
@testable import PalaceCatalog
@testable import Palace

@MainActor
final class CatalogRepositoryFeedLimitTests: XCTestCase {

    private var api: CatalogAPIMock!
    private var defaults: UserDefaults!
    private let testNow = LockIsolated<Date>(Date(timeIntervalSince1970: 1_700_000_000))
    private let readLimit = CatalogRepository.readFeedLimit
    private let preloadLimit = CatalogRepository.preloadedFeedLimit

    override func setUp() {
        super.setUp()
        api = CatalogAPIMock()
        api.defaultFeed = CatalogAPIMock.makeMockFeed(title: "Feed")
        defaults = Self.testUserDefaults()
        defaults.set(testNow.value, forKey: "CatalogRepository.lastAppLaunch")
    }

    override func tearDown() {
        api = nil
        defaults = nil
        super.tearDown()
    }

    private func makeRepository() -> CatalogRepository {
        let repository = CatalogRepository(api: api, now: { [testNow] in testNow.value }, defaults: defaults)
        repository._trackRefreshTasksForTesting()
        return repository
    }

    private func url(_ index: Int) -> URL {
        URL(string: "https://example.com/feeds/\(index)")!
    }

    private func facetURL(group: Int, _ index: Int) -> URL {
        URL(string: "https://example.com/groups/\(group)/facets/\(index)")!
    }

    private func groupURL(_ group: Int) -> URL {
        URL(string: "https://example.com/groups/\(group)")!
    }

    private func load(_ repository: CatalogRepository, _ indices: Range<Int>) async throws {
        for index in indices {
            _ = try await repository.loadTopLevelCatalog(at: url(index))
        }
    }

    /// Loads a feed with five facet links and waits for its facets to be preloaded.
    private func loadGroup(_ repository: CatalogRepository, _ group: Int) async throws {
        api.stubbedFeeds[groupURL(group)] = try XCTUnwrap(
            Self.makeFeed(facets: (0..<5).map { facetURL(group: group, $0) })
        )
        _ = try await repository.loadTopLevelCatalog(at: groupURL(group))
        await repository._awaitAllBackgroundRefreshesForTesting()
    }

    private func fetchCount(_ url: URL) -> Int {
        api.fetchFeedCalls.filter { $0 == url }.count
    }

    // MARK: - Read feeds

    /// Loading one feed past the read limit drops only the least recently read feed.
    func testLoad_OneFeedPastTheReadLimit_DropsOnlyTheOldest() async throws {
        let repository = makeRepository()

        try await load(repository, 0..<(readLimit + 1))

        XCTAssertNil(repository.cachedFeed(for: url(0)))
        for index in 1...readLimit {
            XCTAssertNotNil(repository.cachedFeed(for: url(index)), "feed \(index) should stay in memory")
        }
    }

    /// Going back to a recent feed is a memory hit with no network request,
    /// even after the limit has been reached.
    func testLoad_GoingBackToARecentFeed_MakesNoNetworkRequest() async throws {
        let repository = makeRepository()
        try await load(repository, 0..<(readLimit + 5))
        let fetchesBefore = api.fetchFeedCalls.count

        _ = try await repository.loadTopLevelCatalog(at: url(readLimit + 4))
        _ = try await repository.loadTopLevelCatalog(at: url(5))

        XCTAssertEqual(api.fetchFeedCalls.count, fetchesBefore)
    }

    /// A feed dropped by the limit is fetched again when it is opened.
    func testLoad_FeedDroppedByTheLimit_IsFetchedAgain() async throws {
        let repository = makeRepository()
        try await load(repository, 0..<(readLimit + 1))

        _ = try await repository.loadTopLevelCatalog(at: url(0))

        XCTAssertEqual(fetchCount(url(0)), 2)
    }

    /// A memory hit through loadTopLevelCatalog makes that feed the most
    /// recent, so the next feed past the limit drops the next oldest instead.
    func testLoad_MemoryHit_KeepsThatFeedOverOlderOnes() async throws {
        let repository = makeRepository()
        try await load(repository, 0..<readLimit)

        _ = try await repository.loadTopLevelCatalog(at: url(0))
        _ = try await repository.loadTopLevelCatalog(at: url(readLimit))

        XCTAssertNotNil(repository.cachedFeed(for: url(0)))
        XCTAssertNil(repository.cachedFeed(for: url(1)))
    }

    /// A synchronous cachedFeed(for:) read also makes that feed the most recent.
    func testCachedFeed_Read_KeepsThatFeedOverOlderOnes() async throws {
        let repository = makeRepository()
        try await load(repository, 0..<readLimit)

        XCTAssertNotNil(repository.cachedFeed(for: url(0)))
        _ = try await repository.loadTopLevelCatalog(at: url(readLimit))

        XCTAssertNotNil(repository.cachedFeed(for: url(0)))
        XCTAssertNil(repository.cachedFeed(for: url(1)))
    }

    /// Asking for a feed that is too old to show does not make it recent, so
    /// it is still the first feed dropped.
    func testCachedFeed_TooOldEntry_IsNotMadeRecent() async throws {
        let repository = makeRepository()
        let start = testNow.value
        try await load(repository, 0..<1)
        testNow.value = start.addingTimeInterval(86_401)
        try await load(repository, 1..<readLimit)

        XCTAssertNil(repository.cachedFeed(for: url(0)))
        _ = try await repository.loadTopLevelCatalog(at: url(readLimit))

        XCTAssertNotNil(repository.cachedFeed(for: url(1)))
    }

    /// A stale feed shown while it refreshes counts as read, even when the
    /// refresh fails, so the next feed past the limit drops the next oldest.
    func testLoad_StaleButUsableFeed_IsMadeRecent() async throws {
        let repository = makeRepository()
        try await load(repository, 0..<readLimit)
        testNow.value = testNow.value.addingTimeInterval(601)
        api.fetchFeedError = URLError(.notConnectedToInternet)

        _ = try await repository.loadTopLevelCatalog(at: url(0))
        await repository._awaitAllBackgroundRefreshesForTesting()
        api.fetchFeedError = nil
        _ = try await repository.loadTopLevelCatalog(at: url(readLimit))

        XCTAssertNotNil(repository.cachedFeed(for: url(0)))
        XCTAssertNil(repository.cachedFeed(for: url(1)))
    }

    /// A too-old feed shown offline because the fetch failed keeps its place.
    func testLoad_OfflineFallbackAfterAFetchError_IsMadeRecent() async throws {
        let repository = makeRepository()
        let start = testNow.value
        try await load(repository, 0..<1)
        testNow.value = start.addingTimeInterval(86_401)
        try await load(repository, 1..<readLimit)
        api.fetchFeedError = URLError(.notConnectedToInternet)

        let shown = try await repository.loadTopLevelCatalog(at: url(0))
        api.fetchFeedError = nil
        _ = try await repository.loadTopLevelCatalog(at: url(readLimit))

        XCTAssertNotNil(shown)
        XCTAssertNil(repository.cachedFeed(for: url(1)), "url(1) is now the least recently read")
    }

    /// A too-old feed shown because the fetch returned nothing keeps its place.
    func testLoad_OfflineFallbackAfterAnEmptyFetch_IsMadeRecent() async throws {
        let repository = makeRepository()
        let start = testNow.value
        try await load(repository, 0..<1)
        testNow.value = start.addingTimeInterval(86_401)
        try await load(repository, 1..<readLimit)
        let defaultFeed = api.defaultFeed
        api.defaultFeed = nil

        let shown = try await repository.loadTopLevelCatalog(at: url(0))
        api.defaultFeed = defaultFeed
        _ = try await repository.loadTopLevelCatalog(at: url(readLimit))

        XCTAssertNotNil(shown)
        XCTAssertNil(repository.cachedFeed(for: url(1)), "url(1) is now the least recently read")
    }

    /// Refetching an expired feed replaces it in one place and makes it the
    /// most recent, so the next feed past the limit drops the next oldest.
    func testLoad_RefetchOfAnExpiredFeed_TakesOnePlaceAndBecomesMostRecent() async throws {
        let repository = makeRepository()
        try await load(repository, 0..<readLimit)
        let start = testNow.value
        testNow.value = start.addingTimeInterval(86_401)
        _ = try await repository.loadTopLevelCatalog(at: url(0))
        testNow.value = start

        _ = try await repository.loadTopLevelCatalog(at: url(readLimit))

        XCTAssertEqual(fetchCount(url(0)), 2)
        XCTAssertNotNil(repository.cachedFeed(for: url(0)))
        XCTAssertNil(repository.cachedFeed(for: url(1)))
        XCTAssertNotNil(repository.cachedFeed(for: url(2)))
    }

    // MARK: - Removal

    /// After an invalidation, later feeds past the limit still drop the oldest
    /// remaining feed, not the ones just loaded.
    func testInvalidateCache_ThenTwoFeedsPastTheLimit_DropsTheOldestRemaining() async throws {
        let repository = makeRepository()
        try await load(repository, 0..<readLimit)

        repository.invalidateCache(for: url(0))
        try await load(repository, readLimit..<(readLimit + 2))

        XCTAssertNil(repository.cachedFeed(for: url(1)))
        for index in 2..<(readLimit + 2) {
            XCTAssertNotNil(repository.cachedFeed(for: url(index)), "feed \(index) should stay in memory")
        }
    }

    /// After a memory warning clears the feeds, a full set of new feeds fits again.
    func testReleaseInMemoryCaches_ThenLoadingToTheLimit_KeepsEveryFeed() async throws {
        let repository = makeRepository()
        try await load(repository, 0..<readLimit)

        repository.releaseInMemoryCaches()
        try await load(repository, 1_000..<(1_000 + readLimit))

        XCTAssertNil(repository.cachedFeed(for: url(0)))
        for index in 1_000..<(1_000 + readLimit) {
            XCTAssertNotNil(repository.cachedFeed(for: url(index)), "feed \(index) should stay in memory")
        }
    }

    // MARK: - Preloaded facets

    /// Preloading facets of a feed never drops a feed the patron has read.
    func testPreload_AtTheReadLimit_DropsNoReadFeed() async throws {
        let repository = makeRepository()
        try await load(repository, 0..<(readLimit - 1))

        try await loadGroup(repository, 0)

        for index in 0..<(readLimit - 1) {
            XCTAssertNotNil(repository.cachedFeed(for: url(index)), "read feed \(index) should stay in memory")
        }
        XCTAssertNotNil(repository.cachedFeed(for: groupURL(0)))
        let fetches = api.fetchFeedCalls.count
        _ = try await repository.loadTopLevelCatalog(at: facetURL(group: 0, 0))
        XCTAssertEqual(api.fetchFeedCalls.count, fetches, "a preloaded facet opens from memory")
    }

    /// Past the preload limit, the oldest preloads are dropped and every read
    /// feed stays.
    func testPreload_PastThePreloadLimit_DropsTheOldestPreloadsOnly() async throws {
        let repository = makeRepository()
        let groups = preloadLimit / 5 + 1

        for group in 0..<groups {
            try await loadGroup(repository, group)
        }

        for group in 0..<groups {
            XCTAssertNotNil(repository.cachedFeed(for: groupURL(group)), "group \(group) was read")
        }
        let before = fetchCount(facetURL(group: 0, 0))
        _ = try await repository.loadTopLevelCatalog(at: facetURL(group: 0, 0))
        XCTAssertEqual(fetchCount(facetURL(group: 0, 0)), before + 1, "the oldest preload was dropped")
        let lastBefore = fetchCount(facetURL(group: groups - 1, 4))
        _ = try await repository.loadTopLevelCatalog(at: facetURL(group: groups - 1, 4))
        XCTAssertEqual(fetchCount(facetURL(group: groups - 1, 4)), lastBefore, "the newest preload stays")
    }

    /// A preloaded facet the patron opens counts as read, so later preloads
    /// cannot drop it.
    func testPreload_FacetThePatronOpened_SurvivesLaterPreloads() async throws {
        let repository = makeRepository()
        let groups = preloadLimit / 5
        for group in 0..<groups {
            try await loadGroup(repository, group)
        }

        XCTAssertNotNil(repository.cachedFeed(for: facetURL(group: 0, 0)))
        try await loadGroup(repository, groups)

        let opened = fetchCount(facetURL(group: 0, 0))
        _ = try await repository.loadTopLevelCatalog(at: facetURL(group: 0, 0))
        XCTAssertEqual(fetchCount(facetURL(group: 0, 0)), opened, "the opened facet stays in memory")
        let unopened = fetchCount(facetURL(group: 0, 1))
        _ = try await repository.loadTopLevelCatalog(at: facetURL(group: 0, 1))
        XCTAssertEqual(fetchCount(facetURL(group: 0, 1)), unopened + 1, "an unopened old preload was dropped")
    }

    // MARK: - Format entries

    /// Loading a feed with format entry points fills the format-entries cache,
    /// so opening search needs no extra request.
    func testLoadTopLevelCatalog_FeedWithEntryPoints_PrewarmsFormatEntries() async throws {
        let repository = makeRepository()
        let groups = url(5_000)
        api.stubbedFeeds[groups] = try XCTUnwrap(Self.makeFeedWithEntryPoints())

        _ = try await repository.loadTopLevelCatalog(at: groups)
        let entries = try await repository.fetchSearchEntryPoints(from: groups)

        XCTAssertEqual(entries.map(\.title), ["eBooks", "Audiobooks"])
        XCTAssertTrue(api.fetchSearchEntryPointsCalls.isEmpty)
    }

    /// The format-entries cache drops the least recently read list first, and a
    /// cached read makes a list the most recent.
    func testFetchSearchEntryPoints_PastTheLimit_DropsTheLeastRecentlyRead() async throws {
        let repository = makeRepository()
        api.stubbedSearchEntryPoints = [
            SearchFormatEntry(id: "Book", title: "eBooks", groupsFeedURL: url(9_999), searchDescriptorURL: nil, isActive: true)
        ]
        for index in 0..<readLimit {
            _ = try await repository.fetchSearchEntryPoints(from: url(index))
        }

        _ = try await repository.fetchSearchEntryPoints(from: url(0))
        _ = try await repository.fetchSearchEntryPoints(from: url(readLimit))
        _ = try await repository.fetchSearchEntryPoints(from: url(1))
        _ = try await repository.fetchSearchEntryPoints(from: url(0))

        XCTAssertEqual(api.fetchSearchEntryPointsCalls.filter { $0 == url(0) }.count, 1)
        XCTAssertEqual(api.fetchSearchEntryPointsCalls.filter { $0 == url(1) }.count, 2)
    }

    // MARK: - Fixtures

    private static func makeFeed(facets: [URL]) -> CatalogFeed? {
        let links = facets.enumerated().map { index, url in
            #"<link href="\#(url.absoluteString)" rel="http://opds-spec.org/facet" title="Facet \#(index)" opds:facetGroup="Sort"/>"#
        }.joined(separator: "\n")
        return makeCatalogFeed(xml: """
        <?xml version="1.0" encoding="utf-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom" xmlns:opds="http://opds-spec.org/2010/catalog">
            <id>urn:uuid:group</id>
            <title>Group</title>
            <updated>2024-01-15T12:00:00Z</updated>
            \(links)
        </feed>
        """)
    }

    private static func makeFeedWithEntryPoints() -> CatalogFeed? {
        makeCatalogFeed(xml: """
        <?xml version="1.0" encoding="utf-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom"
              xmlns:opds="http://opds-spec.org/2010/catalog"
              xmlns:simplified="http://librarysimplified.org/terms/">
            <id>http://example.org/groups/</id>
            <title>Groups Feed</title>
            <updated>2024-01-15T12:00:00Z</updated>
            <link href="http://example.org/groups/?entrypoint=Book"
                  rel="http://opds-spec.org/facet" title="eBooks" opds:facetGroup="Formats"
                  simplified:facetGroupType="http://librarysimplified.org/terms/rel/entrypoint"/>
            <link href="http://example.org/groups/?entrypoint=Audio"
                  rel="http://opds-spec.org/facet" title="Audiobooks" opds:facetGroup="Formats"
                  simplified:facetGroupType="http://librarysimplified.org/terms/rel/entrypoint"/>
        </feed>
        """)
    }

    private static func makeCatalogFeed(xml: String) -> CatalogFeed? {
        guard let data = xml.data(using: .utf8),
              let tppXML = TPPXML(data: data),
              let opdsFeed = TPPOPDSFeed(xml: tppXML) else { return nil }
        return CatalogFeed(feed: opdsFeed)
    }
}

/// The two-tier map behind the repository's feed and format-entry caches.
final class RecentEntriesTests: XCTestCase {

    private func makeEntries(readLimit: Int = 2, preloadLimit: Int = 2) -> RecentEntries<Int> {
        RecentEntries(readLimit: readLimit, preloadLimit: preloadLimit)
    }

    /// `contains` is a check, not a read: it does not save an entry from eviction.
    func testContains_DoesNotMakeAnEntryRecent() {
        var entries = makeEntries()
        entries.set(1, for: "a")
        entries.set(2, for: "b")

        XCTAssertTrue(entries.contains("a"))
        entries.set(3, for: "c")

        XCTAssertNil(entries.peek("a"))
        XCTAssertEqual(entries.peek("b"), 2)
    }

    /// `peek` does not make an entry recent either.
    func testPeek_DoesNotMakeAnEntryRecent() {
        var entries = makeEntries()
        entries.set(1, for: "a")
        entries.set(2, for: "b")

        XCTAssertEqual(entries.peek("a"), 1)
        entries.set(3, for: "c")

        XCTAssertNil(entries.peek("a"))
    }

    /// `value(for:)` is a read and makes the entry the most recent.
    func testValueFor_MakesTheEntryMostRecent() {
        var entries = makeEntries()
        entries.set(1, for: "a")
        entries.set(2, for: "b")

        XCTAssertEqual(entries.value(for: "a"), 1)
        entries.set(3, for: "c")

        XCTAssertEqual(entries.peek("a"), 1)
        XCTAssertNil(entries.peek("b"))
    }

    /// Preloads fill their own tier and never drop a read entry.
    func testSetPreloaded_PastThePreloadLimit_DropsTheOldestPreloadOnly() {
        var entries = makeEntries(readLimit: 2, preloadLimit: 1)
        entries.set(1, for: "a")
        entries.set(2, for: "b")

        entries.setPreloaded(10, for: "p")
        entries.setPreloaded(11, for: "q")

        XCTAssertEqual(entries.peek("a"), 1)
        XCTAssertEqual(entries.peek("b"), 2)
        XCTAssertNil(entries.peek("p"))
        XCTAssertEqual(entries.peek("q"), 11)
        XCTAssertEqual(entries.count, 3)
    }

    /// A preload never replaces or demotes an entry that is already there.
    func testSetPreloaded_ExistingReadEntry_KeepsItAndItsValue() {
        var entries = makeEntries(readLimit: 2, preloadLimit: 1)
        entries.set(1, for: "a")

        entries.setPreloaded(99, for: "a")
        entries.setPreloaded(10, for: "p")

        XCTAssertEqual(entries.peek("a"), 1)
        XCTAssertEqual(entries.peek("p"), 10)
    }

    /// Reading a preload moves it to the read tier, where later preloads cannot reach it.
    func testValueFor_Preload_MovesItToTheReadTier() {
        var entries = makeEntries(readLimit: 2, preloadLimit: 1)
        entries.setPreloaded(10, for: "p")

        XCTAssertEqual(entries.value(for: "p"), 10)
        entries.setPreloaded(11, for: "q")

        XCTAssertEqual(entries.peek("p"), 10)
        XCTAssertEqual(entries.peek("q"), 11)
    }

    /// After removeAll, a full set of new entries fits and none is dropped.
    func testRemoveAll_ThenFillingBothTiers_KeepsEveryNewEntry() {
        var entries = makeEntries()
        entries.set(1, for: "a")
        entries.set(2, for: "b")
        entries.setPreloaded(10, for: "p")

        entries.removeAll()
        entries.set(3, for: "c")
        entries.set(4, for: "d")
        entries.setPreloaded(11, for: "q")
        entries.setPreloaded(12, for: "r")

        XCTAssertEqual(entries.count, 4)
        XCTAssertNil(entries.peek("a"))
        XCTAssertEqual(entries.peek("c"), 3)
        XCTAssertEqual(entries.peek("r"), 12)
    }

    /// A removed preload leaves nothing behind, so preloading it again keeps it.
    func testRemove_ThenPreloadingTheSameKeyAgain_KeepsIt() {
        var entries = makeEntries(readLimit: 2, preloadLimit: 1)
        entries.setPreloaded(10, for: "p")

        entries.remove("p")
        entries.setPreloaded(11, for: "p")

        XCTAssertEqual(entries.peek("p"), 11)
        XCTAssertEqual(entries.count, 1)
    }

    /// A removed read entry leaves nothing behind, so setting it again keeps it.
    func testRemove_ThenSettingTheSameKeyAgain_KeepsIt() {
        var entries = makeEntries(readLimit: 1, preloadLimit: 1)
        entries.set(1, for: "a")

        entries.remove("a")
        entries.set(2, for: "a")

        XCTAssertEqual(entries.peek("a"), 2)
    }
}
