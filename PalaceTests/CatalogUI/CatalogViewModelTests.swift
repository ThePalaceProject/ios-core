import XCTest
import Combine
import PalaceCatalog
@testable import Palace

// MARK: - CatalogState Tests

final class CatalogStateTests: XCTestCase {

    func testState_Loading_HasNoContent() {
        let state = CatalogState.loading
        XCTAssertNil(state.content)
        XCTAssertNil(state.title)
        XCTAssertTrue(state.allBooks.isEmpty)
        XCTAssertFalse(state.isApplyingFacet)
    }

    func testState_Error_HasNoContent() {
        let state = CatalogState.error("Network failed")
        XCTAssertNil(state.content)
        XCTAssertTrue(state.allBooks.isEmpty)
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
final class CatalogViewModelStateMachineTests: XCTestCase {

    private var mockRepository: CatalogRepositoryMock!
    private var cancellables: Set<AnyCancellable>!
    private let testURL = URL(string: "https://example.com/catalog")!

    override func setUp() {
        super.setUp()
        mockRepository = CatalogRepositoryMock()
        cancellables = []
    }

    override func tearDown() {
        mockRepository = nil
        cancellables = nil
        super.tearDown()
    }

    private func createViewModel() -> CatalogViewModel {
        CatalogViewModel(
            repository: mockRepository,
            topLevelURLProvider: { [testURL] in testURL },
            bookRegistry: AppContainer.production().bookRegistry,
            imageCache: ImageCache.shared
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
            bookRegistry: AppContainer.production().bookRegistry,
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
        await fulfillment(of: [exp], timeout: 1.0)
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
        await fulfillment(of: [exp], timeout: 1.0)
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
        await fulfillment(of: [exp], timeout: 1.0)
        XCTAssertGreaterThanOrEqual(mockRepository.loadTopLevelCatalogCallCount, 1,
                                    "forceRefresh must invoke the repository at least once")
    }
}

// MARK: - Model Tests

final class CatalogFilterTests: XCTestCase {
    func testCatalogFilter_StoresValues() {
        let f = CatalogFilter(id: "t", title: "Audiobooks", href: URL(string: "https://a.com"), active: false)
        XCTAssertEqual(f.id, "t")
        XCTAssertFalse(f.active)
    }
}

final class CatalogLaneModelTests: XCTestCase {
    func testHasUniqueId() {
        let l1 = CatalogLaneModel(title: "L", books: [], moreURL: nil)
        let l2 = CatalogLaneModel(title: "L", books: [], moreURL: nil)
        XCTAssertNotEqual(l1.id, l2.id)
    }
}
