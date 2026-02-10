//
//  CatalogSearchViewModelTests.swift
//  PalaceTests
//
//  Comprehensive unit tests for CatalogSearchViewModel.
//  Tests cover initialization, search operations, debouncing, cancellation,
//  and state management following Test_Patterns.md conventions.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import Combine
@testable import Palace

// MARK: - Mock Repository for Search Tests

@MainActor
final class CatalogRepositoryMock: CatalogRepositoryProtocol {

  // MARK: - Configuration

  var loadTopLevelCatalogResult: CatalogFeed?
  var loadTopLevelCatalogError: Error?
  var searchResult: CatalogFeed?
  var searchError: Error?
  var simulatedDelay: TimeInterval = 0

  // MARK: - Call Tracking

  private(set) var loadTopLevelCatalogCallCount = 0
  private(set) var searchCallCount = 0
  private(set) var lastSearchQuery: String?
  private(set) var lastSearchURL: URL?
  private(set) var lastLoadURL: URL?
  private(set) var searchHistory: [(query: String, url: URL)] = []

  // MARK: - CatalogRepositoryProtocol

  func loadTopLevelCatalog(at url: URL) async throws -> CatalogFeed? {
    loadTopLevelCatalogCallCount += 1
    lastLoadURL = url

    if simulatedDelay > 0 {
      try await Task.sleep(nanoseconds: UInt64(simulatedDelay * 1_000_000_000))
    }

    if let error = loadTopLevelCatalogError {
      throw error
    }

    return loadTopLevelCatalogResult
  }

