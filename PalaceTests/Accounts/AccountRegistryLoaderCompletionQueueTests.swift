//
//  AccountRegistryLoaderCompletionQueueTests.swift
//
//  Every completion of `AccountRegistryLoader` must arrive on the main queue,
//  because callers pass closures formed in `@MainActor` contexts (TPPAccountList,
//  DeveloperSettingsViewModel) and Swift 6 traps when one runs off main.
//

import XCTest
import PalaceCatalog
import PalacePreferences
@testable import Palace
import PalaceUtilities

final class AccountRegistryLoaderCompletionQueueTests: PalaceWiringTestCase {

    private var suiteName: String!
    private var settings: TPPSettings!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // An unpinned `TPPSettings()` writes `UserDefaults.standard` and reaches the
        // live composition root from `settingsAccountIdsList`'s getter.
        suiteName = "RegistryCompletionQueue-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set([String](), forKey: TPPSettings.settingsLibraryAccountsKey)
        settings = TPPSettings(defaults: defaults)
    }

    override func tearDownWithError() throws {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        settings = nil
        try super.tearDownWithError()
    }

    // MARK: - loadAccountSetsAndAuthDoc

    /// The INV-2 refusal path ran the completion on the caller's background queue,
    /// while the success path delivers on main; a main-isolated caller then trapped.
    func testLoadAccountSets_WhenINV2RefusesWrite_CompletesOnMainQueue() async throws {
        let store = AccountRegistryStore(currentHash: "h")
        XCTAssertTrue(store.replaceBucket(hash: "h", accounts: makeAccounts(["a", "b", "c"]), isCompleteFeed: true))
        let loader = makeLoader(store: store)
        let lossy = try feedData(uuids: ["intruder"], declaring: 1457)

        let result = await completeFromBackground(loader: loader, data: lossy, hash: "h", isCompleteFeed: false)

        XCTAssertEqual(result.applied, false, "premise: INV-2 must refuse this write")
        XCTAssertEqual(result.success, true)
        XCTAssertTrue(result.onMain, "the refusal path must complete on main, like the success path")
    }

    /// An unparseable feed completed `false` synchronously on the caller's queue.
    func testLoadAccountSets_WhenFeedDoesNotParse_CompletesFalseOnMainQueue() async throws {
        let store = AccountRegistryStore(currentHash: "h")
        let loader = makeLoader(store: store)

        let result = await completeFromBackground(loader: loader, data: Data("not json".utf8), hash: "h", isCompleteFeed: nil)

        XCTAssertEqual(result.success, false)
        XCTAssertTrue(result.onMain, "the parse-failure path must complete on main, like the success path")
    }

    /// Control for the two tests above: the accepted write already completes on main.
    func testLoadAccountSets_WhenWriteApplied_CompletesOnMainQueue() async throws {
        let store = AccountRegistryStore(currentHash: "h")
        let loader = makeLoader(store: store)
        let complete = try feedData(uuids: ["a", "b"], declaring: 2)

        let result = await completeFromBackground(loader: loader, data: complete, hash: "h", isCompleteFeed: true)

        XCTAssertEqual(result.applied, true, "premise: INV-2 must accept this write")
        XCTAssertEqual(result.success, true)
        XCTAssertTrue(result.onMain)
    }

    // MARK: - loadCatalogs loading handlers

    /// With no cache and both the crawl and the direct GET failing, the loading
    /// handlers were called `false` from the background fetch Task.
    func testLoadCatalogs_WhenNetworkFailsWithNoCache_CompletesFalseOnMainQueue() async throws {
        let loader = makeLoader(store: AccountRegistryStore())
        let recorder = CompletionRecorder()
        let done = expectation(description: "loadCatalogs completed")

        loader.loadCatalogs { @Sendable success in
            recorder.record(success: success, onMain: Thread.isMainThread)
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 10)  // STARVE-001-OK: completion fires inside an owned task, drained on the next line
        await loader._awaitCatalogLoadForTesting()

        XCTAssertEqual(recorder.success, false)
        XCTAssertEqual(recorder.onMain, true, "a failed load must complete on main, like a successful one")
    }

    /// No cache, the crawl fails, and the direct GET returns bytes that do not parse:
    /// the handler and `.TPPCatalogDidLoad` both came from the fetch Task, and the
    /// `@MainActor` `TPPAccountList.catalogDidLoad` observer trapped.
    func testLoadCatalogs_WhenDirectGETBytesDoNotParse_CompletesAndPostsOnMainQueue() async throws {
        let loader = makeLoader(store: AccountRegistryStore(), networking: ScriptedNetworking(body: Data("<html>".utf8)))
        let posts = PostRecorder()
        let recorder = CompletionRecorder()
        let done = expectation(description: "loadCatalogs completed")

        loader.loadCatalogs { @Sendable success in
            recorder.record(success: success, onMain: Thread.isMainThread)
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 10)  // STARVE-001-OK: completion fires inside an owned task, drained on the next line
        await loader._awaitCatalogLoadForTesting()
        await MainActor.run {}  // drains main-queue deliveries enqueued before this hop

        XCTAssertEqual(recorder.success, false)
        XCTAssertEqual(recorder.onMain, true)
        XCTAssertGreaterThan(posts.count, 0, "premise: the parse failure must post .TPPCatalogDidLoad")
        XCTAssertEqual(posts.offMainCount, 0, ".TPPCatalogDidLoad must be posted on main")
    }

    /// Disk cache and background refresh both yield bytes that do not parse: the
    /// cache-load post ran on the caller's queue and the refresh fallback's post on
    /// its Task, matching the second trapping stack.
    func testLoadCatalogs_WhenCachedAndRefreshedBytesDoNotParse_PostsCatalogDidLoadOnMainQueue() async throws {
        let garbage = Data("not json".utf8)
        let loader = makeLoader(store: AccountRegistryStore(),
                                cache: FixedRegistryCache(data: garbage),
                                networking: ScriptedNetworking(body: garbage))
        let posted = expectation(description: "cache load and refresh fallback both posted")
        posted.expectedFulfillmentCount = 2
        posted.assertForOverFulfill = false
        let posts = PostRecorder(onPost: posted)
        let recorder = CompletionRecorder()
        let done = expectation(description: "loadCatalogs completed")
        let box = UncheckedBox(loader)

        DispatchQueue.global(qos: .utility).async {
            box.value.loadCatalogs { @Sendable success in
                recorder.record(success: success, onMain: Thread.isMainThread)
                done.fulfill()
            }
        }
        // The refresh is spawned after the cache load completes, so the join seam alone
        // can run before it exists; the second post is the synchronizer.
        await fulfillment(of: [done, posted], timeout: 10)  // STARVE-001-OK: refresh Tasks are drained on the next line
        await loader._awaitCatalogLoadForTesting()

        XCTAssertEqual(recorder.success, false)
        XCTAssertEqual(recorder.onMain, true)
        XCTAssertEqual(posts.offMainCount, 0, ".TPPCatalogDidLoad must be posted on main")
    }

    // MARK: - Helpers

    private struct LoadResult {
        let success: Bool?
        let applied: Bool?
        let onMain: Bool
    }

    /// Calls `loadAccountSetsAndAuthDoc` from a global queue, as the crawl Tasks do,
    /// and records where the completion ran.
    private func completeFromBackground(
        loader: AccountRegistryLoader,
        data: Data,
        hash: String,
        isCompleteFeed: Bool?
    ) async -> LoadResult {
        let recorder = CompletionRecorder()
        let done = expectation(description: "loadAccountSetsAndAuthDoc completed")
        let box = UncheckedBox(loader)
        DispatchQueue.global(qos: .utility).async {
            box.value.loadAccountSetsAndAuthDoc(
                fromCatalogData: data,
                key: hash,
                isCompleteFeed: isCompleteFeed,
                didApplyBucketWrite: { @Sendable applied in recorder.recordApplied(applied) }
            ) { @Sendable success in
                recorder.record(success: success, onMain: Thread.isMainThread)
                done.fulfill()
            }
        }
        // The completion is a DispatchGroup.notify or a direct call; the injected
        // auth-doc fetch completes synchronously, so there is no Task to join.
        await fulfillment(of: [done], timeout: 10)  // STARVE-001-OK: bounded DispatchGroup.notify, no Task to join
        return LoadResult(success: recorder.success, applied: recorder.applied, onMain: recorder.onMain ?? false)
    }

    private func makeAccounts(_ uuids: [String]) -> [Account] {
        uuids.map {
            Account(publication: OPDS2Publication(links: [], metadata: .init(id: $0, title: $0), images: nil),
                    imageCache: ImageCache.shared)
        }
    }

    /// Built with the production encoder so the bytes decode through the production parser.
    private func feedData(uuids: [String], declaring: Int) throws -> Data {
        try XCTUnwrap(LibraryCatalogMerger.serializeAsCatalogsFeed(
            publications: uuids.map {
                OPDS2Publication(links: [], metadata: .init(id: $0, title: "Library \($0)"), images: nil)
            },
            metadata: OPDS2CatalogsFeed.Metadata(
                adobe_vendor_id: "ThePalaceProject",
                title: "Libraries",
                numberOfItems: declaring
            )
        ))
    }

    private func makeLoader(
        store: AccountRegistryStore,
        cache: any AccountRegistryCaching = FixedRegistryCache(data: nil),
        networking: any AccountNetworking = ScriptedNetworking(body: nil)
    ) -> AccountRegistryLoader {
        let loader = AccountRegistryLoader(
            registryCache: cache,
            registryStore: store,
            crawlScheduler: .production,
            settings: settings,
            imageCache: ImageCache.shared,
            accountStateStore: AccountStateStore(),
            ageCheck: TPPAgeCheck(ageCheckChoiceStorage: settings),
            networkExecutorProvider: { networking },
            currentAccountProvider: { nil },
            currentAccountIdProvider: { nil },
            accountsForKeyProvider: { store.accounts(forKey: $0) },
            accountProvider: { store.account($0) },
            currentUserAccountProvider: { nil },
            driveCurrentAccountAuthDoc: {},
            fetchAuthDocumentWithStateMachine: { _, completion in completion(true) },
            currentLibraryAccountProvider: { nil }
        )
        loader.snapshotResourceResolver = NoBundledSnapshot()
        loader.crawlerFetcher = FailingFetcher()
        return loader
    }
}

