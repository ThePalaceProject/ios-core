//
//  CatalogLaneMoreViewModelTests.swift
//  PalaceTests
//
//  Tests for CatalogLaneMoreViewModel which manages catalog feed loading and filtering.
//

import XCTest
import Combine
@testable import Palace

@MainActor
final class CatalogLaneMoreViewModelTests: XCTestCase {
  
  private var cancellables: Set<AnyCancellable> = []
  
  override func setUp() {
    super.setUp()
    cancellables = []
  }
  
  override func tearDown() {
    cancellables.removeAll()
    super.tearDown()
  }
  
  // MARK: - Helper
  
  private func createViewModel(title: String = "Test", urlString: String = "https://example.com/feed") -> CatalogLaneMoreViewModel {
    let url = URL(string: urlString)!
    return CatalogLaneMoreViewModel(title: title, url: url)
  }
  
  // MARK: - Initialization Tests
  
  func testInitialState() {
    let viewModel = createViewModel(title: "Featured Books")
    
    XCTAssertEqual(viewModel.title, "Featured Books")
    XCTAssertTrue(viewModel.lanes.isEmpty)
    XCTAssertTrue(viewModel.ungroupedBooks.isEmpty)
    XCTAssertTrue(viewModel.isLoading, "Should start in loading state")
    XCTAssertNil(viewModel.error)
    XCTAssertNil(viewModel.nextPageURL)
    XCTAssertFalse(viewModel.isLoadingMore)
  }
  
  func testUIStateInitialValues() {
    let viewModel = createViewModel()
    
    XCTAssertFalse(viewModel.showingSortSheet)
    XCTAssertFalse(viewModel.showingFiltersSheet)
    XCTAssertFalse(viewModel.showSearch)
  }
  
  func testFilterStateInitialValues() {
    let viewModel = createViewModel()
    
    XCTAssertTrue(viewModel.facetGroups.isEmpty)
    XCTAssertTrue(viewModel.pendingSelections.isEmpty)
    XCTAssertTrue(viewModel.appliedSelections.isEmpty)
    XCTAssertFalse(viewModel.isApplyingFilters)
  }
  
  // MARK: - Computed Properties Tests
  
  func testActiveFiltersCount_WhenEmpty() {
    let viewModel = createViewModel()
    
    XCTAssertEqual(viewModel.activeFiltersCount, 0)
  }
  
  func testAllBooks_WhenLanesEmpty_ReturnsUngroupedBooks() async {
    let viewModel = createViewModel()
    
    // Simulate having ungrouped books
    viewModel.ungroupedBooks = [
      TPPBookMocker.mockBook(identifier: "book1", title: "Book 1"),
      TPPBookMocker.mockBook(identifier: "book2", title: "Book 2")
    ]
    
    XCTAssertEqual(viewModel.allBooks.count, 2)
  }
  
  func testAllBooks_WhenLanesHaveBooks_ReturnsLaneBooks() async {
    let viewModel = createViewModel()
    
    let book1 = TPPBookMocker.mockBook(identifier: "lane-book1", title: "Lane Book 1")
    let book2 = TPPBookMocker.mockBook(identifier: "lane-book2", title: "Lane Book 2")
    
    viewModel.lanes = [
      CatalogLaneModel(title: "Lane 1", books: [book1], moreURL: nil),
      CatalogLaneModel(title: "Lane 2", books: [book2], moreURL: nil)
    ]
    viewModel.ungroupedBooks = [TPPBookMocker.mockBook(identifier: "ungrouped", title: "Ungrouped")]
    
    // When lanes are not empty, allBooks returns lane books only
    XCTAssertEqual(viewModel.allBooks.count, 2)
    XCTAssertEqual(viewModel.allBooks.map { $0.identifier }, ["lane-book1", "lane-book2"])
  }
  
  func testShouldShowPagination_WhenNextPageURLExists() {
    let viewModel = createViewModel()
    
    XCTAssertFalse(viewModel.shouldShowPagination)
    
    viewModel.nextPageURL = URL(string: "https://example.com/page2")
    
    XCTAssertTrue(viewModel.shouldShowPagination)
  }
  
  // MARK: - Published Property Tests
  
  func testIsLoadingPublishes() {
    let viewModel = createViewModel()
    
    let expectation = XCTestExpectation(description: "isLoading should publish")
    
    viewModel.$isLoading
      .dropFirst()
      .sink { _ in
        expectation.fulfill()
      }
      .store(in: &cancellables)
    
    viewModel.isLoading = false
    
    wait(for: [expectation], timeout: 1.0)
  }
  
  func testErrorPublishes() {
    let viewModel = createViewModel()
    
    let expectation = XCTestExpectation(description: "error should publish")
    
    viewModel.$error
      .dropFirst()
      .sink { newError in
        XCTAssertEqual(newError, "Network error")
        expectation.fulfill()
      }
      .store(in: &cancellables)
    
    viewModel.error = "Network error"
    
    wait(for: [expectation], timeout: 1.0)
  }
  
