//
//  BookCellModelCacheTests.swift
//  PalaceTests
//
//  Tests for BookCellModel caching and performance optimizations
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

@MainActor
final class BookCellModelCacheTests: XCTestCase {
  
  var sut: BookCellModelCache!
  var mockImageCache: MockImageCache!
  var mockBookRegistry: TPPBookRegistryMock!
  
  override func setUp() async throws {
    try await super.setUp()
    mockImageCache = MockImageCache()
    mockBookRegistry = TPPBookRegistryMock()
    
    sut = BookCellModelCache(
      configuration: .init(
        maxEntries: 10,
        unusedTTL: 5,
        observeRegistryChanges: false
      ),
      imageCache: mockImageCache,
      bookRegistry: mockBookRegistry
    )
  }
  
  override func tearDown() async throws {
    sut = nil
    mockImageCache = nil
    mockBookRegistry = nil
    try await super.tearDown()
  }
  
  // MARK: - Basic Cache Operations
  
  func testModelCreation() throws {
    let book = makeTestBook(identifier: "book1", title: "Test Book")
    
    let model = sut.model(for: book)
    
    XCTAssertEqual(model.book.identifier, "book1")
    XCTAssertEqual(model.book.title, "Test Book")
  }
  
  func testModelReuse() throws {
    let book = makeTestBook(identifier: "book1", title: "Test Book")
    
    let model1 = sut.model(for: book)
    let model2 = sut.model(for: book)
    
    // Should be the same instance
    XCTAssertTrue(model1 === model2, "Cache should return same model instance")
  }
  
  func testDifferentBooksGetDifferentModels() throws {
    let book1 = makeTestBook(identifier: "book1", title: "Book 1")
    let book2 = makeTestBook(identifier: "book2", title: "Book 2")
    
    let model1 = sut.model(for: book1)
    let model2 = sut.model(for: book2)
    
    XCTAssertFalse(model1 === model2, "Different books should get different models")
    XCTAssertEqual(sut.count, 2)
  }
  
  func testInvalidate() throws {
    let book = makeTestBook(identifier: "book1", title: "Test Book")
    
    let model1 = sut.model(for: book)
    sut.invalidate(for: "book1")
    let model2 = sut.model(for: book)
    
    XCTAssertFalse(model1 === model2, "Should create new model after invalidation")
  }
  
  func testInvalidateMultiple() throws {
    let book1 = makeTestBook(identifier: "book1", title: "Book 1")
    let book2 = makeTestBook(identifier: "book2", title: "Book 2")
    let book3 = makeTestBook(identifier: "book3", title: "Book 3")
    
    _ = sut.model(for: book1)
    _ = sut.model(for: book2)
    _ = sut.model(for: book3)
    
    XCTAssertEqual(sut.count, 3)
    
    sut.invalidate(for: ["book1", "book2"])
    
    XCTAssertEqual(sut.count, 1)
  }
  
  func testClear() throws {
    let book1 = makeTestBook(identifier: "book1", title: "Book 1")
    let book2 = makeTestBook(identifier: "book2", title: "Book 2")
    
    _ = sut.model(for: book1)
    _ = sut.model(for: book2)
    
    sut.clear()
    
    XCTAssertEqual(sut.count, 0)
  }
  
  // MARK: - LRU Eviction
  
  func testLRUEviction() throws {
    // Fill cache to capacity (10)
    for i in 0..<10 {
      let book = makeTestBook(identifier: "book\(i)", title: "Book \(i)")
      _ = sut.model(for: book)
    }
    
    XCTAssertEqual(sut.count, 10)
    
    // Add one more to trigger eviction
    let newBook = makeTestBook(identifier: "newbook", title: "New Book")
    _ = sut.model(for: newBook)
    
    // Should have evicted ~10% (at least 1)
    XCTAssertLessThanOrEqual(sut.count, 10)
  }
  
  // MARK: - Preloading
  
  func testPreload() throws {
    let books = (0..<5).map { makeTestBook(identifier: "book\($0)", title: "Book \($0)") }
    
    sut.preload(books: books)
    
    XCTAssertEqual(sut.count, 5)
    
    // Models should already be cached
    for book in books {
      let model1 = sut.model(for: book)
      let model2 = sut.model(for: book)
      XCTAssertTrue(model1 === model2)
    }
  }
  
  // MARK: - Memory Warning
  
  func testMemoryWarning() throws {
    // Fill cache
    for i in 0..<10 {
      let book = makeTestBook(identifier: "book\(i)", title: "Book \(i)")
      _ = sut.model(for: book)
    }
    
    XCTAssertEqual(sut.count, 10)
    
    sut.handleMemoryWarning()
    
    // Should keep only 25% (2-3 entries)
    XCTAssertLessThanOrEqual(sut.count, 3)
  }
  
  // MARK: - Prefetching
  
  func testPrefetchWithVisibleRange() throws {
    let books = (0..<20).map { makeTestBook(identifier: "book\($0)", title: "Book \($0)") }
    
    // Initially no models
    XCTAssertEqual(sut.count, 0)
    
    // Prefetch with visible range 5..<10, buffer 3
    sut.prefetch(books: books, visibleRange: 5..<10, buffer: 3)
    
    // Wait a tiny bit for the Task to execute
    let expectation = expectation(description: "Prefetch")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
      expectation.fulfill()
    }
    wait(for: [expectation], timeout: 1.0)
    
    // Should have prefetched range 2..<13 (5-3 to 10+3)
    // That's 11 items
    XCTAssertGreaterThan(sut.count, 0)
  }
  
  // MARK: - Model Updates
  
  func testModelUpdatesWhenBookChanges() throws {
    let book1 = makeTestBook(identifier: "book1", title: "Original Title")
    
    let model = sut.model(for: book1)
    XCTAssertEqual(model.book.title, "Original Title")
    
    // Create updated book with same identifier but different title
    // Note: In real usage, the updated date would also change
    let book2 = makeTestBook(identifier: "book1", title: "Updated Title", updated: Date())
    
    let updatedModel = sut.model(for: book2)
    
    // Should be same model instance but with updated book
    XCTAssertTrue(model === updatedModel)
    XCTAssertEqual(updatedModel.book.title, "Updated Title")
  }
  
  // MARK: - Helpers
  
  private func makeTestBook(identifier: String, title: String, updated: Date = Date(timeIntervalSince1970: 0)) -> TPPBook {
    return TPPBookMocker.mockBook(identifier: identifier, title: title, authors: "Test Author", updated: updated)
  }
}
