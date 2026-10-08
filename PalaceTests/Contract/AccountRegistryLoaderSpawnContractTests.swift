//
//  AccountRegistryLoaderSpawnContractTests.swift
//
//  Pins the priority, detachedness and order of every task `AccountRegistryLoader`
//  spawns on the first-run, pagination and refresh paths. The first-run library
//  picker waits on the first-run leg, so it must not run at the `.utility`
//  priority the background crawls share: the cooperative pool queues a task behind
//  non-yielding work of its own priority.
//

import XCTest
import PalaceCatalog
import PalacePreferences
@testable import Palace

final class AccountRegistryLoaderSpawnContractTests: PalaceWiringTestCase {

    private var suiteName: String!
    private var settings: TPPSettings!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // An unpinned `TPPSettings()` writes `UserDefaults.standard` and reaches the
        // live composition root from `settingsAccountIdsList`. Seeding the list empty
        // also keeps the catalog preloader a no-op.
        suiteName = "RegistrySpawnContract-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.set([String](), forKey: TPPSettings.settingsLibraryAccountsKey)
        settings = TPPSettings(defaults: defaults)
    }

    override func tearDownWithError() throws {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        settings = nil
        try super.tearDownWithError()
    }

    // MARK: - First run

    /// A cold `loadCatalogs` spawns the first-run task detached at `.userInitiated`,
    /// because the first-run library picker waits on it.
    func testLoadCatalogs_WhenNothingCached_SpawnsFirstRunTaskDetachedAtUserInitiated() {
        let recorder = SpawnRecorder(runsOperations: false)
        let loader = makeLoader(scheduler: recorder.scheduler(), cache: StubCache(), fetcher: FailingFetcher())

        loader.loadCatalogs(completion: nil)

        XCTAssertEqual(recorder.spawns, [Spawn(.userInitiated, detached: true)])
    }

    /// When the first-page crawl fails, the direct GET that resolves the waiting
    /// `loadCatalogs` completion runs at `.userInitiated`, after the first-run task
    /// and the crawl, and the completion still fires once.
    func testLoadCatalogs_WhenFirstPageFails_FallbackGETRunsAtUserInitiated() async {
        let recorder = SpawnRecorder(runsOperations: true)
        let loader = makeLoader(scheduler: recorder.scheduler(), cache: StubCache(), fetcher: FailingFetcher())
        let completions = CompletionRecorder()

        loader.loadCatalogs(completion: { completions.record($0) })
        await loader._awaitCatalogLoadForTesting()

        XCTAssertEqual(recorder.spawns, [
            Spawn(.userInitiated, detached: true),   // first-run
            Spawn(.userInitiated, detached: false),  // first-page crawl
            Spawn(.userInitiated, detached: true),   // direct-GET fallback
        ])
        // The GET fails and nothing is cached, so the load reports failure.
        XCTAssertEqual(completions.values, [false], "the waiting completion fires exactly once, from the fallback")
        XCTAssertEqual(loader._ownedCrawlTaskCountForTesting, 0)
        ContractSnapshot.assert(recorder.log, named: "firstRun_firstPageFails")
    }

    /// Once page 1 has been shown, the remaining pages and the catalog preload are
    /// background work and stay at `.utility`.
    func testLoadCatalogs_WhenRegistryHasMorePages_PaginationAndPreloadStayUtility() async throws {
        let page1 = try feedData(uuids: ["a", "b"], declaring: 3, withNextPage: true)
        let page2 = try feedData(uuids: ["c"], declaring: 3)
        let empty = try feedData(uuids: [], declaring: 3)
        let recorder = SpawnRecorder(runsOperations: true)
        let loader = makeLoader(
            scheduler: recorder.scheduler(),
            cache: StubCache(),
            fetcher: SequencedFetcher(pages: [page1, page2], emptyPage: empty)
        )

        loader.loadCatalogs(completion: nil)
        await loader._awaitCatalogLoadForTesting()

        XCTAssertEqual(recorder.spawns, [
            Spawn(.userInitiated, detached: true),   // first-run
            Spawn(.userInitiated, detached: false),  // first-page crawl
            Spawn(.utility, detached: false),        // remaining pages
            Spawn(.utility, detached: false),        // catalog preload
        ])
        XCTAssertEqual(loader._ownedCrawlTaskCountForTesting, 0)
        ContractSnapshot.assert(recorder.log, named: "firstRun_paginates")
    }

    // MARK: - Background refresh

    /// A stale in-memory registry is refreshed at `.utility`, and `fallbackDirectRefresh`
    /// stays `.utility`: the patron already has a registry to look at.
    func testLoadCatalogs_WhenLoadedRegistryIsStale_RefreshAndItsFallbackStayUtility() async throws {
        let recorder = SpawnRecorder(runsOperations: true)
        let store = try loadedStore()
        let loader = makeLoader(scheduler: recorder.scheduler(), cache: StubCache(isStale: true), fetcher: FailingFetcher(), store: store)
        let completions = CompletionRecorder()

        loader.loadCatalogs(completion: { completions.record($0) })
        XCTAssertEqual(completions.values, [true], "a loaded registry completes before any refresh task runs")
        await loader._awaitCatalogLoadForTesting()

        XCTAssertEqual(recorder.spawns, [
            Spawn(.utility, detached: false),  // incremental crawl refresh
            Spawn(.utility, detached: true),   // fallbackDirectRefresh after the crawl fails
        ])
        XCTAssertEqual(completions.values, [true], "the refresh does not complete the caller again")
        XCTAssertEqual(loader._ownedCrawlTaskCountForTesting, 0)
        ContractSnapshot.assert(recorder.log, named: "staleRefresh_crawlFails")
    }

    // MARK: - Explicit custom registry URL (developer setting; the crawler is bypassed)

    /// With an explicit registry URL the first-load GET is the only network leg the
    /// waiting completion depends on, so it runs at `.userInitiated`.
    func testLoadCatalogs_WhenRegistryURLIsExplicit_FirstLoadGETRunsAtUserInitiated() async {
        settings.customLibraryRegistryServer = Self.explicitRegistryURL
        let recorder = SpawnRecorder(runsOperations: true)
        let loader = makeLoader(scheduler: recorder.scheduler(), cache: StubCache(), fetcher: FailingFetcher())
        let completions = CompletionRecorder()

        loader.loadCatalogs(completion: { completions.record($0) })
        await loader._awaitCatalogLoadForTesting()

        XCTAssertEqual(recorder.spawns, [
            Spawn(.userInitiated, detached: true),  // first-run
            Spawn(.userInitiated, detached: true),  // direct GET of the explicit URL
        ])
        XCTAssertEqual(completions.values, [false], "the waiting completion fires once, from the failed GET")
        XCTAssertEqual(loader._ownedCrawlTaskCountForTesting, 0)
    }

    /// With an explicit registry URL, refreshing an already-loaded registry is
    /// background work and its direct GET stays `.utility`.
    func testLoadCatalogs_WhenRegistryURLIsExplicitAndStale_RefreshGETStaysUtility() async throws {
        settings.customLibraryRegistryServer = Self.explicitRegistryURL
        let recorder = SpawnRecorder(runsOperations: true)
        let store = try loadedStore()
        let loader = makeLoader(scheduler: recorder.scheduler(), cache: StubCache(isStale: true), fetcher: FailingFetcher(), store: store)
        let completions = CompletionRecorder()

        loader.loadCatalogs(completion: { completions.record($0) })
        await loader._awaitCatalogLoadForTesting()

        XCTAssertEqual(recorder.spawns, [Spawn(.utility, detached: true)])
        XCTAssertEqual(completions.values, [true])
        XCTAssertEqual(loader._ownedCrawlTaskCountForTesting, 0)
    }

    // MARK: - Helpers

    private static let explicitRegistryURL = "https://registry.example.test/libraries"

    private func registryHash() -> String {
        let targetUrl = TPPConfiguration.customUrl(settings: settings)
            ?? (settings.useBetaLibraries ? TPPConfiguration.betaUrl : TPPConfiguration.prodUrl)
        return targetUrl.absoluteString.md5().base64EncodedStringUrlSafe().trimmingCharacters(in: ["="])
    }

    /// A store whose bucket for the current registry hash already holds one library.
    private func loadedStore() throws -> AccountRegistryStore {
        let store = AccountRegistryStore()
        let account = Account(
            publication: OPDS2Publication(links: [], metadata: .init(id: "resident", title: "Resident"), images: nil),
            imageCache: MockImageCache()
        )
        let applied = store.replaceBucket(hash: registryHash(), accounts: [account], isCompleteFeed: true)
        return try XCTUnwrap(applied ? store : nil, "precondition: the registry is already loaded")
    }

    /// Built with the production encoder so the fixture decodes the way the app's bytes do.
    private func feedData(uuids: [String], declaring: Int, withNextPage: Bool = false) throws -> Data {
        let encoded = try XCTUnwrap(LibraryCatalogMerger.serializeAsCatalogsFeed(
            publications: uuids.map {
                OPDS2Publication(links: [], metadata: .init(id: $0, title: "Library \($0)"), images: nil)
            },
            metadata: OPDS2CatalogsFeed.Metadata(adobe_vendor_id: "ThePalaceProject", title: "Libraries", numberOfItems: declaring)
        ))
        guard withNextPage else { return encoded }
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        root["links"] = [[
            "rel": "next",
            "href": "https://registry.palaceproject.io/libraries/crawlable?offset=2&size=2",
            "type": "application/opds+json",
        ]]
        return try JSONSerialization.data(withJSONObject: root)
    }

    private func makeLoader(
        scheduler: CrawlTaskScheduler,
        cache: StubCache,
        fetcher: CrawlerNetworkFetching,
        store: AccountRegistryStore = AccountRegistryStore()
    ) -> AccountRegistryLoader {
        let loader = AccountRegistryLoader(
            registryCache: cache,
            registryStore: store,
            crawlScheduler: scheduler,
            settings: settings,
            imageCache: MockImageCache(),
            accountStateStore: AccountStateStore(),
            ageCheck: TPPAgeCheck(ageCheckChoiceStorage: settings),
            networkExecutorProvider: { InertNetworking() },
            currentAccountProvider: { nil },
            currentAccountIdProvider: { nil },
            accountsForKeyProvider: { store.accounts(forKey: $0) },
            accountProvider: { store.account($0) },
            currentUserAccountProvider: { nil },
            driveCurrentAccountAuthDoc: {},
            fetchAuthDocumentWithStateMachine: { _, completion in completion(true) },
            currentLibraryAccountProvider: { nil }
        )
        // No bundled snapshot: the first-run task goes straight to the network leg.
        loader.snapshotResourceResolver = NoBundledSnapshot()
        loader.crawlerFetcher = fetcher
        return loader
    }
}

