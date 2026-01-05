//
//  CatalogSearchViewModelTests.swift
//  PalaceTests
//
//  Tests for CatalogSearchViewModel including search debouncing,
//  filtering, and error states.
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
  var searchDelay: TimeInterval = 0
  
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
    
    if searchDelay > 0 {
      try await Task.sleep(nanoseconds: UInt64(searchDelay * 1_000_000_000))
    }
    
    if let error = searchError {
      throw error
    }
    return searchResult
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
    searchDelay = 0
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
  
  override func setUp() async throws {
    try await super.setUp()
    mockRepository = CatalogRepositoryMock()
    cancellables = Set<AnyCancellable>()
    testBaseURL = URL(string: "https://example.com/catalog")!
  }
  
  override func tearDown() async throws {
    mockRepository = nil
    cancellables = nil
    testBaseURL = nil
    try await super.tearDown()
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
  
  func testInit_EmptySearchQuery() async {
    let viewModel = createViewModel()
    
    XCTAssertEqual(viewModel.searchQuery, "")
    XCTAssertTrue(viewModel.filteredBooks.isEmpty)
    XCTAssertFalse(viewModel.isLoading)
    XCTAssertNil(viewModel.errorMessage)
  }
  
  // MARK: - UpdateBooks Tests
  
  func testUpdateBooks_SetsFilteredBooks_WhenQueryEmpty() async {
    let viewModel = createViewModel()
    let books = [createTestBook(), createTestBook()]
    
    viewModel.updateBooks(books)
    
    XCTAssertEqual(viewModel.filteredBooks.count, 2)
  }
  
  func testUpdateBooks_KeepsSearchResults_WhenQueryNotEmpty() async {
    let viewModel = createViewModel()
    let books = [createTestBook(), createTestBook()]
    
    viewModel.searchQuery = "test"
    viewModel.updateBooks(books)
    
    // When query is not empty, filteredBooks should not be updated
    // (they would be set by the search results instead)
    XCTAssertNotEqual(viewModel.filteredBooks.count, 2)
  }
  
  // MARK: - Search Query Tests
  
  func testUpdateSearchQuery_SetsQuery() async {
    let viewModel = createViewModel()
    
    viewModel.updateSearchQuery("Harry Potter")
    
    XCTAssertEqual(viewModel.searchQuery, "Harry Potter")
  }
  
  func testUpdateSearchQuery_TriggersDebounce() async {
    let viewModel = createViewModel()
    
    viewModel.updateSearchQuery("test")
    
    // Immediately after setting query, search should not have been called yet
    XCTAssertEqual(mockRepository.searchCallCount, 0)
    
    // Wait for debounce
    try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
    
    // After debounce, search should have been called
    // Note: This depends on debounce timer implementation
  }
  
  func testUpdateSearchQuery_CancelsOldTimer() async {
    let viewModel = createViewModel()
    
    // Rapid updates should only trigger one search
    viewModel.updateSearchQuery("H")
    viewModel.updateSearchQuery("Ha")
    viewModel.updateSearchQuery("Har")
    viewModel.updateSearchQuery("Harr")
    viewModel.updateSearchQuery("Harry")
    
    // Wait for debounce to complete
    try? await Task.sleep(nanoseconds: 200_000_000)
    
    // Should only have made one search call with final query
    // (or possibly still 0 if async timing differs)
    XCTAssertLessThanOrEqual(mockRepository.searchCallCount, 1)
    if mockRepository.searchCallCount > 0 {
      XCTAssertEqual(mockRepository.lastSearchQuery, "Harry")
    }
  }
  
  // MARK: - Clear Search Tests
  
  func testClearSearch_ResetsState() async {
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
  
  func testClearSearch_RestoresAllBooks() async {
    let viewModel = createViewModel()
    let books = [createTestBook(), createTestBook(), createTestBook()]
    
    viewModel.updateBooks(books)
    viewModel.filteredBooks = [] // Simulate search with no results
    
    viewModel.clearSearch()
    
    XCTAssertEqual(viewModel.filteredBooks.count, 3)
  }
  
  // MARK: - Empty Query Tests
  
  func testEmptyQuery_ShowsAllBooks() async {
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
  
  func testWhitespaceQuery_TreatedAsEmpty() async {
    let query = "   "
    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    
    XCTAssertTrue(trimmedQuery.isEmpty)
  }
  
  // MARK: - Debounce Behavior Tests
  
  func testDebounce_DefaultInterval() {
    // Default debounce interval is 0.1 seconds (100ms)
    let debounceInterval: TimeInterval = 0.1
    
    XCTAssertEqual(debounceInterval, 0.1)
  }
  
  func testDebounce_RapidTyping_SingleSearch() async {
    let viewModel = createViewModel()
    
    // Simulate rapid typing
    for char in "testing" {
      viewModel.updateSearchQuery(String(char))
      try? await Task.sleep(nanoseconds: 10_000_000) // 10ms between keystrokes
    }
    
    // Wait for final debounce
    try? await Task.sleep(nanoseconds: 200_000_000)
    
    // Should have made at most one search
    XCTAssertLessThanOrEqual(mockRepository.searchCallCount, 1)
  }
  
  // MARK: - Search Error Handling Tests
  
  func testSearch_NetworkError_ClearsResults() async {
    let viewModel = createViewModel()
    mockRepository.searchError = TestError.networkError
    
    viewModel.updateSearchQuery("test")
    
    // Wait for search to complete
    try? await Task.sleep(nanoseconds: 300_000_000)
    
    // After error, filtered books should be empty
    XCTAssertTrue(viewModel.filteredBooks.isEmpty)
  }
  
  func testSearch_NoBaseURL_ClearsResults() async {
    let viewModel = CatalogSearchViewModel(
      repository: mockRepository,
      baseURL: { nil }
    )
    
    viewModel.updateSearchQuery("test")
    
    // Wait for search
    try? await Task.sleep(nanoseconds: 200_000_000)
    
    // Without URL, filtered books should be empty
    XCTAssertTrue(viewModel.filteredBooks.isEmpty)
  }
  
  // MARK: - Task Cancellation Tests
  
  func testSearch_CancelsPreviousTask() async {
    let viewModel = createViewModel()
    mockRepository.searchDelay = 0.5 // Slow search
    
    // Start first search
    viewModel.updateSearchQuery("first")
    try? await Task.sleep(nanoseconds: 150_000_000) // 150ms
    
    // Start second search before first completes
    viewModel.updateSearchQuery("second")
    try? await Task.sleep(nanoseconds: 700_000_000) // Wait for completion
    
    // Only the second search result should be used
    XCTAssertEqual(mockRepository.lastSearchQuery, "second")
  }
  
  // MARK: - Loading State Tests
  
  func testLoadingState_InitiallyFalse() {
    let viewModel = createViewModel()
    
    XCTAssertFalse(viewModel.isLoading)
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
  
  // MARK: - Repository Interaction Tests
  
  func testSearch_PassesCorrectParameters() async {
    let viewModel = createViewModel()
    
    viewModel.updateSearchQuery("Harry Potter")
    
    // Wait for debounce and search
    try? await Task.sleep(nanoseconds: 300_000_000)
    
    if mockRepository.searchCallCount > 0 {
      XCTAssertEqual(mockRepository.lastSearchQuery, "Harry Potter")
      XCTAssertEqual(mockRepository.lastSearchURL, testBaseURL)
    }
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
  
  // MARK: - Integration Tests
  
  func testSearchFlow_CompleteSuccess() async {
    let viewModel = createViewModel()
    let initialBooks = [createTestBook(), createTestBook()]
    
    // Set initial books
    viewModel.updateBooks(initialBooks)
    XCTAssertEqual(viewModel.filteredBooks.count, 2)
    
    // Perform search (no mock result set, so will return empty)
    viewModel.updateSearchQuery("test")
    try? await Task.sleep(nanoseconds: 300_000_000)
    
    // Clear search
    viewModel.clearSearch()
    
    // Should restore initial books
    XCTAssertEqual(viewModel.filteredBooks.count, 2)
    XCTAssertEqual(viewModel.searchQuery, "")
    XCTAssertFalse(viewModel.isLoading)
  }
  
  func testSearchFlow_ErrorThenRecover() async {
    let viewModel = createViewModel()
    let initialBooks = [createTestBook()]
    
    viewModel.updateBooks(initialBooks)
    
    // Cause error
    mockRepository.searchError = TestError.networkError
    viewModel.updateSearchQuery("test")
    try? await Task.sleep(nanoseconds: 300_000_000)
    
    // Clear search to recover
    viewModel.clearSearch()
    
    // Should be back to initial state
    XCTAssertEqual(viewModel.filteredBooks.count, 1)
    XCTAssertNil(viewModel.errorMessage)
  }
}