// MARK: - Test doubles

private struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

private final class CompletionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _success: Bool?
    private var _applied: Bool?
    private var _onMain: Bool?

    func record(success: Bool, onMain: Bool) {
        lock.withLock { _success = success; _onMain = onMain }
    }
    func recordApplied(_ applied: Bool) { lock.withLock { _applied = applied } }

    var success: Bool? { lock.withLock { _success } }
    var applied: Bool? { lock.withLock { _applied } }
    var onMain: Bool? { lock.withLock { _onMain } }
}

private struct NoBundledSnapshot: BundleResourceResolving {
    func resourceURL(forName name: String, extension ext: String) -> URL? { nil }
}

private struct FailingFetcher: CrawlerNetworkFetching {
    func fetchData(from url: URL) async throws -> (Data, HTTPURLResponse?) {
        throw URLError(.notConnectedToInternet)
    }
}

/// Returns `body` for every GET, or throws when it is nil.
private final class ScriptedNetworking: AccountNetworking, @unchecked Sendable {
    private let body: Data?
    init(body: Data?) { self.body = body }
    func cancelNonEssentialTasks() {}
    func clearCache() {}
    func GET(_ reqURL: URL, useTokenIfAvailable: Bool) async throws -> (Data, URLResponse?) {
        guard let body else { throw URLError(.notConnectedToInternet) }
        return (body, nil)
    }
}