// MARK: - Test doubles

private struct Spawn: Equatable, CustomStringConvertible {
    let priority: TaskPriority
    let detached: Bool
    init(_ priority: TaskPriority, detached: Bool) {
        self.priority = priority
        self.detached = detached
    }
    var description: String { "\(Self.name(priority))\(detached ? " detached" : "")" }

    static func name(_ p: TaskPriority) -> String {
        switch p {
        case .userInitiated: return "userInitiated"
        case .utility: return "utility"
        case .background: return "background"
        case .medium: return "medium"
        default: return "raw(\(p.rawValue))"
        }
    }
}

/// Records each spawn into a `CallLog` and, when `runsOperations`, runs it on the
/// production arm so the chain proceeds exactly as it would in the app.
private final class SpawnRecorder: @unchecked Sendable {
    let log = CallLog()
    private let runsOperations: Bool
    private let lock = NSLock()
    private var _spawns: [Spawn] = []
    var spawns: [Spawn] { lock.withLock { _spawns } }

    init(runsOperations: Bool) { self.runsOperations = runsOperations }

    func scheduler() -> CrawlTaskScheduler {
        CrawlTaskScheduler(
            spawn: { [self] priority, op in
                record(Spawn(priority, detached: false))
                return runsOperations ? CrawlTaskScheduler.production.spawn(priority, op) : Task {}
            },
            spawnDetached: { [self] priority, op in
                record(Spawn(priority, detached: true))
                return runsOperations ? CrawlTaskScheduler.production.spawnDetached(priority, op) : Task {}
            }
        )
    }

