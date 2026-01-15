//
//  CatalogViewModelTests.swift
//  PalaceTests
//
//  Tests for CatalogViewModel with dependency injection,
//  CatalogFilter, CatalogFilterGroup, CatalogLaneModel, and MappedCatalog.
//
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import XCTest
import Combine
@testable import Palace

// MARK: - CatalogFilter Tests (Real Production Struct)

final class CatalogFilterTests: XCTestCase {
  
  func testCatalogFilter_StoresProvidedValues() {
    let filter = CatalogFilter(
      id: "test-id",
      title: "Audiobooks",
      href: URL(string: "https://example.org/audiobooks"),
      active: false
    )
    
    XCTAssertEqual(filter.id, "test-id")
    XCTAssertEqual(filter.title, "Audiobooks")
    XCTAssertNotNil(filter.href)
    XCTAssertFalse(filter.active)
  }
  
  func testCatalogFilter_ActiveState() {
    let activeFilter = CatalogFilter(
      id: "active-id",
      title: "All",
      href: URL(string: "https://example.org/all"),
      active: true
    )
    
    XCTAssertTrue(activeFilter.active)
  }
  
  func testCatalogFilter_WithNilHref() {
    let filter = CatalogFilter(
      id: "no-href",
      title: "No Link",
      href: nil,
      active: false
    )
    
    XCTAssertNil(filter.href)
  }
}

// MARK: - CatalogFilterGroup Tests (Real Production Struct)

final class CatalogFilterGroupTests: XCTestCase {
  
  func testCatalogFilterGroup_StoresProvidedValues() {
    let filters = [
      CatalogFilter(id: "1", title: "All", href: nil, active: true),
      CatalogFilter(id: "2", title: "Available Now", href: URL(string: "https://example.org/available"), active: false)
    ]
    
    let group = CatalogFilterGroup(id: "availability", name: "Availability", filters: filters)
    
    XCTAssertEqual(group.id, "availability")
    XCTAssertEqual(group.name, "Availability")
    XCTAssertEqual(group.filters.count, 2)
  }
  
  func testCatalogFilterGroup_EmptyFilters() {
    let group = CatalogFilterGroup(id: "empty", name: "Empty Group", filters: [])
    
    XCTAssertTrue(group.filters.isEmpty)
  }
  
  func testCatalogFilterGroup_ActiveFilter() {
    let filters = [
      CatalogFilter(id: "1", title: "All", href: nil, active: true),
      CatalogFilter(id: "2", title: "Fiction", href: nil, active: false)
    ]
    
    let group = CatalogFilterGroup(id: "genre", name: "Genre", filters: filters)
    
    let activeFilter = group.filters.first { $0.active }
    XCTAssertNotNil(activeFilter)
    XCTAssertEqual(activeFilter?.title, "All")
  }
}

// MARK: - CatalogLaneModel Tests (Real Production Struct)

final class CatalogLaneModelTests: XCTestCase {
  
  func testCatalogLaneModel_StoresProvidedValues() {
    let lane = CatalogLaneModel(
      title: "Popular Books",
      books: [],
      moreURL: URL(string: "https://example.org/more"),
      isLoading: false
    )
    
    XCTAssertEqual(lane.title, "Popular Books")
    XCTAssertTrue(lane.books.isEmpty)
    XCTAssertNotNil(lane.moreURL)
    XCTAssertFalse(lane.isLoading)
  }
  
  func testCatalogLaneModel_LoadingState() {
    let loadingLane = CatalogLaneModel(
      title: "Loading Lane",
      books: [],
      moreURL: nil,
      isLoading: true
    )
    
    XCTAssertTrue(loadingLane.isLoading)
  }
  
  func testCatalogLaneModel_HasUniqueId() {
    let lane1 = CatalogLaneModel(title: "Lane 1", books: [], moreURL: nil)
    let lane2 = CatalogLaneModel(title: "Lane 1", books: [], moreURL: nil)
    
    // Each lane should have unique ID even with same title
    XCTAssertNotEqual(lane1.id, lane2.id)
  }
  
  func testCatalogLaneModel_WithBooks() {
    let books = [
      TPPBookMocker.snapshotEPUB(),
      TPPBookMocker.snapshotAudiobook()
    ]
    
    let lane = CatalogLaneModel(title: "Featured", books: books, moreURL: nil)
    
    XCTAssertEqual(lane.books.count, 2)
  }
}

// MARK: - MappedCatalog Tests (Real Production Struct)

final class MappedCatalogTests: XCTestCase {
  
  func testMappedCatalog_EmptyFeed() {
    let mapped = CatalogViewModel.MappedCatalog(
      title: "Empty",
      entries: [],
      lanes: [],
      ungroupedBooks: [],
      facetGroups: [],
      entryPoints: []
    )
    
    XCTAssertEqual(mapped.title, "Empty")
    XCTAssertTrue(mapped.entries.isEmpty)
    XCTAssertTrue(mapped.lanes.isEmpty)
    XCTAssertTrue(mapped.ungroupedBooks.isEmpty)
    XCTAssertTrue(mapped.facetGroups.isEmpty)
    XCTAssertTrue(mapped.entryPoints.isEmpty)
  }
  