/// Serves `data` as fresh cached bytes for every hash; nil means no cache.
private final class FixedRegistryCache: AccountRegistryCaching, @unchecked Sendable {
    private let data: Data?
    init(data: Data?) { self.data = data }
    func writeCatalogData(_ data: Data, hash: String, isBundled: Bool) {}
    func readCatalogData(hash: String) -> Data? { data }
    func hasFreshCatalogData(hash: String) -> Bool { data != nil }
    func isCatalogStale(hash: String) -> Bool { true }
    func slimSnapshotURL(hash: String) -> URL? { nil }
    func clearFileCaches() {}
}

/// Records the thread of every `.TPPCatalogDidLoad` post while it is alive.
private final class PostRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var threads: [Bool] = []
    private var token: NSObjectProtocol?
    private let onPost: XCTestExpectation?

    init(onPost: XCTestExpectation? = nil) {
        self.onPost = onPost
        token = NotificationCenter.default.addObserver(forName: .TPPCatalogDidLoad, object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            let onMain = Thread.isMainThread
            self.lock.withLock { self.threads.append(onMain) }
            self.onPost?.fulfill()
        }
    }
    deinit { token.map(NotificationCenter.default.removeObserver) }

    var count: Int { lock.withLock { threads.count } }
    var offMainCount: Int { lock.withLock { threads.filter { !$0 }.count } }
}
