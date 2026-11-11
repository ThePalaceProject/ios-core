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
import PalaceBookModel

@MainActor
final class BookCellModelCacheInvalidationTests: XCTestCase {

    var mockRegistry: TPPBookRegistryMock!
    var mockImageCache: MockImageCache!
    var cache: BookCellModelCache!
    var cancellables: Set<AnyCancellable>!
    /// The cache's own manager, so a library change sent here reaches only
    /// this cache and not the host app's listeners.
    var accountsManager: AccountsManager!

    override func setUp() {
        super.setUp()
        mockRegistry = TPPBookRegistryMock()
        mockImageCache = MockImageCache()
        accountsManager = makeTestAppContainer().accountsManager
        cache = BookCellModelCache(
            imageCache: mockImageCache,
            bookRegistry: mockRegistry,
            downloadCenter: AppContainer.production().downloadCenter,
            accountsManager: accountsManager,
            samplePreviewManager: AppContainer.production().samplePreviewManager,
            readerService: AppContainer.production().readerService,
            bookOpenDependencies: .testDouble()
        )
        cancellables = Set<AnyCancellable>()
    }

    override func tearDown() {
        cache.clear()
        cancellables = nil
        cache = nil
        accountsManager = nil
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

    // MARK: - Direct Invalidation Tests (No Timing Dependencies)

    func testCacheInvalidatesOnDirectInvalidation() {
        let book = createTestBook()
        mockRegistry.addBook(book, state: .downloadFailed)

        let model1 = cache.model(for: book)
        XCTAssertEqual(model1.registryState, .downloadFailed)

        // Update registry state and directly invalidate cache
        mockRegistry.setState(.downloadSuccessful, for: book.identifier)
        cache.invalidate(for: book.identifier)

        let model2 = cache.model(for: book)

        // Should be a new model with correct state
        XCTAssertFalse(model1 === model2, "Cache should return a new model after invalidation")
        XCTAssertEqual(model2.registryState, .downloadSuccessful)
    }

    func testCacheInvalidatesDownloadingToSuccessful() {
        let book = createTestBook()
        mockRegistry.addBook(book, state: .downloading)

        let model1 = cache.model(for: book)
        XCTAssertEqual(model1.stableButtonState, .downloadInProgress)

        // Simulate download completion with direct invalidation
        mockRegistry.setState(.downloadSuccessful, for: book.identifier)
        cache.invalidate(for: book.identifier)

        let model2 = cache.model(for: book)
        XCTAssertFalse(model1 === model2, "Cache should invalidate when download completes")
        XCTAssertEqual(model2.stableButtonState, .downloadSuccessful)
    }

    func testCacheInvalidatesDownloadingToFailed() {
        let book = createTestBook()
        mockRegistry.addBook(book, state: .downloading)

        let model1 = cache.model(for: book)

        // Simulate download failure with direct invalidation
        mockRegistry.setState(.downloadFailed, for: book.identifier)
        cache.invalidate(for: book.identifier)

        let model2 = cache.model(for: book)
        XCTAssertFalse(model1 === model2, "Cache should invalidate when download fails")
        XCTAssertEqual(model2.stableButtonState, .downloadFailed)
    }

    func testCacheInvalidatesFailedToSuccessful() {
        let book = createTestBook()
        mockRegistry.addBook(book, state: .downloadFailed)

        let model1 = cache.model(for: book)
        XCTAssertEqual(model1.stableButtonState, .downloadFailed)

        // Simulate successful retry with direct invalidation
        mockRegistry.setState(.downloadSuccessful, for: book.identifier)
        cache.invalidate(for: book.identifier)

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

    // MARK: - Off-main account-change regression (Swift 6 checkIsolated SIGTRAP)

    /// A library change sent off the main thread clears the `@MainActor` cache
    /// on main. Running the handler off main traps under Swift 6
    /// (`swift_task_checkIsolated`) and takes the test host down. A NEW model
    /// instance proves the handler ran to completion.
    func testAccountChange_postedOffMain_clearsCacheOnMain_withoutTrapping() async {
        let book = createTestBook()
        mockRegistry.addBook(book, state: .downloadSuccessful)
        let modelBefore = cache.model(for: book)

        // `async`, not `sync`: `sync` runs the block on the calling (main) thread.
        let manager: AccountsManager = accountsManager
        let bg = DispatchQueue(label: "regression.offmain.accountchange")
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            bg.async {
                XCTAssertFalse(Thread.isMainThread, "precondition: the send must be off-main")
                manager.requestCurrentLibraryRefresh()
                cont.resume()
            }
        }

        // Two main-queue hops follow the send: the broadcaster's and the cache's
        // own `.receive(on:)`. Each drain runs after everything already queued.
        await drainMainQueueAsync()
        await drainMainQueueAsync()

        let modelAfter = cache.model(for: book)
        XCTAssertFalse(modelBefore === modelAfter,
                       "a library change sent off-main must clear the cache on main; a new model proves the @MainActor handler ran without trapping")
    }
}