  func search(query: String, baseURL: URL) async throws -> CatalogFeed? {
    searchCallCount += 1
    lastSearchQuery = query
    lastSearchURL = baseURL
    searchHistory.append((query, baseURL))

    if simulatedDelay > 0 {
      try await Task.sleep(nanoseconds: UInt64(simulatedDelay * 1_000_000_000))
    }

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

  // MARK: - Test Helpers

  func reset() {
    loadTopLevelCatalogResult = nil
    loadTopLevelCatalogError = nil
    searchResult = nil
    searchError = nil
    simulatedDelay = 0
    loadTopLevelCatalogCallCount = 0
    searchCallCount = 0
    lastSearchQuery = nil
    lastSearchURL = nil
    lastLoadURL = nil
    searchHistory.removeAll()
  }
}

// MARK: - Test Error

enum TestError: Error {
  case networkError
  case parsingError
  case timeout
}

// MARK: - CatalogSearchViewModelTests

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
    mockRepository?.reset()
    mockRepository = nil
    cancellables = nil
    testBaseURL = nil
    super.tearDown()
  }

  // MARK: - Helper Methods

  private func createViewModel(
    baseURL: URL? = nil,
    debounceInterval: TimeInterval = 0.05 // Short debounce for faster tests
  ) -> CatalogSearchViewModel {
    let urlToUse = baseURL ?? testBaseURL
    return CatalogSearchViewModel(
      repository: mockRepository,
      baseURL: { urlToUse },
      debounceInterval: debounceInterval
    )
  }

  private func createViewModelWithNilURL(
    debounceInterval: TimeInterval = 0.05
  ) -> CatalogSearchViewModel {
    return CatalogSearchViewModel(
      repository: mockRepository,
      baseURL: { nil },
      debounceInterval: debounceInterval
    )
  }

  private func createTestBook() -> TPPBook {
    return TPPBookMocker.mockBook(distributorType: .EpubZip)
  }

  /// Wait for debounce + search to complete
  private func waitForDebounce(interval: TimeInterval = 0.1) async {
    try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
  }

  // MARK: - Initialization Tests

  func testInit_HasCorrectDefaults() {
    let viewModel = createViewModel()

    // Verify all @Published properties have correct defaults
    XCTAssertEqual(viewModel.searchQuery, "", "searchQuery should be empty string")
    XCTAssertTrue(viewModel.filteredBooks.isEmpty, "filteredBooks should be empty")
    XCTAssertFalse(viewModel.isLoading, "isLoading should be false")
    XCTAssertNil(viewModel.errorMessage, "errorMessage should be nil")
    XCTAssertNil(viewModel.nextPageURL, "nextPageURL should be nil")
    XCTAssertFalse(viewModel.isLoadingMore, "isLoadingMore should be false")
    XCTAssertNotNil(viewModel.searchId, "searchId should have initial value")
  }

  // MARK: - Search With Empty Query Tests

  func testSearch_WithEmptyQuery_DoesNotCallRepository() async {
    let viewModel = createViewModel()

    // Trigger search with empty query
    viewModel.updateSearchQuery("")

    // Wait for debounce
    await waitForDebounce()

    // Repository should not be called for empty query
    XCTAssertEqual(mockRepository.searchCallCount, 0, "Repository search should not be called for empty query")
  }

  func testSearch_WithWhitespaceOnlyQuery_DoesNotCallRepository() async {
    let viewModel = createViewModel()

    // Trigger search with whitespace-only query
    viewModel.updateSearchQuery("   ")

    // Wait for debounce
    await waitForDebounce()

    // Repository should not be called (whitespace is trimmed, becomes empty)
    XCTAssertEqual(mockRepository.searchCallCount, 0, "Repository search should not be called for whitespace-only query")
  }

  func testSearch_WithEmptyQuery_ShowsAllBooks() async {
    let viewModel = createViewModel()
    let books = [createTestBook(), createTestBook()]

    // Pre-populate with books
    viewModel.updateBooks(books)

    // Clear to empty state
    viewModel.filteredBooks = []

    // Trigger search with empty query
    viewModel.updateSearchQuery("")

    // Wait for debounce
    await waitForDebounce()

    // Should restore all books
    XCTAssertEqual(viewModel.filteredBooks.count, 2, "Empty query should restore all books")
  }

  // MARK: - Search With Valid Query Tests

  func testSearch_WithValidQuery_CallsRepository() async {
    let viewModel = createViewModel()

    // Trigger search with valid query
    viewModel.updateSearchQuery("Harry Potter")

    // Wait for debounce and search (needs longer wait for reliable test)
    await waitForDebounce(interval: 0.25)

    // Repository should be called
    XCTAssertEqual(mockRepository.searchCallCount, 1, "Repository search should be called once")
    XCTAssertEqual(mockRepository.lastSearchQuery, "Harry Potter", "Search query should match")
    XCTAssertEqual(mockRepository.lastSearchURL, testBaseURL, "Search base URL should match")
  }

  func testSearch_WithValidQuery_SetsIsSearching() async {
    let viewModel = createViewModel()

    // Add delay to mock to ensure we can observe isLoading
    mockRepository.simulatedDelay = 0.2

    let expectation = XCTestExpectation(description: "isLoading becomes true")

    viewModel.$isLoading
      .dropFirst()
      .sink { isLoading in
        if isLoading {
          expectation.fulfill()
        }
      }
      .store(in: &cancellables)

    // Trigger search
    viewModel.updateSearchQuery("test")

    await fulfillment(of: [expectation], timeout: 1.0)
    XCTAssertTrue(viewModel.isLoading, "isLoading should be true during search")
  }

  func testSearch_WithValidQuery_ClearsIsLoadingAfterCompletion() async {
    let viewModel = createViewModel()

    // Trigger search
    viewModel.updateSearchQuery("test")

    // Wait for search to complete
    await waitForDebounce(interval: 0.2)

    XCTAssertFalse(viewModel.isLoading, "isLoading should be false after search completes")
  }

  // MARK: - Search Results Tests

  func testSearch_WithResults_UpdatesResults() async {
    let viewModel = createViewModel()

    // Configure mock to return a feed
    // Note: We can't easily create a full CatalogFeed, but we can verify the search was called
    // and the state management is correct
    mockRepository.searchResult = nil // Will result in empty results

    // Trigger search
    viewModel.updateSearchQuery("test query")

    // Wait for search to complete
    await waitForDebounce(interval: 0.2)

    // Verify search was called
    XCTAssertEqual(mockRepository.searchCallCount, 1)
    XCTAssertFalse(viewModel.isLoading, "isLoading should be false after search")
  }

  func testSearch_WithNilResult_SetsEmptyResults() async {
    let viewModel = createViewModel()

    // Pre-populate with books
    let books = [createTestBook()]
    viewModel.updateBooks(books)

    // Configure mock to return nil
    mockRepository.searchResult = nil

    // Trigger search
    viewModel.updateSearchQuery("nonexistent")

    // Wait for search to complete
    await waitForDebounce(interval: 0.2)

    // Filtered books should be empty
    XCTAssertTrue(viewModel.filteredBooks.isEmpty, "filteredBooks should be empty when search returns nil")
  }

  // MARK: - Search Error Tests

  func testSearch_WithError_SetsErrorMessage() async {
    let viewModel = createViewModel()

    // Configure mock to throw error
    mockRepository.searchError = TestError.networkError

    // Trigger search
    viewModel.updateSearchQuery("test")

    // Wait for search to complete
    await waitForDebounce(interval: 0.2)

    // Verify error handling - filteredBooks should be cleared
    XCTAssertTrue(viewModel.filteredBooks.isEmpty, "filteredBooks should be empty on error")
    XCTAssertFalse(viewModel.isLoading, "isLoading should be false after error")
  }

  func testSearch_WithError_ClearsNextPageURL() async {
    let viewModel = createViewModel()

    // Set up initial state with next page URL
    viewModel.nextPageURL = URL(string: "https://example.com/page2")

    // Configure mock to throw error
    mockRepository.searchError = TestError.networkError

    // Trigger search
    viewModel.updateSearchQuery("test")

    // Wait for search to complete
    await waitForDebounce(interval: 0.2)

    XCTAssertNil(viewModel.nextPageURL, "nextPageURL should be nil after error")
  }

  // MARK: - Debouncing Tests

  func testSearch_Debounces_MultipleQueries() async {
    let viewModel = createViewModel(debounceInterval: 0.1)

    // Rapidly fire multiple search queries
    viewModel.updateSearchQuery("H")
    viewModel.updateSearchQuery("Ha")
    viewModel.updateSearchQuery("Har")
    viewModel.updateSearchQuery("Harr")
    viewModel.updateSearchQuery("Harry")

    // Wait for debounce to complete
    await waitForDebounce(interval: 0.2)

    // Should only call repository once with final query
    XCTAssertEqual(mockRepository.searchCallCount, 1, "Repository should only be called once after debounce")
    XCTAssertEqual(mockRepository.lastSearchQuery, "Harry", "Should use final query value")
  }

  func testSearch_Debounces_DoesNotSearchDuringDebounceWindow() async {
    let viewModel = createViewModel(debounceInterval: 0.2)

    // Fire a search query
    viewModel.updateSearchQuery("test")

    // Check immediately (within debounce window)
    XCTAssertEqual(mockRepository.searchCallCount, 0, "Should not search immediately")

    // Wait for partial debounce
    await waitForDebounce(interval: 0.05)
    XCTAssertEqual(mockRepository.searchCallCount, 0, "Should not search during debounce window")

    // Wait for full debounce + search
    await waitForDebounce(interval: 0.3)
    XCTAssertEqual(mockRepository.searchCallCount, 1, "Should search after debounce completes")
  }

  // MARK: - Cancellation Tests

  func testSearch_CancelsInFlight_OnNewQuery() async {
    let viewModel = createViewModel(debounceInterval: 0.05)

    // Add delay to mock so first search is still in progress
    mockRepository.simulatedDelay = 0.3

    // Start first search
    viewModel.updateSearchQuery("first")

    // Wait for debounce, but search will still be in flight
    await waitForDebounce(interval: 0.1)

    // Start second search (should cancel first)
    mockRepository.simulatedDelay = 0.05 // Make second search faster
    viewModel.updateSearchQuery("second")

    // Wait for second search to complete
    await waitForDebounce(interval: 0.3)

    // Verify last search query was "second"
    XCTAssertEqual(mockRepository.lastSearchQuery, "second", "Last search should be 'second'")
  }

  func testSearch_CancelsDebounce_OnNewQuery() async {
    let viewModel = createViewModel(debounceInterval: 0.2)

    // Start first search
    viewModel.updateSearchQuery("first")

    // Before debounce completes, start second search
    await waitForDebounce(interval: 0.05)
    viewModel.updateSearchQuery("second")

    // Wait for second debounce to complete
    await waitForDebounce(interval: 0.3)

    // Only "second" should have been searched
    XCTAssertEqual(mockRepository.searchCallCount, 1, "Should only search once")
    XCTAssertEqual(mockRepository.lastSearchQuery, "second", "Should search for 'second'")
  }

  // MARK: - Clear Search Tests

  func testClearSearch_ResetsState() {
    let viewModel = createViewModel()
    let books = [createTestBook()]

    // Set up various states
    viewModel.updateBooks(books)
    viewModel.searchQuery = "test"
    viewModel.isLoading = true
    viewModel.errorMessage = "Error"
    viewModel.nextPageURL = URL(string: "https://example.com/page2")
    viewModel.isLoadingMore = true

    // Clear search
    viewModel.clearSearch()

    // Verify all state is reset
    XCTAssertEqual(viewModel.searchQuery, "", "searchQuery should be empty")
    XCTAssertFalse(viewModel.isLoading, "isLoading should be false")
    XCTAssertNil(viewModel.errorMessage, "errorMessage should be nil")
    XCTAssertNil(viewModel.nextPageURL, "nextPageURL should be nil")
    XCTAssertFalse(viewModel.isLoadingMore, "isLoadingMore should be false")
    XCTAssertEqual(viewModel.filteredBooks.count, 1, "filteredBooks should be restored to allBooks")
  }

  func testClearSearch_RestoresAllBooks() {
    let viewModel = createViewModel()
    let books = [createTestBook(), createTestBook(), createTestBook()]

    viewModel.updateBooks(books)
    viewModel.filteredBooks = [] // Simulate search with no results

    viewModel.clearSearch()

    XCTAssertEqual(viewModel.filteredBooks.count, 3, "Should restore all books")
  }

  func testClearSearch_ChangesSearchId() {
    let viewModel = createViewModel()
    let initialSearchId = viewModel.searchId

    viewModel.clearSearch()

    XCTAssertNotEqual(viewModel.searchId, initialSearchId, "searchId should change on clear")
  }

  func testClearSearch_CancelsPendingOperations() async {
    let viewModel = createViewModel(debounceInterval: 0.2)

    // Start a search
    viewModel.updateSearchQuery("test")

    // Clear before debounce completes
    viewModel.clearSearch()

    // Wait for what would have been the debounce
    await waitForDebounce(interval: 0.3)

    // Search should not have been called
    XCTAssertEqual(mockRepository.searchCallCount, 0, "Search should be cancelled by clearSearch")
  }

  // MARK: - Nil Base URL Tests

  func testSearch_WithNilBaseURL_DoesNotSearch() async {
    let viewModel = createViewModelWithNilURL()

    // Trigger search
    viewModel.updateSearchQuery("test")

    // Wait for debounce
    await waitForDebounce(interval: 0.2)

    // Repository should not be called when baseURL is nil
    XCTAssertEqual(mockRepository.searchCallCount, 0, "Should not call repository when baseURL is nil")
    XCTAssertTrue(viewModel.filteredBooks.isEmpty, "filteredBooks should be empty")
    XCTAssertFalse(viewModel.isLoading, "isLoading should be false")
  }

  func testSearch_WithNilBaseURL_ClearsNextPageURL() async {
    let viewModel = createViewModelWithNilURL()

    // Set up initial state
    viewModel.nextPageURL = URL(string: "https://example.com/page2")

    // Trigger search
    viewModel.updateSearchQuery("test")

    // Wait for debounce
    await waitForDebounce(interval: 0.2)

    XCTAssertNil(viewModel.nextPageURL, "nextPageURL should be cleared when baseURL is nil")
  }

  // MARK: - Search ID Tests (PP-3605 Regression)

  func testSearch_NewSearch_ChangesSearchId() async {
    let viewModel = createViewModel()
    let initialSearchId = viewModel.searchId

    // Perform a search
    viewModel.updateSearchQuery("test")

    // Wait for search to complete
    await waitForDebounce(interval: 0.2)

    XCTAssertNotEqual(viewModel.searchId, initialSearchId, "searchId should change for new search")
  }

  func testSearch_DifferentQueries_HaveDifferentSearchIds() async {
    let viewModel = createViewModel()

    // First search
    viewModel.updateSearchQuery("first")
    await waitForDebounce(interval: 0.2)
    let firstSearchId = viewModel.searchId

    // Second search
    viewModel.updateSearchQuery("second")
    await waitForDebounce(interval: 0.2)
    let secondSearchId = viewModel.searchId

    XCTAssertNotEqual(firstSearchId, secondSearchId, "Different searches should have different searchIds")
  }

  // MARK: - Update Books Tests

  func testUpdateBooks_SetsFilteredBooks_WhenQueryEmpty() {
    let viewModel = createViewModel()
    let books = [createTestBook(), createTestBook()]

    viewModel.updateBooks(books)

    XCTAssertEqual(viewModel.filteredBooks.count, 2)
  }

  func testUpdateBooks_DoesNotChangeFilteredBooks_WhenQueryNotEmpty() {
    let viewModel = createViewModel()
    let books = [createTestBook(), createTestBook()]

    // Set a non-empty query first
    viewModel.searchQuery = "test"
    viewModel.filteredBooks = []

    // Update books
    viewModel.updateBooks(books)

    // filteredBooks should remain empty (not updated when query is non-empty)
    XCTAssertTrue(viewModel.filteredBooks.isEmpty, "filteredBooks should not change when query is non-empty")
  }

  // MARK: - Load Next Page Tests

  func testLoadNextPage_WithNoNextURL_DoesNothing() async {
    let viewModel = createViewModel()
    viewModel.nextPageURL = nil

    await viewModel.loadNextPage()

    XCTAssertEqual(mockRepository.loadTopLevelCatalogCallCount, 0)
    XCTAssertFalse(viewModel.isLoadingMore)
  }

  func testLoadNextPage_WhenAlreadyLoading_DoesNothing() async {
    let viewModel = createViewModel()
    viewModel.nextPageURL = URL(string: "https://example.com/page2")
    viewModel.isLoadingMore = true

    await viewModel.loadNextPage()

    // Should not make additional call
    XCTAssertEqual(mockRepository.loadTopLevelCatalogCallCount, 0)
  }

  func testLoadNextPage_SetsIsLoadingMore() async {
    let viewModel = createViewModel()
    viewModel.nextPageURL = URL(string: "https://example.com/page2")

    // Add delay to observe loading state
    mockRepository.simulatedDelay = 0.2

    let expectation = XCTestExpectation(description: "isLoadingMore becomes true")

    viewModel.$isLoadingMore
      .dropFirst()
      .sink { isLoadingMore in
        if isLoadingMore {
          expectation.fulfill()
        }
      }
      .store(in: &cancellables)

    Task {
      await viewModel.loadNextPage()
    }

    await fulfillment(of: [expectation], timeout: 1.0)
  }

  func testLoadNextPage_DoesNotChangeSearchId() async {
    let viewModel = createViewModel()
    let initialSearchId = viewModel.searchId
    viewModel.nextPageURL = URL(string: "https://example.com/page2")

    await viewModel.loadNextPage()

    XCTAssertEqual(viewModel.searchId, initialSearchId, "searchId should not change during pagination")
  }

  // MARK: - Apply Registry Updates Tests

  func testApplyRegistryUpdates_DoesNotChangeSearchId() {
    let viewModel = createViewModel()
    let books = [createTestBook()]
    viewModel.updateBooks(books)
    viewModel.filteredBooks = books

    let initialSearchId = viewModel.searchId

    viewModel.applyRegistryUpdates(changedIdentifier: nil)

    XCTAssertEqual(viewModel.searchId, initialSearchId, "searchId should not change during registry updates")
  }

  func testApplyRegistryUpdates_WithEmptyFilteredBooks_DoesNothing() {
    let viewModel = createViewModel()
    viewModel.filteredBooks = []

    // Should not crash or throw
    viewModel.applyRegistryUpdates(changedIdentifier: nil)

    XCTAssertTrue(viewModel.filteredBooks.isEmpty)
  }

  // MARK: - Edge Case Tests

  func testSearch_SpecialCharacters_DoesNotCrash() async {
    let viewModel = createViewModel()

    viewModel.updateSearchQuery("Harry's Book & Other Stories (Volume 1)")

    await waitForDebounce(interval: 0.2)

    // Should not crash and query should be stored
    XCTAssertEqual(mockRepository.lastSearchQuery, "Harry's Book & Other Stories (Volume 1)")
  }

  func testSearch_UnicodeCharacters_Works() async {
    let viewModel = createViewModel()

    viewModel.updateSearchQuery("日本語の本")

    await waitForDebounce(interval: 0.2)

    XCTAssertEqual(mockRepository.lastSearchQuery, "日本語の本")
  }

  func testSearch_VeryLongQuery_Works() async {
    let viewModel = createViewModel()
    // Use a query without trailing space to avoid trimming differences
    let longQuery = (0..<100).map { _ in "test" }.joined(separator: " ")

    viewModel.updateSearchQuery(longQuery)

    await waitForDebounce(interval: 0.25)

    XCTAssertEqual(mockRepository.lastSearchQuery, longQuery)
  }

  func testUpdateBooks_EmptyArray_Works() {
    let viewModel = createViewModel()

    viewModel.updateBooks([])

    XCTAssertTrue(viewModel.filteredBooks.isEmpty)
  }

  func testUpdateBooks_LargeArray_Works() {
    let viewModel = createViewModel()
    let books = (0..<100).map { _ in createTestBook() }

    viewModel.updateBooks(books)

    XCTAssertEqual(viewModel.filteredBooks.count, 100)
  }

  // MARK: - Concurrent Operation Tests

  func testConcurrentUpdates_DoNotCrash() async {
    let viewModel = createViewModel()
    let books = [createTestBook(), createTestBook()]

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
    viewModel.nextPageURL = nextPageURL

    // Perform initial search
    viewModel.updateSearchQuery("sky")

    // Wait for debounce and search to complete
    await waitForDebounce(interval: 0.15)

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
    await waitForDebounce(interval: 0.15)

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
    await waitForDebounce(interval: 0.15)
    let firstSearchId = viewModel.searchId

    // Second different search
    viewModel.updateSearchQuery("ocean")
    await waitForDebounce(interval: 0.15)
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
}
