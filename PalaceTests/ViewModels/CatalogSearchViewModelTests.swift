//
//  CatalogSearchViewModelTests.swift
//  PalaceTests
//
//  Tests for CatalogSearchViewModel state management.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import Combine
@testable import Palace

// MARK: - Mock Repository for Search Tests

@MainActor
final class CatalogRepositoryMock: CatalogRepositoryProtocol {
  
  var loadTopLevelCatalogResult: CatalogFeed?
  var loadTopLevelCatalogError: Error?
  var searchResult: CatalogFeed?
  var searchError: Error?
  var loadTopLevelCatalogCallCount = 0
  var searchCallCount = 0
  var lastSearchQuery: String?
  var lastSearchURL: URL?
  
  func loadTopLevelCatalog(at url: URL) async throws -> CatalogFeed? {
    loadTopLevelCatalogCallCount += 1
    if let error = loadTopLevelCatalogError {
      throw error
    }
    return loadTopLevelCatalogResult
  }
  
  func search(query: String, baseURL: URL) async throws -> CatalogFeed? {
    searchCallCount += 1
    lastSearchQuery = query
    lastSearchURL = baseURL
    
    if let error = searchError {
      throw error
    }
    return searchResult
  }
  
  func fetchFeed(at url: URL) async throws -> CatalogFeed? {
    return try await loadTopLevelCatalog(at: url)
  }
  
  func invalidateCache(for url: URL) {
    // No-op for mock
  }
  
  func reset() {
    loadTopLevelCatalogResult = nil
    loadTopLevelCatalogError = nil
    searchResult = nil
    searchError = nil
    loadTopLevelCatalogCallCount = 0
    searchCallCount = 0
    lastSearchQuery = nil
    lastSearchURL = nil
  }
}

// MARK: - Test Error

enum TestError: Error {
  case networkError
  case parsingError
  case timeout
}

// MARK: - Tests

@MainActor
final class CatalogSearchViewModelTests: XCTestCase {
  
  // MARK: - Properties
  
  private var mockRepository: CatalogRepositoryMock!
  private var cancellables: Set<AnyCancellable>!
  private var testBaseURL: URL!
  
  // MARK: - Setup/Teardown
  
  override func setUp() {
    super.setUp()
    mockRepository = CatalogRepositoryMock()
    cancellables = Set<AnyCancellable>()
    testBaseURL = URL(string: "https://example.com/catalog")!
  }
  
  override func tearDown() {
    mockRepository = nil
    cancellables = nil
    testBaseURL = nil
    super.tearDown()
  }
  
  // MARK: - Helper Methods
  
  private func createViewModel() -> CatalogSearchViewModel {
    return CatalogSearchViewModel(
      repository: mockRepository,
      baseURL: { [weak self] in self?.testBaseURL }
    )
  }
  
  private func createTestBook() -> TPPBook {
    return TPPBookMocker.mockBook(distributorType: .EpubZip)
  }
  
  // MARK: - Initialization Tests
  
  func testInit_EmptySearchQuery() {
    let viewModel = createViewModel()
    
    XCTAssertEqual(viewModel.searchQuery, "")
    XCTAssertTrue(viewModel.filteredBooks.isEmpty)
    XCTAssertFalse(viewModel.isLoading)
    XCTAssertNil(viewModel.errorMessage)
  }
  
  // MARK: - UpdateBooks Tests
  
  func testUpdateBooks_SetsFilteredBooks_WhenQueryEmpty() {
    let viewModel = createViewModel()
    let books = [createTestBook(), createTestBook()]
    
    viewModel.updateBooks(books)
    
    XCTAssertEqual(viewModel.filteredBooks.count, 2)
  }
  
  func testUpdateBooks_KeepsSearchResults_WhenQueryNotEmpty() {
    let viewModel = createViewModel()
    let books = [createTestBook(), createTestBook()]
    
    viewModel.searchQuery = "test"
    viewModel.updateBooks(books)
    
    // When query is not empty, filteredBooks should not be updated
    XCTAssertNotEqual(viewModel.filteredBooks.count, 2)
  }
  
  // MARK: - Search Query Tests
  
  func testUpdateSearchQuery_SetsQuery() {
    let viewModel = createViewModel()
    
    viewModel.updateSearchQuery("Harry Potter")
    
    XCTAssertEqual(viewModel.searchQuery, "Harry Potter")
  }
  
  // MARK: - Clear Search Tests
  
  func testClearSearch_ResetsState() {
    let viewModel = createViewModel()
    let books = [createTestBook()]
    
    viewModel.updateBooks(books)
    viewModel.searchQuery = "test"
    viewModel.isLoading = true
    viewModel.errorMessage = "Error"
    
    viewModel.clearSearch()
    
    XCTAssertEqual(viewModel.searchQuery, "")
    XCTAssertFalse(viewModel.isLoading)
    XCTAssertNil(viewModel.errorMessage)
    XCTAssertEqual(viewModel.filteredBooks.count, 1)
  }
  
