//
//  RegistryTruncationRegressionTests.swift
//  PalaceTests
//
//  PP-5191, the regression proper. Drives the REAL first-page fast path — not a
//  helper — through the `crawlerFetcher` seam, in the field configuration that
//  produced HelpSpot 19030 and 19012:
//
//    * no usable disk cache (cold, or >24h old, or metadata lost)
//    * so `loadCatalogs` takes path 3: bundled snapshot, THEN the network
//    * page 1 arrives carrying a fraction of the registry and declaring the true total
//    * pagination for the remaining pages FAILS (dropped connection / backgrounded)
//
//  Before the fix, page 1 was written verbatim over the whole bucket and the
//  complete bundled snapshot committed moments earlier was destroyed. A patron
//  whose library was not among the 100 most-recently-modified was left with an
//  app that could not name it, could not list it in Settings, and told them to
//  sign in. On `release/3.3.0` every assertion below fails.
//

import XCTest
import PalaceCatalog
import PalacePreferences
@testable import Palace

final class RegistryTruncationRegressionTests: XCTestCase {

    private var tempDir: URL!
    private var suiteName: String!
    private var settings: TPPSettings!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pp5191_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Pin settings to a per-suite defaults domain. `settingsAccountIdsList`'s
        // GETTER writes a default list AND reaches `AppContainer.production()` when
        // its key is absent, so an unpinned `TPPSettings()` would both pollute
        // `UserDefaults.standard` and touch the live composition root from a unit
        // test. Seeding the key empty also keeps the catalog preloader a no-op.
        suiteName = "PP5191Regression-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set([String](), forKey: TPPSettings.settingsLibraryAccountsKey)
        settings = TPPSettings(defaults: defaults)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        settings = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    /// Mirrors `AccountRegistryLoader.loadCatalogs`' key derivation
    /// (`AccountRegistryLoader.swift:475-482`).
    private func registryHashForCurrentConfiguration() -> String {
        let targetUrl = TPPConfiguration.customUrl()
            ?? (settings.useBetaLibraries ? TPPConfiguration.betaUrl : TPPConfiguration.prodUrl)
        return targetUrl.absoluteString
            .md5()
            .base64EncodedStringUrlSafe()
            .trimmingCharacters(in: ["="])
    }

    // MARK: - Fixtures

    /// Built with the PRODUCTION encoder, then decorated with pagination links.
    ///
    /// An earlier revision hand-rolled this JSON and it did not decode —
    /// `OPDS2CatalogsFeed.fromData` returned nil, `mergePartialPage` correctly took
    /// its "nothing parseable to overlay onto" path, and the test failed looking
    /// exactly like the production defect it exists to catch. Fixtures go through
    /// the same encoder the app uses, or they test the fixture.
    private func feedData(uuids: [String], declaring: Int?, withNextPage: Bool = false) throws -> Data {
        let encoded = try XCTUnwrap(LibraryCatalogMerger.serializeAsCatalogsFeed(
            publications: uuids.map {
                OPDS2Publication(links: [], metadata: .init(id: $0, title: "Library \($0)"), images: nil)
            },
            metadata: OPDS2CatalogsFeed.Metadata(
                adobe_vendor_id: "ThePalaceProject",
                title: "Libraries",
                numberOfItems: declaring
            )
        ))
        guard withNextPage else { return encoded }
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        root["links"] = [[
            "rel": "next",
            "href": "https://registry.palaceproject.io/libraries/crawlable?offset=100&size=100",
            "type": "application/opds+json"
        ]]
        return try JSONSerialization.data(withJSONObject: root)
    }

    /// Guards the fixture itself: if these bytes stop decoding, every assertion in
    /// this file silently stops testing the thing it names.
    private func assertFixtureDecodes(_ data: Data, expected: Int, file: StaticString = #filePath, line: UInt = #line) throws {
        let feed = try OPDS2CatalogsFeed.fromData(data)
        XCTAssertEqual(feed.catalogs.count, expected,
                       "fixture must decode through the production parser", file: file, line: line)
    }

