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
        cache = BookCellModelCache(
            imageCache: mockImageCache,
            bookRegistry: mockRegistry,
            downloadCenter: AppContainer.production().downloadCenter,
            accountsManager: AppContainer.production().accountsManager,
            samplePreviewManager: AppContainer.production().samplePreviewManager,
            readerService: AppContainer.production().readerService
        )
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

    /// Regression for the wandering CI test-host crash. `.TPPCurrentAccountDidChange`
    /// is posted from whatever thread performs an account switch — often OFF-MAIN
    /// (sign-in / account-switch completions fire on the URLSession delegate queue
    /// because `TPPNetworkExecutor` uses `delegateQueue: nil`). `BookCellModelCache`
    /// is `@MainActor` and its account-change handler mutates main-actor
    /// `cache`/`accessOrder`. Before the `.receive(on: DispatchQueue.main)` fix on
    /// the observer, an off-main post delivered that handler OFF-MAIN → Swift 6
    /// `swift_task_checkIsolated` SIGTRAP → the whole sim-clone process died,
    /// surfacing as an innocent `(0.000s)` collateral failure elsewhere.
    ///
    /// This drives the exact scenario (post off-main) and asserts the cache was
    /// cleared on main — a NEW model instance proves the `@MainActor` handler ran
    /// to completion instead of trapping. With the pre-fix bare `.sink` this test
    /// would crash the host rather than fail.
    func testAccountChange_postedOffMain_clearsCacheOnMain_withoutTrapping() async {
        let book = createTestBook()
        mockRegistry.addBook(book, state: .downloadSuccessful)
        let modelBefore = cache.model(for: book)

        // Post from a background thread — the off-main crash scenario. `async`
        // (NOT `sync`, which runs on the calling/main thread) guarantees off-main;
        // the continuation resumes only after the post has been delivered into the
        // Combine subscription (and the `.receive(on: .main)` hop enqueued).
        let bg = DispatchQueue(label: "regression.offmain.accountchange")
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            bg.async {
                XCTAssertFalse(Thread.isMainThread, "precondition: the post must be off-main")
                NotificationCenter.default.post(name: .TPPCurrentAccountDidChange, object: nil)
                cont.resume()
            }
        }

        // The `.receive(on: .main)` block was enqueued during the sync post above,
        // so subsequent main hops run strictly after it (FIFO) — a deterministic
        // drain, not a wall-clock poll.
        await Task { @MainActor in }.value
        await Task { @MainActor in }.value

        let modelAfter = cache.model(for: book)
        XCTAssertFalse(modelBefore === modelAfter,
                       "an account change posted off-main must clear the cache on main; a new model proves the @MainActor handler ran without trapping")
    }
}
