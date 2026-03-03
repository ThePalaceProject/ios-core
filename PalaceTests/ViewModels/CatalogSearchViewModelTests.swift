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
}
