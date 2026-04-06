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

    // MARK: - Model Updates

    func testModelUpdatesWhenBookChanges() async throws {
        let book1 = makeTestBook(identifier: "book1", title: "Original Title")

        let model = sut.model(for: book1)
        XCTAssertEqual(model.book.title, "Original Title")

        // Create updated book with same identifier but different title
        let book2 = makeTestBook(identifier: "book1", title: "Updated Title", updated: Date())

        let updatedModel = sut.model(for: book2)

        // Should be same model instance
        XCTAssertTrue(model === updatedModel)

        // Yield to allow the deferred Task { @MainActor } to run before asserting.
        // Task.yield() suspends the current task so queued main-actor work can execute.
        await Task.yield(); await Task.yield(); await Task.yield()
        XCTAssertEqual(updatedModel.book.title, "Updated Title")
    }

    /// Tests direct invalidation of downloading models
    /// Bug fix: XXXX - Stale downloading cells showing after download completes
    func testDirectInvalidation_RefreshesModel() throws {
        let observingCache = BookCellModelCache(
            configuration: .init(
                maxEntries: 10,
                unusedTTL: 5,
                observeRegistryChanges: false
            ),
            imageCache: mockImageCache,
            bookRegistry: mockBookRegistry
        )

        let book = makeTestBook(identifier: "downloadingBook", title: "Test Book")

        // Set book to downloading state
        mockBookRegistry.addBook(
            book,
            location: nil,
            state: .downloading,
            fulfillmentId: nil,
            readiumBookmarks: nil,
            genericBookmarks: nil
        )

        let model1 = observingCache.model(for: book)
        XCTAssertEqual(model1.state.buttonState, .downloadInProgress)

        // Simulate download completion and direct invalidation
        mockBookRegistry.setState(.downloadSuccessful, for: book.identifier)
        observingCache.invalidate(for: book.identifier)

        let model2 = observingCache.model(for: book)

        XCTAssertFalse(model1 === model2, "Should return new model after invalidation")
        XCTAssertEqual(model2.state.buttonState, .downloadSuccessful)
    }

    /// Tests that cache invalidation works for any state transition
    func testDirectInvalidation_WorksForStateTransitions() throws {
        let cache = BookCellModelCache(
            configuration: .init(
                maxEntries: 10,
                unusedTTL: 5,
                observeRegistryChanges: false
            ),
            imageCache: mockImageCache,
            bookRegistry: mockBookRegistry
        )

        let book = makeTestBook(identifier: "activeDownload", title: "Active Download")

        mockBookRegistry.addBook(
            book,
            location: nil,
            state: .downloadNeeded,
            fulfillmentId: nil,
            readiumBookmarks: nil,
            genericBookmarks: nil
        )

        let model1 = cache.model(for: book)
        XCTAssertEqual(model1.state.buttonState, .downloadNeeded)

        // Change state and invalidate
        mockBookRegistry.setState(.downloading, for: book.identifier)
        cache.invalidate(for: book.identifier)

        let model2 = cache.model(for: book)

        XCTAssertFalse(model1 === model2, "State change with invalidation should create new model")
        XCTAssertEqual(model2.state.buttonState, .downloadInProgress)
    }

    /// Tests that cache invalidation works for holding state transition
    func testDirectInvalidation_WorksForHoldingState() throws {
        let cache = BookCellModelCache(
            configuration: .init(
                maxEntries: 10,
                unusedTTL: 5,
                observeRegistryChanges: false
            ),
            imageCache: mockImageCache,
            bookRegistry: mockBookRegistry
        )

        let book = makeTestBook(identifier: "holdBook", title: "Hold Book")

        mockBookRegistry.addBook(
            book,
            location: nil,
            state: .downloading,
            fulfillmentId: nil,
            readiumBookmarks: nil,
            genericBookmarks: nil
        )

        let model1 = cache.model(for: book)
        XCTAssertEqual(model1.state.buttonState, .downloadInProgress)

        // Transition to holding and invalidate
        mockBookRegistry.setState(.holding, for: book.identifier)
        cache.invalidate(for: book.identifier)

        let model2 = cache.model(for: book)

        XCTAssertFalse(model1 === model2, "Cache should create new model after invalidation")
        XCTAssertEqual(model2.state.buttonState, .holding)
    }

    // MARK: - Edge Case Tests

    func testCacheWithSameIdentifierDifferentUpdatedDate() async throws {
        let oldDate = Date(timeIntervalSince1970: 1000)
        let newDate = Date(timeIntervalSince1970: 2000)

        let oldBook = makeTestBook(identifier: "same-id", title: "Old Title", updated: oldDate)
        let newBook = makeTestBook(identifier: "same-id", title: "New Title", updated: newDate)

        _ = sut.model(for: oldBook)
        let model = sut.model(for: newBook)

        // Yield to allow the deferred Task { @MainActor } to run before asserting.
        await Task.yield(); await Task.yield(); await Task.yield()

        // Model should have updated to new book data
        XCTAssertEqual(model.book.title, "New Title")
        XCTAssertEqual(sut.count, 1)
    }

    func testConcurrentAccess_DoesNotCrash() async throws {
        let books = (0..<20).map { makeTestBook(identifier: "concurrent-\($0)", title: "Book \($0)") }

        // Simulate concurrent access patterns
        await withTaskGroup(of: Void.self) { group in
            for book in books {
                group.addTask { @MainActor in
                    _ = self.sut.model(for: book)
                }
            }
        }

        XCTAssertGreaterThan(sut.count, 0)
        XCTAssertLessThanOrEqual(sut.count, 20)
    }

    func testInvalidateNonExistentKey_DoesNotCrash() throws {
        // Invalidating a key that doesn't exist should not crash
        sut.invalidate(for: "non-existent-key")

        XCTAssertEqual(sut.count, 0)
    }

    func testClearEmptyCache_DoesNotCrash() throws {
        // Clearing an empty cache should not crash
        sut.clear()

        XCTAssertEqual(sut.count, 0)
    }

    func testMemoryWarningOnEmptyCache_DoesNotCrash() throws {
        sut.handleMemoryWarning()

        XCTAssertEqual(sut.count, 0)
    }

    func testPreloadEmptyArray_DoesNotCrash() throws {
        sut.preload(books: [])

        XCTAssertEqual(sut.count, 0)
    }

    func testPrefetchWithEmptyRange_DoesNotCrash() throws {
        let books = [makeTestBook(identifier: "book1", title: "Book")]

        sut.prefetch(books: books, visibleRange: 0..<0, buffer: 0)

        // Should not crash
        XCTAssertTrue(true)
    }

    // MARK: - Configuration Tests

    func testDefaultConfiguration_HasReasonableValues() {
        let defaultConfig = BookCellModelCache.Configuration.default

        XCTAssertGreaterThan(defaultConfig.maxEntries, 0)
        XCTAssertGreaterThan(defaultConfig.unusedTTL, 0)
        XCTAssertTrue(defaultConfig.observeRegistryChanges)
    }

    func testAggressiveConfiguration_HasLargerValues() {
        let defaultConfig = BookCellModelCache.Configuration.default
        let aggressiveConfig = BookCellModelCache.Configuration.aggressive

        XCTAssertGreaterThan(aggressiveConfig.maxEntries, defaultConfig.maxEntries)
        XCTAssertGreaterThan(aggressiveConfig.unusedTTL, defaultConfig.unusedTTL)
    }

    // MARK: - Deferred Update Tests (SwiftUI Warning Fix)

    /// Tests that when a book is updated, the cache defers the model update
    /// to avoid "Publishing changes from within view updates" warning.
    func testModelUpdate_WithNewerBook_DefersUpdateToTask() async throws {
        let oldDate = Date(timeIntervalSince1970: 1000)
        let newDate = Date(timeIntervalSince1970: 2000)

        let oldBook = makeTestBook(identifier: "deferred-test", title: "Old Title", updated: oldDate)
        let newBook = makeTestBook(identifier: "deferred-test", title: "New Title", updated: newDate)

        // First call caches the model
        let model = sut.model(for: oldBook)
        XCTAssertEqual(model.book.updated, oldDate)

        // Second call with newer book triggers deferred update
        let sameModel = sut.model(for: newBook)
        XCTAssertTrue(model === sameModel, "Should return same model instance")

        // Yield to allow the deferred Task { @MainActor } to run before asserting.
        await Task.yield(); await Task.yield(); await Task.yield()

        // After the deferred update, the model should have the new book
        XCTAssertEqual(model.book.updated, newDate)
        XCTAssertEqual(model.book.title, "New Title")
    }

    /// Tests that the cache doesn't update when the book hasn't changed
    func testModelUpdate_WithSameBook_DoesNotUpdate() throws {
        let book = makeTestBook(identifier: "no-update-test", title: "Same Book")

        let model1 = sut.model(for: book)
        let originalBook = model1.book

        let model2 = sut.model(for: book)

        XCTAssertTrue(model1 === model2)
        // Book should not have been modified
        XCTAssertEqual(model1.book.identifier, originalBook.identifier)
    }

    /// Tests that older book versions don't trigger updates
    func testModelUpdate_WithOlderBook_DoesNotUpdate() async throws {
        let oldDate = Date(timeIntervalSince1970: 1000)
        let newDate = Date(timeIntervalSince1970: 2000)

        let newBook = makeTestBook(identifier: "older-test", title: "New Title", updated: newDate)
        let oldBook = makeTestBook(identifier: "older-test", title: "Old Title", updated: oldDate)

        // Cache the newer book first
        let model = sut.model(for: newBook)
        XCTAssertEqual(model.book.title, "New Title")

        // Request with older book - should not update
        let sameModel = sut.model(for: oldBook)
        XCTAssertTrue(model === sameModel)

        // Yield to allow any deferred Task { @MainActor } a chance to run (it shouldn't update)
        await Task.yield(); await Task.yield(); await Task.yield()

        // Book should still be the newer version
        XCTAssertEqual(model.book.title, "New Title")
        XCTAssertEqual(model.book.updated, newDate)
    }

    // MARK: - Helpers

    private func makeTestBook(identifier: String, title: String, updated: Date = Date(timeIntervalSince1970: 0)) -> TPPBook {
        return TPPBookMocker.mockBook(identifier: identifier, title: title, authors: "Test Author", updated: updated)
    }
}
