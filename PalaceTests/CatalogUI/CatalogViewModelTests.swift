import XCTest
import Combine
import PalaceCatalog
import PalaceNetwork
@testable import Palace

// Offline/reconnect branching (PP-4578) is driven by the shared
// `MockReachability` test double (PalaceTests/Mocks/MockReachability.swift).

// MARK: - CatalogState Tests

@MainActor
final class CatalogStateTests: XCTestCase {

    func testState_Loading_HasNoContent() {
        let state = CatalogState.loading
        XCTAssertNil(state.content)
        XCTAssertNil(state.title)
        XCTAssertTrue(state.allBooks.isEmpty)
        XCTAssertFalse(state.isApplyingFacet)
    }

    func testState_Error_HasNoContent() {
        let state = CatalogState.error("Network failed", sideloadedLanes: [])
        XCTAssertNil(state.content)
        XCTAssertTrue(state.allBooks.isEmpty)
        XCTAssertTrue(state.sideloadedLanes.isEmpty)
    }

    func testState_Loaded_ExposesContent() {
        let books = [TPPBookMocker.snapshotEPUB()]
        let content = CatalogContent(
            title: "Test Library",
            feed: .grouped([CatalogLaneModel(title: "Lane", books: books, moreURL: nil)]),
            selectors: .empty
        )
        let state = CatalogState.loaded(content)
        XCTAssertEqual(state.title, "Test Library")
        XCTAssertEqual(state.allBooks.count, 1)
        XCTAssertFalse(state.isApplyingFacet)
    }

    func testState_ApplyingFacet_IsTrue() {
        let content = CatalogContent(title: "T", feed: .empty, selectors: .empty)
        XCTAssertTrue(CatalogState.applyingFacet(content).isApplyingFacet)
    }

    func testState_SwitchingEntryPoint_HasNoContent() {
        let selectors = CatalogSelectors(
            entryPoints: [CatalogFilter(id: "1", title: "All", href: nil, active: true)],
            facetGroups: []
        )
        XCTAssertNil(CatalogState.switchingEntryPoint(selectors).content)
    }

    func testState_AllBooks_Grouped() {
        let lanes = [
            CatalogLaneModel(title: "L1", books: [TPPBookMocker.snapshotEPUB()], moreURL: nil),
            CatalogLaneModel(title: "L2", books: [TPPBookMocker.snapshotAudiobook()], moreURL: nil)
        ]
        let state = CatalogState.loaded(CatalogContent(title: "T", feed: .grouped(lanes), selectors: .empty))
        XCTAssertEqual(state.allBooks.count, 2)
    }

    func testState_AllBooks_Ungrouped() {
        let books = [TPPBookMocker.snapshotEPUB(), TPPBookMocker.snapshotAudiobook()]
        let state = CatalogState.loaded(CatalogContent(title: "T", feed: .ungrouped(books), selectors: .empty))
        XCTAssertEqual(state.allBooks.count, 2)
    }
}

// MARK: - CatalogSelectors Tests

@MainActor
final class CatalogSelectorsTests: XCTestCase {

    func testWithSelectedFacet_UpdatesActiveState() {
        let filters = [
            CatalogFilter(id: "1", title: "All", href: nil, active: true),
            CatalogFilter(id: "2", title: "Fiction", href: nil, active: false)
        ]
        let selectors = CatalogSelectors(
            entryPoints: [],
            facetGroups: [CatalogFilterGroup(id: "g", name: "Genre", filters: filters)]
        )
        let updated = selectors.withSelectedFacet(CatalogFilter(id: "2", title: "Fiction", href: nil, active: false))
        XCTAssertFalse(updated.facetGroups[0].filters[0].active)
        XCTAssertTrue(updated.facetGroups[0].filters[1].active)
    }