    private func record(_ spawn: Spawn) {
        lock.withLock { _spawns.append(spawn) }
        log.record("spawn", args: ["priority": Spawn.name(spawn.priority), "detached": spawn.detached])
    }
}

private final class CompletionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Bool] = []
    var values: [Bool] { lock.withLock { _values } }
    func record(_ value: Bool) { lock.withLock { _values.append(value) } }
}

private struct NoBundledSnapshot: BundleResourceResolving {
    func resourceURL(forName name: String, extension ext: String) -> URL? { nil }
}

private struct FailingFetcher: CrawlerNetworkFetching {
    func fetchData(from url: URL) async throws -> (Data, HTTPURLResponse?) {
        throw URLError(.notConnectedToInternet)
    }
}

/// Serves `pages` in order, then a valid empty page, so pagination ends in success.
private final class SequencedFetcher: CrawlerNetworkFetching, @unchecked Sendable {
    private let pages: [Data]
    private let emptyPage: Data
    private let lock = NSLock()
    private var index = 0
    init(pages: [Data], emptyPage: Data) {
        self.pages = pages
        self.emptyPage = emptyPage
    }

    func fetchData(from url: URL) async throws -> (Data, HTTPURLResponse?) {
        let page = lock.withLock { () -> Data in
            guard index < pages.count else { return emptyPage }
            defer { index += 1 }
            return pages[index]
        }
        return (page, nil)
    }
}

/// In-memory cache with no disk: never fresh, optionally stale.
private final class StubCache: AccountRegistryCaching, @unchecked Sendable {
    private let isStale: Bool
    private let lock = NSLock()
    private var blobs: [String: Data] = [:]
    init(isStale: Bool = false) { self.isStale = isStale }

    func writeCatalogData(_ data: Data, hash: String, isBundled: Bool) { lock.withLock { blobs[hash] = data } }
    func readCatalogData(hash: String) -> Data? { lock.withLock { blobs[hash] } }
    func hasFreshCatalogData(hash: String) -> Bool { false }
    func isCatalogStale(hash: String) -> Bool { isStale }
    func slimSnapshotURL(hash: String) -> URL? { nil }
    func clearFileCaches() { lock.withLock { blobs.removeAll() } }
}

/// Direct GET that fails. Failure takes the branch that posts no notification:
/// the parse-failure branch posts `.TPPCatalogDidLoad` off the main thread, which
/// traps in the host app's `@MainActor` `TPPAccountList` observer.
private final class InertNetworking: AccountNetworking, @unchecked Sendable {
    func cancelNonEssentialTasks() {}
    func clearCache() {}
    func GET(_ reqURL: URL, useTokenIfAvailable: Bool) async throws -> (Data, URLResponse?) {
        throw URLError(.notConnectedToInternet)
    }
}