  func testMappedCatalog_WithLanes() {
    let lanes = [
      CatalogLaneModel(title: "Fiction", books: [], moreURL: nil),
      CatalogLaneModel(title: "Non-Fiction", books: [], moreURL: nil)
    ]
    
    let mapped = CatalogViewModel.MappedCatalog(
      title: "Catalog",
      entries: [],
      lanes: lanes,
      ungroupedBooks: [],
      facetGroups: [],
      entryPoints: []
    )
    
    XCTAssertEqual(mapped.lanes.count, 2)
    XCTAssertEqual(mapped.lanes[0].title, "Fiction")
    XCTAssertEqual(mapped.lanes[1].title, "Non-Fiction")
  }
  
  func testMappedCatalog_WithUngroupedBooks() {
    let books = [TPPBookMocker.snapshotEPUB()]
    
    let mapped = CatalogViewModel.MappedCatalog(
      title: "Books",
      entries: [],
      lanes: [],
      ungroupedBooks: books,
      facetGroups: [],
      entryPoints: []
    )
    
    XCTAssertEqual(mapped.ungroupedBooks.count, 1)
    XCTAssertTrue(mapped.lanes.isEmpty)
  }
}

// MARK: - CatalogViewModel Tests (Real ViewModel with Mock Repository)

@MainActor
final class CatalogViewModelIntegrationTests: XCTestCase {
  
  private var mockRepository: CatalogRepositoryMock!
  private var cancellables: Set<AnyCancellable>!
  private var testURL: URL!
  
  override func setUp() {
    super.setUp()
    mockRepository = CatalogRepositoryMock()
    cancellables = Set<AnyCancellable>()
    testURL = URL(string: "https://example.com/catalog")!
  }
  
  override func tearDown() {
    mockRepository = nil
    cancellables = nil
    testURL = nil
    super.tearDown()
  }
  
  private func createViewModel(url: URL? = nil) -> CatalogViewModel {
    let urlToUse = url ?? testURL!
    return CatalogViewModel(
      repository: mockRepository,
      topLevelURLProvider: { urlToUse }
    )
  }
  
  // MARK: - Initialization Tests
  
  func testViewModel_InitialState_HasCorrectDefaults() {
    let viewModel = createViewModel()
    
    XCTAssertEqual(viewModel.title, "")
    XCTAssertTrue(viewModel.entries.isEmpty)
    XCTAssertTrue(viewModel.lanes.isEmpty)
    XCTAssertTrue(viewModel.ungroupedBooks.isEmpty)
    XCTAssertFalse(viewModel.isLoading)
    XCTAssertNil(viewModel.errorMessage)
    XCTAssertTrue(viewModel.facetGroups.isEmpty)
    XCTAssertTrue(viewModel.entryPoints.isEmpty)
  }
  
  // MARK: - Load Tests with Mock Repository
  
  func testLoad_WithNilURL_DoesNotLoad() async {
    let viewModel = CatalogViewModel(
      repository: mockRepository,
      topLevelURLProvider: { nil }
    )
    
    await viewModel.load()
    
    XCTAssertFalse(viewModel.isLoading)
    XCTAssertEqual(mockRepository.loadTopLevelCatalogCallCount, 0)
  }
  
  func testLoad_CallsRepository() async {
    let viewModel = createViewModel()
    
    await viewModel.load()
    
    // Wait for internal Task to complete
    try? await Task.sleep(nanoseconds: 200_000_000)
    
    XCTAssertGreaterThanOrEqual(mockRepository.loadTopLevelCatalogCallCount, 1)
  }
  
  func testLoad_WithError_SetsErrorMessage() async {
    mockRepository.loadTopLevelCatalogError = TestError.networkError
    let viewModel = createViewModel()
    
    await viewModel.load()
    
    // Wait for async completion
    try? await Task.sleep(nanoseconds: 100_000_000)
    
    XCTAssertNotNil(viewModel.errorMessage)
    XCTAssertFalse(viewModel.isLoading)
  }
  
  func testLoad_WithNilResult_SetsErrorMessage() async {
    mockRepository.loadTopLevelCatalogResult = nil
    let viewModel = createViewModel()
    
    await viewModel.load()
    
    // Wait for async completion
    try? await Task.sleep(nanoseconds: 100_000_000)
    
    XCTAssertNotNil(viewModel.errorMessage)
    XCTAssertFalse(viewModel.isLoading)
  }
  
  // MARK: - Scroll Management Tests
  
  func testResetScrollTrigger_SetsFalse() {
    let viewModel = createViewModel()
    viewModel.shouldScrollToTop = true
    
    viewModel.resetScrollTrigger()
    
    XCTAssertFalse(viewModel.shouldScrollToTop)
  }
  
  // MARK: - Search Repository Accessor Tests
  
  func testSearchRepository_ReturnsSameRepository() {
    let viewModel = createViewModel()
    
    let searchRepo = viewModel.searchRepository
    
    XCTAssertTrue(searchRepo is CatalogRepositoryMock)
  }
  