    func testWithSelectedEntryPoint_UpdatesActiveState() {
        let selectors = CatalogSelectors(
            entryPoints: [
                CatalogFilter(id: "1", title: "All", href: URL(string: "https://a.com/all"), active: true),
                CatalogFilter(id: "2", title: "Ebooks", href: URL(string: "https://a.com/ebooks"), active: false)
            ],
            facetGroups: []
        )
        let updated = selectors.withSelectedEntryPoint(
            CatalogFilter(id: "2", title: "Ebooks", href: URL(string: "https://a.com/ebooks"), active: false)
        )
        XCTAssertFalse(updated.entryPoints[0].active)
        XCTAssertTrue(updated.entryPoints[1].active)
    }
}

// MARK: - MappedCatalog Bridge Tests

@MainActor
final class MappedCatalogBridgeTests: XCTestCase {

    func testToCatalogContent_GroupedFeed() {
        let mapped = CatalogViewModel.MappedCatalog(
            title: "Library", entries: [],
            lanes: [CatalogLaneModel(title: "Lane", books: [], moreURL: nil)],
            ungroupedBooks: [], facetGroups: [], entryPoints: []
        )
        let content = mapped.toCatalogContent()
        XCTAssertEqual(content.title, "Library")
        if case .grouped(let lanes) = content.feed { XCTAssertEqual(lanes.count, 1) }
        else { XCTFail("Expected .grouped") }
    }

    func testToCatalogContent_UngroupedFeed() {
        let mapped = CatalogViewModel.MappedCatalog(
            title: "Books", entries: [], lanes: [],
            ungroupedBooks: [TPPBookMocker.snapshotEPUB()],
            facetGroups: [], entryPoints: []
        )
        if case .ungrouped(let books) = mapped.toCatalogContent().feed { XCTAssertEqual(books.count, 1) }
        else { XCTFail("Expected .ungrouped") }
    }

    func testToCatalogContent_EmptyFeed() {
        let mapped = CatalogViewModel.MappedCatalog(
            title: "E", entries: [], lanes: [], ungroupedBooks: [],
            facetGroups: [], entryPoints: []
        )
        if case .empty = mapped.toCatalogContent().feed { } else { XCTFail("Expected .empty") }
    }
}

// MARK: - CatalogViewModel State Machine Tests

@MainActor
final class CatalogViewModelStateMachineTests: PalaceTestCase {

    private var mockRepository: CatalogRepositoryMock!
    // Isolated mock registry — replaces `AppContainer.production().bookRegistry`,
    // which built the whole production graph (incl. a live `AccountsManager`
    // whose init enqueues the un-cancellable auth-doc main-hop that polluted
    // later Accounts tests). GAP 3 of the test-pollution root-fix.
    private var bookRegistry: TPPBookRegistryMock!
    private var cancellables: Set<AnyCancellable>!
    private let testURL = URL(string: "https://example.com/catalog")!

    // NOTE: sync `setUp()`/`tearDown()` (not the `WithError` variants) because
    // `CatalogRepositoryMock` + `TPPBookRegistryMock` inits are `@MainActor` and
    // the sync hooks are main-actor-isolated. `PalaceTestCase`'s inherited
    // `setUpWithError`/`tearDownWithError` still run automatically (XCTest invokes
    // both), so the runtime-quiescence floor is active without us overriding it.
    override func setUp() {
        super.setUp()
        mockRepository = CatalogRepositoryMock()
        bookRegistry = TPPBookRegistryMock()
        cancellables = []
    }

    override func tearDown() {
        mockRepository = nil
        bookRegistry = nil
        cancellables = nil
        super.tearDown()
    }

    /// Inject a deterministic reachability so the offline-vs-error decision does
    /// not depend on the test host's live network (PP-4578). Defaults to
    /// connected so pre-existing error-path tests keep asserting `.error`.
    private func createViewModel(reachability: Reachability = MockReachability(initiallyConnected: true)) -> CatalogViewModel {
        CatalogViewModel(
            repository: mockRepository,
            topLevelURLProvider: { [testURL] in testURL },
            bookRegistry: bookRegistry,
            imageCache: ImageCache.shared,
            reachability: reachability
        )
    }

    func testViewModel_InitialState_IsLoading() {
        let vm = createViewModel()
        if case .loading = vm.state { } else { XCTFail("Expected .loading") }
        XCTAssertEqual(vm.scrollGeneration, 0)
    }