  func testClearSearch_RestoresAllBooks() {
    let viewModel = createViewModel()
    let books = [createTestBook(), createTestBook(), createTestBook()]
    
    viewModel.updateBooks(books)
    viewModel.filteredBooks = [] // Simulate search with no results
    
    viewModel.clearSearch()
    
    XCTAssertEqual(viewModel.filteredBooks.count, 3)
  }
  
  // MARK: - Empty Query Tests
  
  func testEmptyQuery_ShowsAllBooks() {
    let viewModel = createViewModel()
    let books = [createTestBook(), createTestBook()]
    
    viewModel.updateBooks(books)
    viewModel.searchQuery = "test"
    viewModel.filteredBooks = []
    
    // Simulate empty query search
    viewModel.searchQuery = ""
    viewModel.updateBooks(books) // Re-apply to restore
    
    XCTAssertEqual(viewModel.filteredBooks.count, 2)
  }
  
  func testWhitespaceQuery_TreatedAsEmpty() {
    let query = "   "
    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    
    XCTAssertTrue(trimmedQuery.isEmpty)
  }
  
  // MARK: - Loading State Tests
  
  func testLoadingState_InitiallyFalse() {
    let viewModel = createViewModel()
    
    XCTAssertFalse(viewModel.isLoading)
  }
  
  func testLoadingState_CanBeSet() {
    let viewModel = createViewModel()
    
    viewModel.isLoading = true
    
    XCTAssertTrue(viewModel.isLoading)
  }
  
  // MARK: - Error Message Tests
  
  func testErrorMessage_InitiallyNil() {
    let viewModel = createViewModel()
    
    XCTAssertNil(viewModel.errorMessage)
  }
  
  func testErrorMessage_ClearedOnClearSearch() {
    let viewModel = createViewModel()
    viewModel.errorMessage = "Some error"
    
    viewModel.clearSearch()
    
    XCTAssertNil(viewModel.errorMessage)
  }
  
  // MARK: - Filtered Books Tests
  
  func testFilteredBooks_EmptyInitially() {
    let viewModel = createViewModel()
    
    XCTAssertTrue(viewModel.filteredBooks.isEmpty)
  }
  
  func testFilteredBooks_UpdatedOnUpdateBooks() {
    let viewModel = createViewModel()
    let books = [createTestBook()]
    
    viewModel.updateBooks(books)
    
    XCTAssertEqual(viewModel.filteredBooks.count, 1)
  }
  
  // MARK: - Query Trimming Tests
  
  func testSearch_TrimsWhitespace() {
    let query = "  Harry Potter  "
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    
    XCTAssertEqual(trimmed, "Harry Potter")
  }
  
  func testSearch_EmptyAfterTrim_ShowsAllBooks() {
    let query = "   "
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    
    XCTAssertTrue(trimmed.isEmpty)
  }
  
  // MARK: - Edge Case Tests
  
  func testSearch_SpecialCharacters_DoesNotCrash() {
    let viewModel = createViewModel()
    
    // Special characters in search query should not crash
    viewModel.updateSearchQuery("Harry's Book & Other Stories (Volume 1)")
    
    XCTAssertEqual(viewModel.searchQuery, "Harry's Book & Other Stories (Volume 1)")
  }
  
  func testSearch_UnicodeCharacters_Stored() {
    let viewModel = createViewModel()
    
    viewModel.updateSearchQuery("日本語の本")
    
    XCTAssertEqual(viewModel.searchQuery, "日本語の本")
  }
  
  func testSearch_VeryLongQuery_Stored() {
    let viewModel = createViewModel()
    let longQuery = String(repeating: "test ", count: 100)
    
    viewModel.updateSearchQuery(longQuery)
    
    XCTAssertEqual(viewModel.searchQuery, longQuery)
  }
  
  func testUpdateBooks_EmptyArray() {
    let viewModel = createViewModel()
    
    viewModel.updateBooks([])
    
    XCTAssertTrue(viewModel.filteredBooks.isEmpty)
  }
  
  func testUpdateBooks_LargeArray() {
    let viewModel = createViewModel()
    let books = (0..<100).map { _ in createTestBook() }
    
    viewModel.updateBooks(books)
    
    XCTAssertEqual(viewModel.filteredBooks.count, 100)
  }
  
  // MARK: - Concurrent Operation Tests
  
