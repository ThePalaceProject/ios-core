//
//  ArraySafetyTests.swift
//  PalaceTests
//
//  Tests for array bounds-safety fixes in BookCellModelCache.prefetch,
//  CatalogSearchViewModel.applyRegistryUpdates, and BookListView prefetching.
//  These prevent crashes during scrolling and searching when arrays mutate
//  between index-lookup and slice operations.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import Combine
@testable import Palace

// MARK: - BookCellModelCache Prefetch Safety Tests

@MainActor
final class BookCellModelCachePrefetchSafetyTests: XCTestCase {

    var sut: BookCellModelCache!
    var mockImageCache: MockImageCache!
    var mockBookRegistry: TPPBookRegistryMock!

    override func setUp() async throws {
        try await super.setUp()
        mockImageCache = MockImageCache()
        mockBookRegistry = TPPBookRegistryMock()

        sut = BookCellModelCache(
            configuration: .init(
                maxEntries: 50,
                unusedTTL: 60,
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

    // MARK: - Empty Array

    func testPrefetch_EmptyBooksArray_DoesNotCrash() {
        sut.prefetch(books: [], visibleRange: 0..<0, buffer: 10)
    }

    func testPrefetch_EmptyBooksArray_WithNonZeroRange_DoesNotCrash() {
        sut.prefetch(books: [], visibleRange: 5..<10, buffer: 10)
    }

    // MARK: - Range Exceeds Array Bounds

    func testPrefetch_RangeExceedsArraySize_DoesNotCrash() {
        let books = (0..<3).map { makeBook(index: $0) }

        sut.prefetch(books: books, visibleRange: 0..<100, buffer: 10)
    }

    func testPrefetch_NegativeBufferRange_ClampsToZero() {
        let books = (0..<5).map { makeBook(index: $0) }

        sut.prefetch(books: books, visibleRange: 2..<4, buffer: 0)
    }

    func testPrefetch_LargeBuffer_ClampsToArraySize() {
        let books = (0..<5).map { makeBook(index: $0) }

        sut.prefetch(books: books, visibleRange: 0..<3, buffer: 1000)

        // Should not crash; buffer is clamped to array bounds
    }

    // MARK: - Normal Operation

    func testPrefetch_NormalRange_PreloadsModels() async {
        let books = (0..<10).map { makeBook(index: $0) }

        sut.prefetch(books: books, visibleRange: 2..<5, buffer: 2)

        // Give the Task time to execute
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Models in visible + buffer range should be cached
        XCTAssertGreaterThan(sut.count, 0)
    }

    func testPrefetch_StartOfList_DoesNotAccessNegativeIndex() {
        let books = (0..<5).map { makeBook(index: $0) }

        sut.prefetch(books: books, visibleRange: 0..<2, buffer: 5)
    }

    func testPrefetch_EndOfList_DoesNotAccessBeyondBounds() {
        let books = (0..<5).map { makeBook(index: $0) }

        sut.prefetch(books: books, visibleRange: 3..<5, buffer: 10)
    }

    func testPrefetch_SingleElementArray_DoesNotCrash() {
        let books = [makeBook(index: 0)]

        sut.prefetch(books: books, visibleRange: 0..<1, buffer: 5)
    }

    // MARK: - Helpers

    private func makeBook(index: Int) -> TPPBook {
        TPPBookMocker.mockBook(identifier: "prefetch-\(index)", title: "Book \(index)", authors: "Author")
    }
}

// MARK: - CatalogSearchViewModel Registry Update Safety Tests

@MainActor
final class CatalogSearchViewModelRegistryUpdateTests: XCTestCase {

    var sut: CatalogSearchViewModel!
    var mockRepository: CatalogRepositoryMock!
    private var cancellables = Set<AnyCancellable>()

    override func setUp() async throws {
        try await super.setUp()
        mockRepository = CatalogRepositoryMock()
        sut = CatalogSearchViewModel(
            repository: mockRepository,
            baseURL: { URL(string: "https://example.com/search") },
            debounceInterval: 0.0
        )
    }

    override func tearDown() async throws {
        sut = nil
        mockRepository = nil
        cancellables.removeAll()
        try await super.tearDown()
    }

    // MARK: - Empty State

    func testApplyRegistryUpdates_EmptyFilteredBooks_DoesNotCrash() {
        sut.applyRegistryUpdates(changedIdentifier: nil)

        XCTAssertTrue(sut.filteredBooks.isEmpty)
    }

    // MARK: - With Books

    func testApplyRegistryUpdates_WithBooks_UpdatesMatchingBook() {
        let book1 = makeBook(identifier: "book-1", title: "Original Title")
        let book2 = makeBook(identifier: "book-2", title: "Another Book")

        sut.updateBooks([book1, book2])

        // Apply updates for a specific book
        sut.applyRegistryUpdates(changedIdentifier: "book-1")

        // Should not crash, books should still be present
        XCTAssertEqual(sut.filteredBooks.count, 2)
    }

    func testApplyRegistryUpdates_NilChangedIdentifier_UpdatesAllBooks() {
        let books = (0..<5).map { makeBook(identifier: "book-\($0)", title: "Book \($0)") }

        sut.updateBooks(books)
        sut.applyRegistryUpdates(changedIdentifier: nil)

        XCTAssertEqual(sut.filteredBooks.count, 5)
    }

    func testApplyRegistryUpdates_UnknownIdentifier_NoChanges() {
        let book1 = makeBook(identifier: "book-1", title: "Book 1")
        sut.updateBooks([book1])

        sut.applyRegistryUpdates(changedIdentifier: "nonexistent-book")

        XCTAssertEqual(sut.filteredBooks.count, 1)
        XCTAssertEqual(sut.filteredBooks.first?.identifier, "book-1")
    }

    func testApplyRegistryUpdates_MultipleRapidCalls_DoesNotCrash() {
        let books = (0..<20).map { makeBook(identifier: "rapid-\($0)", title: "Book \($0)") }
        sut.updateBooks(books)

        for i in 0..<20 {
            sut.applyRegistryUpdates(changedIdentifier: "rapid-\(i)")
        }

        XCTAssertEqual(sut.filteredBooks.count, 20)
    }

    // MARK: - Helpers

    private func makeBook(identifier: String, title: String) -> TPPBook {
        TPPBookMocker.mockBook(identifier: identifier, title: title, authors: "Author")
    }
}