    func testLoad_WithNilURL_DoesNotCallRepository() async {
        let vm = CatalogViewModel(
            repository: mockRepository,
            topLevelURLProvider: { nil },
            bookRegistry: bookRegistry,
            imageCache: ImageCache.shared
        )
        await vm.load()
        XCTAssertEqual(mockRepository.loadTopLevelCatalogCallCount, 0)
    }

    func testLoad_WithError_TransitionsToError() async {
        mockRepository.loadTopLevelCatalogError = NSError(domain: "test", code: 1)
        let vm = createViewModel()
        let exp = XCTestExpectation(description: "error")
        vm.$state.sink { if case .error = $0 { exp.fulfill() } }.store(in: &cancellables)
        await vm.load()
        // 5s timeout: load() spawns currentLoadTask but does NOT await it,
        // so the @Published state transition lands when the Task gets
        // scheduled. The 1-second window flaked under macos-26 CI load
        // (testLoad_WithError saw a timeout in PR #889 CI). 5s matches
        // drainMainQueue/awaitCondition defaults — generous in CI without
        // hiding a real hang.
        await fulfillment(of: [exp], timeout: 5.0)
        guard case .error = vm.state else {
            return XCTFail("Expected .error state after load failure, got \(vm.state)")
        }
    }

    func testLoad_WithNilResult_TransitionsToError() async {
        mockRepository.loadTopLevelCatalogResult = nil
        let vm = createViewModel()
        let exp = XCTestExpectation(description: "error")
        vm.$state.sink { if case .error = $0 { exp.fulfill() } }.store(in: &cancellables)
        await vm.load()
        // 5s timeout: load() spawns currentLoadTask but does NOT await it,
        // so the @Published state transition lands when the Task gets
        // scheduled. The 1-second window flaked under macos-26 CI load
        // (testLoad_WithError saw a timeout in PR #889 CI). 5s matches
        // drainMainQueue/awaitCondition defaults — generous in CI without
        // hiding a real hang.
        await fulfillment(of: [exp], timeout: 5.0)
        guard case .error = vm.state else {
            return XCTFail("Expected .error state after nil result, got \(vm.state)")
        }
    }

    func testSearchRepository_ReturnsMock() {
        let vm = createViewModel()
        XCTAssertTrue(vm.searchRepository is CatalogRepositoryMock)
        XCTAssertEqual(vm.searchBaseURL(), testURL)
    }

    func testApplyFacet_WithNilHref_NoOp() async {
        let vm = createViewModel()
        await vm.applyFacet(CatalogFilter(id: "1", title: "T", href: nil, active: false))
        XCTAssertEqual(mockRepository.loadTopLevelCatalogCallCount, 0)
    }

    func testApplyFacet_RequiresLoadedState() async {
        let vm = createViewModel()
        await vm.applyFacet(CatalogFilter(id: "1", title: "F", href: URL(string: "https://a.com"), active: false))
        XCTAssertEqual(mockRepository.loadTopLevelCatalogCallCount, 0)
    }

    func testApplyEntryPoint_WithNilHref_NoOp() async {
        let vm = createViewModel()
        await vm.applyEntryPoint(CatalogFilter(id: "1", title: "T", href: nil, active: false))
        XCTAssertEqual(mockRepository.loadTopLevelCatalogCallCount, 0)
    }

    func testApplyEntryPoint_RequiresLoadedState() async {
        let vm = createViewModel()
        await vm.applyEntryPoint(CatalogFilter(id: "1", title: "A", href: URL(string: "https://a.com"), active: false))
        XCTAssertEqual(mockRepository.loadTopLevelCatalogCallCount, 0)
    }

    func testForceRefresh_TransitionsToLoading() async {
        let vm = createViewModel()
        let exp = XCTestExpectation(description: "loading")
        vm.$state.sink { if case .loading = $0 { exp.fulfill() } }.store(in: &cancellables)
        await vm.forceRefresh()
        // 5s timeout: load() spawns currentLoadTask but does NOT await it,
        // so the @Published state transition lands when the Task gets
        // scheduled. The 1-second window flaked under macos-26 CI load
        // (testLoad_WithError saw a timeout in PR #889 CI). 5s matches
        // drainMainQueue/awaitCondition defaults — generous in CI without
        // hiding a real hang.
        await fulfillment(of: [exp], timeout: 5.0)
        XCTAssertGreaterThanOrEqual(mockRepository.loadTopLevelCatalogCallCount, 1,
                                    "forceRefresh must invoke the repository at least once")
    }