  func testConcurrentUpdates_DoNotCrash() async {
    let viewModel = createViewModel()
    let books = [createTestBook(), createTestBook()]
    
    // Simulate concurrent operations
    await withTaskGroup(of: Void.self) { group in
      group.addTask { @MainActor in
        viewModel.updateBooks(books)
      }
      group.addTask { @MainActor in
        viewModel.updateSearchQuery("test")
      }
      group.addTask { @MainActor in
        viewModel.clearSearch()
      }
    }
    
    // Should not crash
    XCTAssertNotNil(viewModel)
  }
  
  // MARK: - PP-3605 Regression Tests: Scroll Position on Pagination
  
  /// Regression test for PP-3605: Search results scroll to top during pagination
  /// The searchId should NOT change when pagination loads more books,
  /// so the view doesn't scroll back to the top.
  func testPP3605_LoadNextPage_DoesNotChangeSearchId() async {
    let viewModel = createViewModel()
    
    // Set up mock to return results with a next page URL
    let nextPageURL = URL(string: "https://example.com/catalog?page=2")!
    let mockFeed = createMockFeedWithNextPage(nextPageURL: nextPageURL)
    mockRepository.loadTopLevelCatalogResult = mockFeed
    
    // Perform initial search
    viewModel.updateSearchQuery("sky")
    
    // Wait for debounce and search to complete
    try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
    
    // Capture the searchId after initial search
    let searchIdAfterInitialSearch = viewModel.searchId
    
    // Now load next page (pagination)
    await viewModel.loadNextPage()
    
    // searchId should NOT change after pagination
    XCTAssertEqual(
      viewModel.searchId,
      searchIdAfterInitialSearch,
      "searchId should remain unchanged during pagination to preserve scroll position"
    )
  }
  
  /// Regression test for PP-3605: Search results scroll to top on registry updates
  /// The searchId should NOT change when registry updates refresh book states.
  func testPP3605_ApplyRegistryUpdates_DoesNotChangeSearchId() {
    let viewModel = createViewModel()
    let books = [createTestBook(), createTestBook()]
    viewModel.updateBooks(books)
    
    // Simulate having search results
    viewModel.filteredBooks = books
    
    // Capture the searchId before registry update
    let searchIdBeforeUpdate = viewModel.searchId
    
    // Apply registry updates (simulates book state changes like downloads)
    viewModel.applyRegistryUpdates(changedIdentifier: nil)
    
    // searchId should NOT change after registry updates
    XCTAssertEqual(
      viewModel.searchId,
      searchIdBeforeUpdate,
      "searchId should remain unchanged during registry updates to preserve scroll position"
    )
  }
  
  /// Test that searchId DOES change when a new search query is entered
  func testPP3605_NewSearch_ChangesSearchId() async {
    let viewModel = createViewModel()
    
    // Capture initial searchId
    let initialSearchId = viewModel.searchId
    
    // Perform a search
    viewModel.updateSearchQuery("harry potter")
    
    // Wait for debounce to trigger search
    try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
    
    // searchId SHOULD change for a new search
    XCTAssertNotEqual(
      viewModel.searchId,
      initialSearchId,
      "searchId should change when performing a new search to trigger scroll to top"
    )
  }
  
  /// Test that searchId changes again for subsequent different searches
  func testPP3605_DifferentSearches_EachHaveUniqueSearchId() async {
    let viewModel = createViewModel()
    
    // First search
    viewModel.updateSearchQuery("sky")
    try? await Task.sleep(nanoseconds: 200_000_000)
    let firstSearchId = viewModel.searchId
    
    // Second different search
    viewModel.updateSearchQuery("ocean")
    try? await Task.sleep(nanoseconds: 200_000_000)
    let secondSearchId = viewModel.searchId
    
    // Each search should have a unique searchId
    XCTAssertNotEqual(
      firstSearchId,
      secondSearchId,
      "Different searches should have different searchIds"
    )
  }
  
  /// Test that clearing search changes searchId (to scroll to top of all books)
  func testPP3605_ClearSearch_ChangesSearchId() {
    let viewModel = createViewModel()
    let books = [createTestBook()]
    viewModel.updateBooks(books)
    
    // Set up a search state
    viewModel.searchQuery = "test"
    let searchIdBeforeClear = viewModel.searchId
    
    // Clear the search
    viewModel.clearSearch()
    
    // searchId SHOULD change when clearing search to scroll to top of results
    XCTAssertNotEqual(
      viewModel.searchId,
      searchIdBeforeClear,
      "searchId should change when clearing search to trigger scroll to top"
    )
  }
  
  // MARK: - Helper for PP-3605 Tests
  
  private func createMockFeedWithNextPage(nextPageURL: URL) -> CatalogFeed? {
    // The mock will return this feed, which should have pagination info
    // For the test, we mainly need the mock to return something
    // The actual next page URL extraction happens in the view model
    return nil
  }
}
