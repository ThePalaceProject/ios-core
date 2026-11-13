//
//  CatalogRepository keeps a fixed number of recent feeds in memory and drops
//  the least recently used first, so a long browse stops growing memory while
//  going back to a recent feed stays a memory hit (PP-5585).
//

import XCTest
import PalaceCatalog
@testable import Palace

@MainActor
final class CatalogRepositoryFeedLimitTests: XCTestCase {

    private var api: CatalogAPIMock!
    private var defaults: UserDefaults!
    private let testNow = LockIsolated<Date>(Date(timeIntervalSince1970: 1_700_000_000))
    private let limit = CatalogRepository.memoryFeedLimit

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
        CatalogRepository(api: api, now: { [testNow] in testNow.value }, defaults: defaults)
    }

    private func url(_ index: Int) -> URL {
        URL(string: "https://example.com/feeds/\(index)")!
    }

    private func load(_ repository: CatalogRepository, _ indices: Range<Int>) async throws {
        for index in indices {
            _ = try await repository.loadTopLevelCatalog(at: url(index))
        }
    }

    // MARK: - Feed limit

    /// The limit is a small fixed count that still holds several recent loads
    /// with their preloaded facets.
    func testMemoryFeedLimit_IsForty() {
        XCTAssertEqual(limit, 40)
    }

    /// Loading one feed past the limit drops only the oldest feed.
    func testLoad_OneFeedPastTheLimit_DropsOnlyTheOldest() async throws {
        let repository = makeRepository()

        try await load(repository, 0..<(limit + 1))

        XCTAssertNil(repository.cachedFeed(for: url(0)))
        for index in 1...limit {
            XCTAssertNotNil(repository.cachedFeed(for: url(index)), "feed \(index) should stay in memory")
        }
    }

    /// Going back to a recent feed is a memory hit with no network request,
    /// even after the limit has been reached.
    func testLoad_GoingBackToARecentFeed_MakesNoNetworkRequest() async throws {
        let repository = makeRepository()
        try await load(repository, 0..<(limit + 5))
        let fetchesBefore = api.fetchFeedCalls.count

        _ = try await repository.loadTopLevelCatalog(at: url(limit + 4))
        _ = try await repository.loadTopLevelCatalog(at: url(5))

        XCTAssertEqual(api.fetchFeedCalls.count, fetchesBefore)
    }

    /// A feed dropped by the limit is fetched again when it is opened.
    func testLoad_FeedDroppedByTheLimit_IsFetchedAgain() async throws {
        let repository = makeRepository()
        try await load(repository, 0..<(limit + 1))

        _ = try await repository.loadTopLevelCatalog(at: url(0))

        XCTAssertEqual(api.fetchFeedCalls.filter { $0 == url(0) }.count, 2)
    }

    // MARK: - Recency

    /// A memory hit through loadTopLevelCatalog makes that feed the most
    /// recent, so the next feed past the limit drops the next oldest instead.
    func testLoad_MemoryHit_KeepsThatFeedOverOlderOnes() async throws {
        let repository = makeRepository()
        try await load(repository, 0..<limit)

        _ = try await repository.loadTopLevelCatalog(at: url(0))
        _ = try await repository.loadTopLevelCatalog(at: url(limit))

        XCTAssertNotNil(repository.cachedFeed(for: url(0)))
        XCTAssertNil(repository.cachedFeed(for: url(1)))
    }

    /// A synchronous cachedFeed(for:) read also makes that feed the most recent.
    func testCachedFeed_Read_KeepsThatFeedOverOlderOnes() async throws {
        let repository = makeRepository()
        try await load(repository, 0..<limit)

        XCTAssertNotNil(repository.cachedFeed(for: url(0)))
        _ = try await repository.loadTopLevelCatalog(at: url(limit))

        XCTAssertNotNil(repository.cachedFeed(for: url(0)))
        XCTAssertNil(repository.cachedFeed(for: url(1)))
    }

    // MARK: - Removal keeps the count right

    /// An invalidated feed frees its place: the next load drops nothing else.
    func testInvalidateCache_FreesAPlace_NextLoadDropsNothing() async throws {
        let repository = makeRepository()
        try await load(repository, 0..<limit)

        repository.invalidateCache(for: url(0))
        _ = try await repository.loadTopLevelCatalog(at: url(limit))

        for index in 1...limit {
            XCTAssertNotNil(repository.cachedFeed(for: url(index)), "feed \(index) should stay in memory")
        }
    }

    /// After an invalidation, later feeds past the limit still drop the oldest
    /// remaining feed, not the ones just loaded.
    func testInvalidateCache_ThenTwoFeedsPastTheLimit_DropsTheOldestRemaining() async throws {
        let repository = makeRepository()
        try await load(repository, 0..<limit)

        repository.invalidateCache(for: url(0))
        try await load(repository, limit..<(limit + 2))

        XCTAssertNil(repository.cachedFeed(for: url(1)))
        for index in 2..<(limit + 2) {
            XCTAssertNotNil(repository.cachedFeed(for: url(index)), "feed \(index) should stay in memory")
        }
    }

    /// After a memory warning clears the feeds, a full set of new feeds fits again.
    func testReleaseInMemoryCaches_ThenLoadingToTheLimit_KeepsEveryFeed() async throws {
        let repository = makeRepository()
        try await load(repository, 0..<limit)

        repository.releaseInMemoryCaches()
        try await load(repository, 100..<(100 + limit))

        XCTAssertNil(repository.cachedFeed(for: url(0)))
        for index in 100..<(100 + limit) {
            XCTAssertNotNil(repository.cachedFeed(for: url(index)), "feed \(index) should stay in memory")
        }
    }

    /// Refetching an expired feed replaces it in one place and makes it the
    /// most recent, so the next feed past the limit drops the next oldest.
    func testLoad_RefetchOfAnExpiredFeed_TakesOnePlaceAndBecomesMostRecent() async throws {
        let repository = makeRepository()
        try await load(repository, 0..<limit)
        let start = testNow.value
        testNow.value = start.addingTimeInterval(86_401)
        _ = try await repository.loadTopLevelCatalog(at: url(0))
        testNow.value = start

        _ = try await repository.loadTopLevelCatalog(at: url(limit))

        XCTAssertEqual(api.fetchFeedCalls.filter { $0 == url(0) }.count, 2)
        XCTAssertNotNil(repository.cachedFeed(for: url(0)))
        XCTAssertNil(repository.cachedFeed(for: url(1)))
        XCTAssertNotNil(repository.cachedFeed(for: url(2)))
    }

    // MARK: - Format entries

    /// Loading a feed with format entry points fills the format-entries cache,
    /// so opening search needs no extra request.
    func testLoadTopLevelCatalog_FeedWithEntryPoints_PrewarmsFormatEntries() async throws {
        let repository = makeRepository()
        let groups = url(500)
        api.stubbedFeeds[groups] = try XCTUnwrap(Self.makeFeedWithEntryPoints())

        _ = try await repository.loadTopLevelCatalog(at: groups)
        let entries = try await repository.fetchSearchEntryPoints(from: groups)

        XCTAssertEqual(entries.map(\.title), ["eBooks", "Audiobooks"])
        XCTAssertTrue(api.fetchSearchEntryPointsCalls.isEmpty)
    }

    /// The format-entries cache has the same limit and drops the oldest first.
    func testFetchSearchEntryPoints_OnePastTheLimit_RefetchesOnlyTheOldest() async throws {
        let repository = makeRepository()
        api.stubbedSearchEntryPoints = [
            SearchFormatEntry(id: "Book", title: "eBooks", groupsFeedURL: url(999), searchDescriptorURL: nil, isActive: true)
        ]
        for index in 0...limit {
            _ = try await repository.fetchSearchEntryPoints(from: url(index))
        }

        _ = try await repository.fetchSearchEntryPoints(from: url(limit))
        _ = try await repository.fetchSearchEntryPoints(from: url(1))
        _ = try await repository.fetchSearchEntryPoints(from: url(0))

        XCTAssertEqual(api.fetchSearchEntryPointsCalls.filter { $0 == url(0) }.count, 2)
        XCTAssertEqual(api.fetchSearchEntryPointsCalls.filter { $0 == url(1) }.count, 1)
        XCTAssertEqual(api.fetchSearchEntryPointsCalls.filter { $0 == url(limit) }.count, 1)
    }

    private static func makeFeedWithEntryPoints() -> CatalogFeed? {
        let xml = """
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
        """
        guard let data = xml.data(using: .utf8),
              let tppXML = TPPXML(data: data),
              let opdsFeed = TPPOPDSFeed(xml: tppXML) else { return nil }
        return CatalogFeed(feed: opdsFeed)
    }
}