    // MARK: - Offline State (PP-4578)

    func testLoad_WhenOffline_TransitionsToOffline() async {
        mockRepository.loadTopLevelCatalogError = NSError(domain: "test", code: -1009)
        let vm = createViewModel(reachability: MockReachability(initiallyConnected: false))
        let exp = XCTestExpectation(description: "offline")
        vm.$state.sink { if case .offline = $0 { exp.fulfill() } }.store(in: &cancellables)
        await vm.load()
        await fulfillment(of: [exp], timeout: 5.0)
        guard case .offline = vm.state else {
            return XCTFail("Expected .offline state when load fails with no connectivity, got \(vm.state)")
        }
    }

    func testLoad_NilResultWhenOffline_TransitionsToOffline() async {
        mockRepository.loadTopLevelCatalogResult = nil
        let vm = createViewModel(reachability: MockReachability(initiallyConnected: false))
        let exp = XCTestExpectation(description: "offline")
        vm.$state.sink { if case .offline = $0 { exp.fulfill() } }.store(in: &cancellables)
        await vm.load()
        await fulfillment(of: [exp], timeout: 5.0)
        guard case .offline = vm.state else {
            return XCTFail("Expected .offline state on nil result with no connectivity, got \(vm.state)")
        }
    }

    func testLoad_OnlineFailure_StaysError_NotOffline() async {
        // AC: genuine online load failures keep the existing error + Reload behavior.
        mockRepository.loadTopLevelCatalogError = NSError(domain: "test", code: 500)
        let vm = createViewModel(reachability: MockReachability(initiallyConnected: true))
        let exp = XCTestExpectation(description: "error")
        vm.$state.sink { if case .error = $0 { exp.fulfill() } }.store(in: &cancellables)
        await vm.load()
        await fulfillment(of: [exp], timeout: 5.0)
        guard case .error = vm.state else {
            return XCTFail("Expected .error (not .offline) when failing while connected, got \(vm.state)")
        }
    }

    func testReconnect_WhileOffline_AutoReloadsCatalog() async {
        // AC: when connectivity is restored, the catalog reloads automatically.
        mockRepository.loadTopLevelCatalogError = NSError(domain: "test", code: -1009)
        let reachability = MockReachability(initiallyConnected: false)
        let vm = createViewModel(reachability: reachability)

        let offlineExp = XCTestExpectation(description: "offline")
        vm.$state.sink { if case .offline = $0 { offlineExp.fulfill() } }.store(in: &cancellables)
        await vm.load()
        await fulfillment(of: [offlineExp], timeout: 5.0)
        let callsWhileOffline = mockRepository.loadTopLevelCatalogCallCount

        // Reconnecting must trigger a fresh load attempt without any Reload tap.
        let reloadExp = XCTestExpectation(description: "reload")
        vm.$state.dropFirst().sink { if case .loading = $0 { reloadExp.fulfill() } }.store(in: &cancellables)
        reachability.simulate(connected: true)
        await fulfillment(of: [reloadExp], timeout: 5.0)

        // Give the spawned load task a moment to re-hit the repository.
        let deadline = Date().addingTimeInterval(5.0)
        while mockRepository.loadTopLevelCatalogCallCount <= callsWhileOffline, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertGreaterThan(mockRepository.loadTopLevelCatalogCallCount, callsWhileOffline,
                             "Reconnect must auto-reload the catalog (repository re-invoked)")
    }

    // MARK: - Prefetch Cancellation (catalog "stuck state" load multiplier)