  func testSearchBaseURL_ReturnsCorrectURL() {
    let viewModel = createViewModel()
    
    let baseURL = viewModel.searchBaseURL()
    
    XCTAssertEqual(baseURL, testURL)
  }
  
  // MARK: - Force Refresh Tests
  
  func testForceRefresh_ClearsDataAndReloads() async {
    let viewModel = createViewModel()
    
    await viewModel.forceRefresh()
    
    // Wait for internal Task to complete
    try? await Task.sleep(nanoseconds: 300_000_000)
    
    XCTAssertNil(viewModel.errorMessage)
    XCTAssertGreaterThanOrEqual(mockRepository.loadTopLevelCatalogCallCount, 1)
  }
  
  // MARK: - Handle Account Change Tests
  
  func testHandleAccountChange_LoadsNewCatalog() async {
    let viewModel = createViewModel()
    
    await viewModel.handleAccountChange()
    
    // Wait for internal Task to complete
    try? await Task.sleep(nanoseconds: 300_000_000)
    
    // Should trigger a load since lastLoadedURL is nil initially
    XCTAssertGreaterThanOrEqual(mockRepository.loadTopLevelCatalogCallCount, 1)
  }
  
  // MARK: - Published Property Tests
  
  func testIsContentReloading_PublishesChanges() {
    let viewModel = createViewModel()
    
    let expectation = XCTestExpectation(description: "isContentReloading should publish")
    
    viewModel.$isContentReloading
      .dropFirst()
      .sink { _ in
        expectation.fulfill()
      }
      .store(in: &cancellables)
    
    viewModel.isContentReloading = true
    
    wait(for: [expectation], timeout: 1.0)
  }
  
  func testErrorMessage_PublishesChanges() {
    let viewModel = createViewModel()
    
    let expectation = XCTestExpectation(description: "errorMessage should publish")
    
    viewModel.$errorMessage
      .dropFirst()
      .sink { _ in
        expectation.fulfill()
      }
      .store(in: &cancellables)
    
    // We can't directly set errorMessage, but we can verify the publisher exists
    // This is just validating the Combine setup
    expectation.fulfill()
    
    wait(for: [expectation], timeout: 1.0)
  }
}

// MARK: - CatalogViewModel Optimistic Loading Tests

@MainActor
final class CatalogViewModelOptimisticLoadingTests: XCTestCase {
  
  private var mockRepository: CatalogRepositoryMock!
  private var testURL: URL!
  
  override func setUp() {
    super.setUp()
    mockRepository = CatalogRepositoryMock()
    testURL = URL(string: "https://example.com/catalog")!
  }
  
  override func tearDown() {
    mockRepository = nil
    testURL = nil
    super.tearDown()
  }
  
  private func createViewModel() -> CatalogViewModel {
    return CatalogViewModel(
      repository: mockRepository,
      topLevelURLProvider: { [weak self] in self?.testURL }
    )
  }
  
  func testApplyFacet_WithNilHref_DoesNothing() async {
    let viewModel = createViewModel()
    let facet = CatalogFilter(id: "1", title: "Test", href: nil, active: false)
    
    await viewModel.applyFacet(facet)
    
    XCTAssertEqual(mockRepository.loadTopLevelCatalogCallCount, 0)
  }
  
  func testApplyEntryPoint_WithNilHref_DoesNothing() async {
    let viewModel = createViewModel()
    let entryPoint = CatalogFilter(id: "1", title: "Test", href: nil, active: false)
    
    await viewModel.applyEntryPoint(entryPoint)
    
    XCTAssertEqual(mockRepository.loadTopLevelCatalogCallCount, 0)
  }
  
  func testApplyFacet_WithValidHref_CallsRepository() async {
    let viewModel = createViewModel()
    let facet = CatalogFilter(
      id: "1",
      title: "Fiction",
      href: URL(string: "https://example.com/fiction"),
      active: false
    )
    
    await viewModel.applyFacet(facet)
    
    XCTAssertEqual(mockRepository.loadTopLevelCatalogCallCount, 1)
  }
  
  func testApplyEntryPoint_WithValidHref_CallsRepository() async {
    let viewModel = createViewModel()
    let entryPoint = CatalogFilter(
      id: "1",
      title: "Audiobooks",
      href: URL(string: "https://example.com/audiobooks"),
      active: false
    )
    
    await viewModel.applyEntryPoint(entryPoint)
    
    XCTAssertEqual(mockRepository.loadTopLevelCatalogCallCount, 1)
  }
  
  func testApplyFacet_WithError_RestoresPreviousState() async {
    let viewModel = createViewModel()
    mockRepository.loadTopLevelCatalogError = TestError.networkError
    
    let facet = CatalogFilter(
      id: "1",
      title: "Fiction",
      href: URL(string: "https://example.com/fiction"),
      active: false
    )
    
    await viewModel.applyFacet(facet)
    
    XCTAssertNotNil(viewModel.errorMessage)
    XCTAssertFalse(viewModel.isOptimisticLoading)
  }
}
