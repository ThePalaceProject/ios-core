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
  
  // MARK: - Active Filters Count Tests
  
  /// Tests activeFiltersCount with properly formatted selections
  /// Format: "groupName|filterTitle" - filters out "all" default titles
  func testActiveFiltersCount_WithAppliedSelections() {
    let viewModel = createViewModel()
    
    // Use format expected by CatalogFilterService: "groupName|filterTitle"
    // Note: "all" titles are filtered out, so use specific filter names
    viewModel.appliedSelections = Set(["Format|eBook", "Availability|Available Now"])
    
    XCTAssertEqual(viewModel.activeFiltersCount, 2)
  }
  
  func testActiveFiltersCount_AfterClearingSelections() {
    let viewModel = createViewModel()
    
    // Use format expected by CatalogFilterService
    viewModel.appliedSelections = Set(["Format|eBook"])
    XCTAssertEqual(viewModel.activeFiltersCount, 1)
    
    viewModel.appliedSelections.removeAll()
    XCTAssertEqual(viewModel.activeFiltersCount, 0)
  }
  
  func testActiveFiltersCount_FiltersOutAllDefaults() {
    let viewModel = createViewModel()
    
    // "all" titles are filtered out by the service
    viewModel.appliedSelections = Set(["Format|All", "Availability|All Formats"])
    
    XCTAssertEqual(viewModel.activeFiltersCount, 0, "Default 'all' selections should not count")
  }
  
  // MARK: - Pagination Tests
  
  func testPagination_NextPageURLCanBeSet() {
    let viewModel = createViewModel()
    let nextPageURL = URL(string: "https://example.com/feed?page=2")
    
    viewModel.nextPageURL = nextPageURL
    
    XCTAssertEqual(viewModel.nextPageURL, nextPageURL)
    XCTAssertTrue(viewModel.shouldShowPagination)
  }
  
  func testPagination_ClearedWhenNil() {
    let viewModel = createViewModel()
    viewModel.nextPageURL = URL(string: "https://example.com/feed?page=2")
    
    viewModel.nextPageURL = nil
    
    XCTAssertNil(viewModel.nextPageURL)
    XCTAssertFalse(viewModel.shouldShowPagination)
  }
  
  // MARK: - Books List Tests
  
  func testAllBooks_EmptyWhenNoData() {
    let viewModel = createViewModel()
    
    XCTAssertTrue(viewModel.allBooks.isEmpty)
  }
  
  func testAllBooks_CombinesMultipleLanes() {
    let viewModel = createViewModel()
    
    let book1 = TPPBookMocker.mockBook(identifier: "book1", title: "Book 1")
    let book2 = TPPBookMocker.mockBook(identifier: "book2", title: "Book 2")
    let book3 = TPPBookMocker.mockBook(identifier: "book3", title: "Book 3")
    
    viewModel.lanes = [
      CatalogLaneModel(title: "Lane 1", books: [book1, book2], moreURL: nil),
      CatalogLaneModel(title: "Lane 2", books: [book3], moreURL: nil)
    ]
    
    XCTAssertEqual(viewModel.allBooks.count, 3)
  }
  
  // MARK: - Error Handling Tests
  
  func testError_CanBeSet() {
    let viewModel = createViewModel()
    
    viewModel.error = "Connection failed"
    
    XCTAssertEqual(viewModel.error, "Connection failed")
  }
  
  func testError_CanBeCleared() {
    let viewModel = createViewModel()
    viewModel.error = "Some error"
    
    viewModel.error = nil
    
    XCTAssertNil(viewModel.error)
  }
  
  // MARK: - Filter Groups Tests
  
  func testFacetGroups_MultipleGroups() {
    let viewModel = createViewModel()
    
    let formatGroup = CatalogFilterGroup(
      id: "format",
      name: "Format",
      filters: [
        CatalogFilter(id: "ebook", title: "eBook", href: nil, active: false),
        CatalogFilter(id: "audiobook", title: "Audiobook", href: nil, active: false)
      ]
    )
    
    let availabilityGroup = CatalogFilterGroup(
      id: "availability",
      name: "Availability",
      filters: [
        CatalogFilter(id: "now", title: "Available Now", href: nil, active: true),
        CatalogFilter(id: "all", title: "All", href: nil, active: false)
      ]
    )
    
    viewModel.facetGroups = [formatGroup, availabilityGroup]
    
    XCTAssertEqual(viewModel.facetGroups.count, 2)
  }
  
  // MARK: - Title Tests
  
  func testTitle_WithSpecialCharacters() {
    let viewModel = createViewModel(title: "New & Popular 📚")
    
    XCTAssertEqual(viewModel.title, "New & Popular 📚")
  }
  
  func testTitle_Empty() {
    let viewModel = createViewModel(title: "")
    
    XCTAssertEqual(viewModel.title, "")
  }
}