    /// `cancelPrefetch()` must both cancel the tracked tasks AND clear the list,
    /// so stale cover prefetch can't keep saturating the network after the
    /// patron leaves a feed.
    func testCancelPrefetch_cancelsAndClearsTrackedTasks() async {
        let vm = createViewModel()
        let flag = PrefetchCancelFlag()
        let started = XCTestExpectation(description: "prefetch started")
        let synthetic = Task<Void, Never> {
            started.fulfill()
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 10_000_000) }
            await flag.markCancelled()
        }
        vm.appendPrefetchTaskForTesting(synthetic)
        XCTAssertEqual(vm.prefetchTaskCountForTesting, 1)
        await fulfillment(of: [started], timeout: 2.0)

        vm.cancelPrefetchForTesting()
        XCTAssertEqual(vm.prefetchTaskCountForTesting, 0, "cancelPrefetch must clear tracked tasks")

        _ = await synthetic.value
        let wasCancelled = await flag.value
        XCTAssertTrue(wasCancelled, "Tracked prefetch tasks must actually be cancelled")
    }

    /// A reload must cancel any prefetch left over from the previous feed.
    /// `loadTopLevelCatalogResult = nil` makes the new load fail fast so it
    /// appends no new prefetch, keeping the assertion deterministic.
    func testReload_cancelsPriorPrefetchTasks() async {
        mockRepository.loadTopLevelCatalogResult = nil
        let vm = createViewModel()
        let synthetic = Task<Void, Never> {
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 10_000_000) }
        }
        vm.appendPrefetchTaskForTesting(synthetic)
        XCTAssertEqual(vm.prefetchTaskCountForTesting, 1)

        await vm.forceRefresh()

        XCTAssertEqual(vm.prefetchTaskCountForTesting, 0, "Reload must cancel + clear prior prefetch tasks")
        _ = await synthetic.value
        XCTAssertTrue(synthetic.isCancelled, "Prior prefetch must be cancelled on reload")
    }

    // MARK: - Library-switch SWR + de-triple-fire (swarm_27c181b5 A1)

    /// A library switch must serve the new library's account-scoped cache
    /// instantly (stale-while-revalidate). It must NOT invalidate — invalidating
    /// on every switch is exactly the triple-fire the SWR change removes.
    func testHandleAccountChange_servesCache_doesNotInvalidate() async {
        mockRepository.loadTopLevelCatalogResult = Self.makeGroupedCatalogFeed()
        let vm = createViewModel() // fresh VM: lastLoadedURL == nil so the switch reloads
        await vm.handleAccountChange()
        await waitUntilLoaded(vm, at: testURL)

        XCTAssertEqual(mockRepository.invalidateCacheCallCount, 0,
                       "handleAccountChange must serve the account-scoped cache (SWR) without invalidating")
        guard case .loaded = vm.state else {
            return XCTFail("Expected .loaded after account change, got \(vm.state)")
        }
    }

    /// Pull-to-refresh is the ONE path that invalidates: it drops the current
    /// URL's cache entry exactly once so the reload is guaranteed to hit the
    /// network.
    func testRefresh_pullToRefresh_invalidatesOnce() async {
        mockRepository.loadTopLevelCatalogResult = Self.makeGroupedCatalogFeed()
        let vm = createViewModel()
        await vm.refresh()
        await waitUntilLoaded(vm, at: testURL)

        XCTAssertEqual(mockRepository.invalidateCacheCallCount, 1,
                       "pull-to-refresh must invalidate the cache exactly once")
        XCTAssertEqual(mockRepository.lastInvalidatedURL, testURL,
                       "pull-to-refresh must invalidate the current top-level URL")
    }

    /// A → B → A library switch must not re-fetch A on the way back: because a
    /// switch never invalidates, A's cache stays warm and is served instantly.
    /// Drives all three legs through the production seam (`load` +
    /// `handleAccountChange`) and asserts A's network-fetch count does not grow
    /// on return — the concrete de-triple-fire win.
    func testSwitchBackAndForth_ABA_servesCacheNotThreeFetches() async {
        let urlA = URL(string: "https://library-a.example.com/catalog")!
        let urlB = URL(string: "https://library-b.example.com/catalog")!
        mockRepository.simulatesCache = true
        mockRepository.loadTopLevelCatalogResult = Self.makeGroupedCatalogFeed()

        var currentURL = urlA
        let vm = CatalogViewModel(
            repository: mockRepository,
            topLevelURLProvider: { currentURL },
            bookRegistry: bookRegistry,
            imageCache: ImageCache.shared,
            reachability: MockReachability(initiallyConnected: true)
        )

        // Leg 1 — load library A (cache miss → 1 network fetch for A).
        await vm.load()
        await waitUntilLoaded(vm, at: urlA)
        XCTAssertEqual(mockRepository.networkFetchCount(for: urlA), 1)

        // Leg 2 — switch A → B (cache miss → 1 network fetch for B).
        currentURL = urlB
        await vm.handleAccountChange()
        await waitUntilLoaded(vm, at: urlB)
        XCTAssertEqual(mockRepository.networkFetchCount(for: urlB), 1)

        // Leg 3 — switch B → A. A was never invalidated, so it is served from
        // the warm cache: A's network-fetch count must stay at 1.
        currentURL = urlA
        await vm.handleAccountChange()
        await waitUntilLoaded(vm, at: urlA)

        XCTAssertEqual(mockRepository.networkFetchCount(for: urlA), 1,
                       "Returning to library A must serve the warm cache, not trigger a second fetch")
        XCTAssertEqual(mockRepository.invalidateCacheCallCount, 0,
                       "No library switch may invalidate the account-scoped cache (SWR)")
    }

    // MARK: - SWR test helpers

    /// Poll until the view model reaches `.loaded` for `url`. `load()` spawns
    /// `currentLoadTask` without awaiting it, so the `@Published` transition
    /// lands asynchronously; `activeEntryPointURL` is set to the loaded URL on
    /// the success path, giving a per-leg completion signal for the A→B→A drive.
    private func waitUntilLoaded(
        _ vm: CatalogViewModel,
        at url: URL,
        timeout: TimeInterval = 5.0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if case .loaded = vm.state, vm.activeEntryPointURL == url { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for .loaded at \(url); state=\(vm.state), active=\(String(describing: vm.activeEntryPointURL))",
                file: file, line: line)
    }

    /// Minimal real OPDS 2 grouped `CatalogFeed` (one lane, one book) so
    /// `load()` maps to `.loaded` and exercises the real success path rather
    /// than an error/offline branch.
    private static func makeGroupedCatalogFeed(title: String = "Library") -> CatalogFeed {
        let publication = OPDS2Publication(
            links: [
                OPDS2Link(
                    href: "https://example.com/borrow/0",
                    type: "application/epub+zip",
                    rel: "http://opds-spec.org/acquisition/borrow"
                )
            ],
            metadata: OPDS2Publication.Metadata(
                updated: Date(),
                description: nil,
                id: "pub-0",
                title: "Book 0"
            ),
            images: nil
        )
        let group = OPDS2Group(
            metadata: OPDS2GroupMetadata(title: "Group 0"),
            links: [OPDS2Link(href: "https://example.com/group/0", rel: "subsection")],
            publications: [publication]
        )
        let opds2 = OPDS2Feed(
            metadata: OPDS2FeedMetadata(title: title),
            links: [],
            groups: [group]
        )
        return CatalogFeed(opds2Feed: opds2)
    }
}

/// Test-only observer for prefetch-cancellation assertions.
private actor PrefetchCancelFlag {
    private(set) var value = false
    func markCancelled() { value = true }
}

// MARK: - Model Tests

@MainActor
final class CatalogFilterTests: XCTestCase {
    func testCatalogFilter_StoresValues() {
        let f = CatalogFilter(id: "t", title: "Audiobooks", href: URL(string: "https://a.com"), active: false)
        XCTAssertEqual(f.id, "t")
        XCTAssertFalse(f.active)
    }
}

@MainActor
final class CatalogLaneModelTests: XCTestCase {
    func testHasUniqueId() {
        let l1 = CatalogLaneModel(title: "L", books: [], moreURL: nil)
        let l2 = CatalogLaneModel(title: "L", books: [], moreURL: nil)
        XCTAssertNotEqual(l1.id, l2.id)
    }
}