    private func makeLoader(
        store: AccountRegistryStore,
        cache: InMemoryRegistryCache,
        bundledURL: URL?,
        fetcher: CrawlerNetworkFetching
    ) -> AccountRegistryLoader {
        let loader = AccountRegistryLoader(
            registryCache: cache,
            registryStore: store,
            crawlScheduler: .production,
            settings: settings,
            imageCache: ImageCache.shared,
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
        loader.snapshotResourceResolver = StubBundleResolver(url: bundledURL)
        loader.crawlerFetcher = fetcher
        return loader
    }

    // MARK: - The regression

    func testFirstPage_doesNotDestroyTheBundledRegistry_whenPaginationFails() async throws {
        // The bundled snapshot: a COMPLETE registry of three libraries. In the
        // field this is 1142 and it is written by `loadCatalogs` path 3 moments
        // before the network call below.
        let bundled = try feedData(uuids: ["bundled-a", "bundled-b", "patron-library"], declaring: 3)
        try assertFixtureDecodes(bundled, expected: 3)
        let bundledURL = tempDir.appendingPathComponent("bundled_registry.json")
        try bundled.write(to: bundledURL)

        // Page 1: one library, honestly declaring a much larger registry, with a
        // next link. `patron-library` is NOT on it — it is the page-7 case.
        let page1 = try feedData(uuids: ["freshly-modified"], declaring: 1457, withNextPage: true)
        try assertFixtureDecodes(page1, expected: 1)

        let store = AccountRegistryStore()
        let cache = InMemoryRegistryCache()
        let fetcher = ScriptedFetcher(firstPage: page1)   // every later page throws
        let loader = makeLoader(store: store, cache: cache, bundledURL: bundledURL, fetcher: fetcher)

        let done = expectation(description: "loadCatalogs completed")
        loader.loadCatalogs { _ in done.fulfill() }
        await fulfillment(of: [done], timeout: 20)
        await loader._awaitAllCrawlTasksForTesting()

        // Diagnostic trace — makes a setup failure legible instead of looking
        // like the production defect.
        // Deterministic premise. An earlier revision asserted
        // `fetcher.failedPageRequests > 0` to prove pagination had failed — but that
        // depends on a BACKGROUND task having started, and it flapped: it passed on
        // one run and failed on the next with no code change. A premise that flaps is
        // worse than none, because a spurious pass hides the thing it guards.
        //
        // The cache write trace is recorded synchronously inside the first-page
        // branch, so it is ordered with respect to this assertion. It also pins the
        // defect directly: the bundled snapshot commits 3, and the page write that
        // follows must carry 4 (3 + the page's own), never 1.
        let networkWrites = cache.writes.filter { !$0.isBundled }
        XCTAssertEqual(cache.writes.first?.count, 3,
                       "Premise: the bundled snapshot must have committed 3 libraries first")
        XCTAssertEqual(networkWrites.first?.count, 4,
                       "The page-1 write must carry the MERGED registry (3 bundled + 1 fresh). A count of 1 here is the defect verbatim: page 1 written over the whole registry.")

        XCTAssertNotNil(store.account("patron-library"),
                        "THE DEFECT: the patron's library was committed from the bundled snapshot and must survive a partial page-1 write. Before the fix it was discarded and `currentAccount` went nil — no library name, no Settings row, and a sign-in prompt for a signed-in patron.")
        XCTAssertNotNil(store.account("bundled-a"))
        XCTAssertNotNil(store.account("bundled-b"))
        XCTAssertNotNil(store.account("freshly-modified"),
                        "the page's own library must still be merged IN — the fix must not discard the fresh data either")
    }

    // MARK: - S-1: what the disk gate is, and what it is NOT
    //
    // There is deliberately no test here asserting "a refused first-page write leaves
    // the cache untouched", because INV-2 cannot refuse at that call site **while the
    // bundled cache write succeeds.** That qualifier is load-bearing: `mergePartialPage`
    // reads its base from DISK (`AccountRegistryLoader.swift:570`), not from the store,
    // so a failed or cleared cache write (disk full, sandbox error, `clearFileCaches()`
    // racing a library switch) yields a bare page and INV-2 does refuse. Two structural
    // facts make it unreachable on the healthy path:
    //
    //   1. `loadCatalogs` returns at path 1 (`AccountRegistryLoader.swift:486`) when
    //      the bucket is non-empty, so reaching `fetchFromNetwork` REQUIRES an empty
    //      bucket — and an empty resident set is INV-2's always-accept cell.
    //   2. If the bundled snapshot populates the bucket within the same run, the
    //      merged page-1 feed is a SUPERSET of it, which removes nothing and is
    //      likewise accepted.
    //
    // Two earlier revisions of this file claimed to test it. The first seeded a
    // 3-library bundle and a 1-library page, which merges to a superset — `applied`
    // was true throughout, so deleting the gate changed nothing. The second seeded the
    // bucket directly to manufacture a resident set, which sent `loadCatalogs` down
    // path 1: it asserted "no writes" and got it because NOTHING RAN. Both passed with
    // the gate deleted, and one of them was cited as a red-proof in a commit body.
    //
    // The gate is still correct to keep — it is live whenever the cache write fails,
    // and it becomes live generally the moment any future caller reaches that write
    // with a populated bucket. It is NOT dead code. But it
    // is documented here as unreachable rather than covered by a test that cannot
    // fail. What IS reachable and IS tested below: the `didApplyBucketWrite` signal
    // that the gate consumes.

    /// QA round 2, finding A. The background pagination used to undo the merge it was
    /// meant to complete: its merge base was page 1 rather than the cache we had just
    /// written, its cache write was unconditional, and it passed no completeness — so
    /// the `= true` default licensed INV-2 to delete. Seconds after the merge saved
    /// 1242 libraries, a walk that ended short wrote back only what it saw.
    ///
    /// `reachedDeclaredTotal` already DETECTED that case and declined to record a full
    /// crawl — but nothing consumed the verdict for the bucket write. A guard whose
    /// refusal renders as success, in post-condition form.
    func testShortBackgroundCrawl_cannotDeleteTheLibrariesItNeverSaw() async throws {
        let bundled = try feedData(uuids: ["bundled-a", "bundled-b", "patron-library"], declaring: 3)
        try assertFixtureDecodes(bundled, expected: 3)
        let bundledURL = tempDir.appendingPathComponent("bundled_registry.json")
        try bundled.write(to: bundledURL)

        // Page 1 declares a far larger registry and links onward, so pagination runs;
        // page 2 returns a SHORT list that knows nothing of the bundled libraries.
        let page1 = try feedData(uuids: ["fresh-1"], declaring: 900, withNextPage: true)
        let page2 = try feedData(uuids: ["fresh-2"], declaring: 900)
        let emptyPage = try feedData(uuids: [], declaring: 900)

        let store = AccountRegistryStore()
        let cache = InMemoryRegistryCache()
        let loader = makeLoader(store: store, cache: cache, bundledURL: bundledURL,
                                fetcher: SequencedFetcher(pages: [page1, page2], emptyPage: emptyPage))

        let done = expectation(description: "loadCatalogs completed")
        loader.loadCatalogs { _ in done.fulfill() }
        await fulfillment(of: [done], timeout: 20)
        await loader._awaitAllCrawlTasksForTesting()

        XCTAssertNotNil(store.account("patron-library"),
                        "A crawl that ended at 2 of a declared 900 must not delete the libraries it never reached. Before this fix the pagination write-back took the `isCompleteFeed: true` default and removed them seconds after the merge had saved them.")
        XCTAssertNotNil(store.account("bundled-a"))
        XCTAssertNotNil(store.account("bundled-b"))

        if let onDisk = cache.lastWrittenData {
            let ids = Set(try OPDS2CatalogsFeed.fromData(onDisk).catalogs.map(\.metadata.id))
            XCTAssertTrue(ids.contains("patron-library"),
                          "and the bytes a future launch will hydrate must not be short either")
        }
    }

    /// The `?? feedIsPositivelyComplete(feed)` default in `loadAccountSetsAndAuthDoc`
    /// is the guard for six of the eight entry points, and a `= true` default hid on
    /// that line for three revisions before QA caught it.
    ///
    /// `palace_mutate` cannot cover it: the loader reports `0/36 mutation points on
    /// changed lines`, and the tool has no `??` operator, so a
    /// `?? feedIsPositivelyComplete(feed)` -> `?? true` mutant is not in its set. The
    /// mutation gate therefore reports "nothing to mutate" for this file — which reads
    /// exactly like a pass. This test is the only thing standing in for it, so it
    /// deliberately passes NO `isCompleteFeed` argument: it exercises the default path
    /// a caller gets by forgetting.
    func testDerivedCompleteness_aCallerThatPassesNothing_cannotDelete() async throws {
        let hash = registryHashForCurrentConfiguration()
        let store = AccountRegistryStore(currentHash: hash)
        let resident = ["a", "b", "c"].map {
            Account(publication: OPDS2Publication(links: [], metadata: .init(id: $0, title: $0), images: nil),
                    imageCache: ImageCache.shared)
        }
        XCTAssertTrue(store.replaceBucket(hash: hash, accounts: resident, isCompleteFeed: true))

        let loader = makeLoader(store: store, cache: InMemoryRegistryCache(), bundledURL: nil,
                                fetcher: ScriptedFetcher(firstPage: Data()))

        // No `numberOfItems` at all — the shape the direct-GET `/libraries` fallback
        // returns (measured: 1457 catalogs, no declared total). It removes two
        // libraries, so it may only be applied against POSITIVE completeness.
        let lossy = try feedData(uuids: ["a"], declaring: nil)
        var applied: Bool?
        let done = expectation(description: "load finished")
        loader.loadAccountSetsAndAuthDoc(
            fromCatalogData: lossy,
            key: hash,
            didApplyBucketWrite: { applied = $0 }
        ) { _ in done.fulfill() }
        await fulfillment(of: [done], timeout: 10)

        XCTAssertEqual(applied, false,
                       "A caller that passes no completeness must NOT get delete authority by default. With `?? true` this feed — which declares nothing and drops two libraries — would be applied, and the registry would shrink to one on the code path that runs when the network is already misbehaving.")
        XCTAssertEqual(store.accounts(forKey: hash).count, 3)
        XCTAssertNotNil(store.account("c"))
    }

    // MARK: - S-3: a refusal must refuse COMPLETELY

    func testRefusedWrite_leavesNoOrphanStateAndPostsNoAccountChange() async throws {
        let store = AccountRegistryStore(currentHash: "h")
        // `Account._setState` writes `AccountStateStore.shared` (Account+State.swift:204);
        // the injected store is only READ by the loader. Asserting on a fresh injected
        // store therefore could not fail — it is `.notLoaded` no matter what production
        // does. Assert the singleton, with a unique uuid so no other suite can collide.
        let stateStore = AccountStateStore.shared
        let intruderUUID = "pp5191-intruder-\(UUID().uuidString)"
        let resident = ["a", "b", "c"].map {
            Account(publication: OPDS2Publication(links: [], metadata: .init(id: $0, title: $0), images: nil),
                    imageCache: ImageCache.shared)
        }
        XCTAssertTrue(store.replaceBucket(hash: "h", accounts: resident, isCompleteFeed: true))

        let loader = AccountRegistryLoader(
            registryCache: InMemoryRegistryCache(),
            registryStore: store,
            crawlScheduler: .production,
            settings: settings,
            imageCache: ImageCache.shared,
            accountStateStore: stateStore,
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

        var accountChangedPosts = 0
        let token = NotificationCenter.default.addObserver(
            forName: .TPPCurrentAccountDidChange, object: nil, queue: nil
        ) { _ in accountChangedPosts += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        // A lossy partial write: one library, declaring far more, over a resident three.
        let lossy = try feedData(uuids: [intruderUUID], declaring: 1457)
        var appliedSignal: Bool?
        let done = expectation(description: "load finished")
        loader.loadAccountSetsAndAuthDoc(
            fromCatalogData: lossy,
            key: "h",
            isCompleteFeed: false,
            didApplyBucketWrite: { appliedSignal = $0 }
        ) { _ in done.fulfill() }
        await fulfillment(of: [done], timeout: 10)

        XCTAssertEqual(appliedSignal, false,
                       "INV-2 must have refused this write, and must SAY so through `didApplyBucketWrite`. This signal is what the cache-write gate consumes; if it stopped being delivered, the disk and the bucket would silently disagree.")
        XCTAssertNotNil(appliedSignal,
                        "the signal must actually fire — an unfired callback and a `false` one are not the same thing, and only one of them gates anything")
        XCTAssertEqual(store.accounts(forKey: "h").count, 3, "the resident registry stands")
        XCTAssertNil(store.account(intruderUUID))

        if case .notLoaded = stateStore.state(for: intruderUUID) {
            // expected: no state was ever recorded for a uuid that never entered the bucket
        } else {
            XCTFail("A refused write must not drive the state machine for accounts that never entered the bucket — `AccountStateStore` would then hold .basicInfoLoaded for a uuid `account(_:)` cannot resolve, which reads from every consumer's side exactly like a successful load.")
        }
        XCTAssertEqual(accountChangedPosts, 0,
                       "…and it must not announce an account change that did not happen")
    }
}

// MARK: - Test doubles

private final class StubBundleResolver: BundleResourceResolving {
    private let url: URL?
    init(url: URL?) { self.url = url }
    /// `nil` models a build with no bundled snapshot, so `loadCatalogs` path 3 goes
    /// straight to the network fetch with whatever the cache already holds.
    func resourceURL(forName name: String, extension ext: String) -> URL? { url }
}

/// Serves page 1 once, then fails — the interrupted-pagination field scenario.
private final class ScriptedFetcher: CrawlerNetworkFetching, @unchecked Sendable {
    private let firstPage: Data
    private let lock = NSLock()
    private var served = false

    init(firstPage: Data) { self.firstPage = firstPage }

    /// `NSLock.lock()/unlock()` are unavailable from async contexts under Swift 6;
    /// the scoped `withLock` form is the async-safe equivalent and keeps the
    /// claim-once decision atomic against the parallel page fetches.
    private func claimFirstPage() -> Bool {
        lock.withLock {
            let isFirst = !served
            if isFirst { served = true }
            return isFirst
        }
    }

    func fetchData(from url: URL) async throws -> (Data, HTTPURLResponse?) {
        if claimFirstPage() { return (firstPage, nil) }
        throw URLError(.networkConnectionLost)
    }
}

/// Serves a scripted sequence of pages, then keeps returning a VALID EMPTY page.
///
/// Throwing on exhaustion was wrong and made the clobber test vacuous: a throw
/// inside `fetchPagesParallel` makes `crawlRemainingPages` return `.failure`, so the
/// write-back branch under test never executes at all and the test passed with the
/// defect fully reintroduced. The defect needs the crawl to SUCCEED while falling
/// short of its declared total — the server under-reporting — so exhaustion has to
/// look like an empty page, not a network error.
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

private final class InMemoryRegistryCache: AccountRegistryCaching, @unchecked Sendable {
    private let lock = NSLock()
    private var blobs: [String: Data] = [:]
    private(set) var lastWrittenData: Data?
    /// Diagnostic: (hash, catalogCount, isBundled) per write, in order.
    private var _writes: [(hash: String, count: Int, isBundled: Bool)] = []
    var writes: [(hash: String, count: Int, isBundled: Bool)] { lock.lock(); defer { lock.unlock() }; return _writes }
    private var _reads: [(hash: String, hit: Bool)] = []
    var reads: [(hash: String, hit: Bool)] { lock.lock(); defer { lock.unlock() }; return _reads }

    /// Pre-populate without counting it as a production write.
    func seed(_ data: Data, hash: String) {
        lock.lock(); defer { lock.unlock() }
        blobs[hash] = data
    }

    func writeCatalogData(_ data: Data, hash: String, isBundled: Bool) {
        let n = (try? OPDS2CatalogsFeed.fromData(data))?.catalogs.count ?? -1
        lock.lock(); defer { lock.unlock() }
        blobs[hash] = data
        lastWrittenData = data
        _writes.append((hash, n, isBundled))
    }
    func readCatalogData(hash: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        let d = blobs[hash]
        _reads.append((hash, d != nil))
        return d
    }
    // False so `loadCatalogs` takes path 3 (bundled + network) — the cold / >24h /
    // metadata-lost entry condition this defect needs.
    func hasFreshCatalogData(hash: String) -> Bool { false }
    func isCatalogStale(hash: String) -> Bool { true }
    func slimSnapshotURL(hash: String) -> URL? { nil }
    func clearFileCaches() { lock.lock(); defer { lock.unlock() }; blobs.removeAll() }
}

private final class InertNetworking: AccountNetworking, @unchecked Sendable {
    func cancelNonEssentialTasks() {}
    func clearCache() {}
    func GET(_ reqURL: URL, useTokenIfAvailable: Bool) async throws -> (Data, URLResponse?) {
        throw URLError(.networkConnectionLost)
    }
}