  func testLanesPublishes() {
    let viewModel = createViewModel()
    
    let expectation = XCTestExpectation(description: "lanes should publish")
    
    viewModel.$lanes
      .dropFirst()
      .sink { newLanes in
        XCTAssertEqual(newLanes.count, 1)
        expectation.fulfill()
      }
      .store(in: &cancellables)
    
    viewModel.lanes = [CatalogLaneModel(title: "Test Lane", books: [], moreURL: nil)]
    
    wait(for: [expectation], timeout: 1.0)
  }
  
  // MARK: - UI State Toggle Tests
  
  func testShowingSortSheetToggle() {
    let viewModel = createViewModel()
    
    viewModel.showingSortSheet = true
    XCTAssertTrue(viewModel.showingSortSheet)
    
    viewModel.showingSortSheet = false
    XCTAssertFalse(viewModel.showingSortSheet)
  }
  
  func testShowingFiltersSheetToggle() {
    let viewModel = createViewModel()
    
    viewModel.showingFiltersSheet = true
    XCTAssertTrue(viewModel.showingFiltersSheet)
    
    viewModel.showingFiltersSheet = false
    XCTAssertFalse(viewModel.showingFiltersSheet)
  }
  
  func testShowSearchToggle() {
    let viewModel = createViewModel()
    
    viewModel.showSearch = true
    XCTAssertTrue(viewModel.showSearch)
    
    viewModel.showSearch = false
    XCTAssertFalse(viewModel.showSearch)
  }
  
  // MARK: - Sort Facets Tests
  
  func testSortFacets_WhenNoSortGroup_ReturnsEmpty() {
    let viewModel = createViewModel()
    
    viewModel.facetGroups = [
      CatalogFilterGroup(id: "format", name: "Format", filters: [
        CatalogFilter(id: "ebook", title: "eBook", href: nil, active: false)
      ])
    ]
    
    XCTAssertTrue(viewModel.sortFacets.isEmpty)
  }
  
  func testSortFacets_WhenSortGroupExists_ReturnsFacets() {
    let viewModel = createViewModel()
    
    let sortFilter1 = CatalogFilter(id: "title", title: "Title", href: URL(string: "https://example.com/sort/title"), active: false)
    let sortFilter2 = CatalogFilter(id: "author", title: "Author", href: URL(string: "https://example.com/sort/author"), active: true)
    
    viewModel.facetGroups = [
      CatalogFilterGroup(id: "sort", name: "Sort By", filters: [sortFilter1, sortFilter2]),
      CatalogFilterGroup(id: "format", name: "Format", filters: [])
    ]
    
    XCTAssertEqual(viewModel.sortFacets.count, 2)
  }
  
  func testActiveSortTitle_WhenNoActiveFacet_ReturnsNil() {
    let viewModel = createViewModel()
    
    viewModel.facetGroups = [
      CatalogFilterGroup(id: "sort", name: "Sort By", filters: [
        CatalogFilter(id: "title", title: "Title", href: nil, active: false),
        CatalogFilter(id: "author", title: "Author", href: nil, active: false)
      ])
    ]
    
    XCTAssertNil(viewModel.activeSortTitle)
  }
  
  func testActiveSortTitle_WhenActiveFacetExists_ReturnsTitle() {
    let viewModel = createViewModel()
    
    viewModel.facetGroups = [
      CatalogFilterGroup(id: "sort", name: "Sort By", filters: [
        CatalogFilter(id: "title", title: "Title", href: nil, active: false),
        CatalogFilter(id: "author", title: "Author", href: nil, active: true)
      ])
    ]
    
    XCTAssertEqual(viewModel.activeSortTitle, "Author")
  }
  
  // MARK: - Filter Selection Tests
  
  func testPendingSelectionsUpdate() {
    let viewModel = createViewModel()
    
    viewModel.pendingSelections.insert("Format::eBook")
    viewModel.pendingSelections.insert("Sort::Title")
    
    XCTAssertEqual(viewModel.pendingSelections.count, 2)
    XCTAssertTrue(viewModel.pendingSelections.contains("Format::eBook"))
    XCTAssertTrue(viewModel.pendingSelections.contains("Sort::Title"))
  }
  
  func testAppliedSelectionsUpdate() {
    let viewModel = createViewModel()
    
    viewModel.appliedSelections.insert("Format::eBook")
    
    XCTAssertEqual(viewModel.appliedSelections.count, 1)
    XCTAssertTrue(viewModel.appliedSelections.contains("Format::eBook"))
  }
  
  // MARK: - Loading More State Tests
  
  func testIsLoadingMoreInitiallyFalse() {
    let viewModel = createViewModel()
    
    XCTAssertFalse(viewModel.isLoadingMore)
  }
  
  func testIsApplyingFiltersInitiallyFalse() {
    let viewModel = createViewModel()
    
    XCTAssertFalse(viewModel.isApplyingFilters)
  }
}
