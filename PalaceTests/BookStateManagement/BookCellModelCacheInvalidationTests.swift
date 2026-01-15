//
//  BookCellModelCacheInvalidationTests.swift
//  PalaceTests
//
//  Tests for BookCellModelCache invalidation logic.
//  Ensures cache properly invalidates models when registry state changes.
//

import XCTest
import Combine
@testable import Palace

@MainActor
final class BookCellModelCacheInvalidationTests: XCTestCase {
  
  var mockRegistry: TPPBookRegistryMock!
  var mockImageCache: MockImageCache!
  var cache: BookCellModelCache!
  var cancellables: Set<AnyCancellable>!
  
  override func setUp() {
    super.setUp()
    mockRegistry = TPPBookRegistryMock()
    mockImageCache = MockImageCache()
    cache = BookCellModelCache(imageCache: mockImageCache, bookRegistry: mockRegistry)
    cancellables = Set<AnyCancellable>()
  }
  
  override func tearDown() {
    cache.clear()
    cancellables = nil
    cache = nil
    mockRegistry = nil
    mockImageCache = nil
    super.tearDown()
  }
  
  // MARK: - Helper
  
  private func createTestBook(id: String = "test-book-\(UUID().uuidString)") -> TPPBook {
    return TPPBook(dictionary: [
      "acquisitions": [TPPFake.genericAcquisition.dictionaryRepresentation()],
      "title": "Test Book",
      "categories": ["Fiction"],
      "id": id,
      "updated": "2024-01-01T00:00:00Z"
    ])!
  }
  
  // MARK: - Basic Caching Tests
  
  func testCacheReturnsSameModel() {
    let book = createTestBook()
    mockRegistry.addBook(book, state: .downloadSuccessful)
    
    let model1 = cache.model(for: book)
    let model2 = cache.model(for: book)
    
    XCTAssertTrue(model1 === model2, "Cache should return the same model instance")
  }
  
  func testCacheReturnsDifferentModelsForDifferentBooks() {
    let book1 = createTestBook(id: "book-1")
    let book2 = createTestBook(id: "book-2")
    mockRegistry.addBook(book1, state: .downloadSuccessful)
    mockRegistry.addBook(book2, state: .downloadSuccessful)
    
    let model1 = cache.model(for: book1)
    let model2 = cache.model(for: book2)
    
    XCTAssertFalse(model1 === model2, "Different books should have different models")
  }
  
  // MARK: - Invalidation Tests
  
  func testCacheInvalidatesOnStateChange() async {
    let book = createTestBook()
    mockRegistry.addBook(book, state: .downloadFailed)
    
    let model1 = cache.model(for: book)
    XCTAssertEqual(model1.registryState, .downloadFailed)
    
    // Change registry state - should trigger invalidation
    mockRegistry.setState(.downloadSuccessful, for: book.identifier)
    
    // Wait for invalidation
    try? await Task.sleep(nanoseconds: 150_000_000) // 150ms
    
    let model2 = cache.model(for: book)
    
    // Should be a new model with correct state
    XCTAssertFalse(model1 === model2, "Cache should return a new model after state change")
    XCTAssertEqual(model2.registryState, .downloadSuccessful)
  }
  
  func testCacheInvalidatesDownloadingToSuccessful() async {
    let book = createTestBook()
    mockRegistry.addBook(book, state: .downloading)
    
    let model1 = cache.model(for: book)
    XCTAssertEqual(model1.stableButtonState, .downloadInProgress)
    
    // Simulate download completion
    mockRegistry.setState(.downloadSuccessful, for: book.identifier)
    
    try? await Task.sleep(nanoseconds: 150_000_000) // 150ms
    
    let model2 = cache.model(for: book)
    XCTAssertFalse(model1 === model2, "Cache should invalidate when download completes")
  }
  
  func testCacheInvalidatesDownloadingToFailed() async {
    let book = createTestBook()
    mockRegistry.addBook(book, state: .downloading)
    
    let model1 = cache.model(for: book)
    
    // Simulate download failure
    mockRegistry.setState(.downloadFailed, for: book.identifier)
    
    try? await Task.sleep(nanoseconds: 150_000_000) // 150ms
    
    let model2 = cache.model(for: book)
    XCTAssertFalse(model1 === model2, "Cache should invalidate when download fails")
  }
  
  func testCacheInvalidatesFailedToSuccessful() async {
    let book = createTestBook()
    mockRegistry.addBook(book, state: .downloadFailed)
    
    let model1 = cache.model(for: book)
    XCTAssertEqual(model1.stableButtonState, .downloadFailed)
    
    // Simulate successful retry
    mockRegistry.setState(.downloadSuccessful, for: book.identifier)
    
    try? await Task.sleep(nanoseconds: 150_000_000) // 150ms
    
    let model2 = cache.model(for: book)
    
    // CRITICAL: This is the bug fix - cache should now invalidate this transition
    XCTAssertFalse(model1 === model2, "Cache MUST invalidate when failed changes to successful")
    XCTAssertEqual(model2.stableButtonState, .downloadSuccessful)
  }
  
  // MARK: - Clear Tests
  
  func testClearAllRemovesAllModels() {
    let book1 = createTestBook(id: "book-1")
    let book2 = createTestBook(id: "book-2")
    mockRegistry.addBook(book1, state: .downloadSuccessful)
    mockRegistry.addBook(book2, state: .downloadSuccessful)
    
    let model1Before = cache.model(for: book1)
    let model2Before = cache.model(for: book2)
    
    cache.clear()
    
    let model1After = cache.model(for: book1)
    let model2After = cache.model(for: book2)
    
    XCTAssertFalse(model1Before === model1After)
    XCTAssertFalse(model2Before === model2After)
  }
  
  func testInvalidateForSpecificBook() {
    let book1 = createTestBook(id: "book-1")
    let book2 = createTestBook(id: "book-2")
    mockRegistry.addBook(book1, state: .downloadSuccessful)
    mockRegistry.addBook(book2, state: .downloadSuccessful)
    
    let model1Before = cache.model(for: book1)
    let model2Before = cache.model(for: book2)
    
    cache.invalidate(for: book1.identifier)
    
    let model1After = cache.model(for: book1)
    let model2After = cache.model(for: book2)
    
    XCTAssertFalse(model1Before === model1After, "Invalidated book should have new model")
    XCTAssertTrue(model2Before === model2After, "Other books should keep same model")
  }
}
