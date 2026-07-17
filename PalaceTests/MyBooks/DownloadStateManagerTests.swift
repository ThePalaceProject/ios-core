//
//  DownloadStateManagerTests.swift
//  PalaceTests
//
//  Unit tests for DownloadStateManager: state tracking, progress queries,
//  cleanup, and reset operations.
//

import XCTest
@testable import Palace

@MainActor
final class DownloadStateManagerTests: XCTestCase {

    private var stateManager: DownloadStateManager!

    override func setUp() {
        super.setUp()
        stateManager = DownloadStateManager()
    }

    override func tearDown() {
        stateManager = nil
        super.tearDown()
    }

    // MARK: - Initialization

    func testInit_defaultMaxConcurrentDownloads() {
        XCTAssertEqual(stateManager.maxConcurrentDownloads, 4)
        // Default must be a positive integer (downloads must be enabled)
        XCTAssertGreaterThan(stateManager.maxConcurrentDownloads, 0,
                             "Default maxConcurrentDownloads must be positive")
    }

    func testInit_emptyCollections() async {
        let infoCount = await stateManager.bookIdentifierToDownloadInfo.count()
        let taskCount = await stateManager.bookIdentifierToDownloadTask.count()
        let bookCount = await stateManager.taskIdentifierToBook.count()

        XCTAssertEqual(infoCount, 0)
        XCTAssertEqual(taskCount, 0)
        XCTAssertEqual(bookCount, 0)
    }

    // MARK: - Download Info Async

    func testDownloadInfoAsync_existingEntry_returnsInfo() async {
        let bookId = "test-book-123"
        let task = fakeDownloadTask()
        let info = MyBooksDownloadInfo(downloadProgress: 0.5, downloadTask: task, rightsManagement: .none)

        await stateManager.bookIdentifierToDownloadInfo.set(bookId, value: info)

        let retrieved = await stateManager.downloadInfoAsync(forBookIdentifier: bookId)
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.downloadProgress, 0.5)
        XCTAssertEqual(retrieved?.rightsManagement, MyBooksDownloadInfo.MyBooksDownloadRightsManagement.none)
    }

    func testDownloadInfoAsync_missingEntry_returnsNil() async {
        let result = await stateManager.downloadInfoAsync(forBookIdentifier: "nonexistent")
        XCTAssertNil(result)
    }

    func testDownloadInfoAsync_cachesInCoordinator() async {
        let bookId = "cache-test"
        let task = fakeDownloadTask()
        let info = MyBooksDownloadInfo(downloadProgress: 0.3, downloadTask: task, rightsManagement: .lcp)

        await stateManager.bookIdentifierToDownloadInfo.set(bookId, value: info)
        _ = await stateManager.downloadInfoAsync(forBookIdentifier: bookId)

        // Verify it was cached in coordinator
        let cached = await stateManager.downloadCoordinator.getCachedDownloadInfo(for: bookId)
        XCTAssertNotNil(cached)
        XCTAssertEqual(cached?.rightsManagement, .lcp)
    }

    // MARK: - Download Info Sync (Legacy)

    func testDownloadInfo_sync_returnsNilForMissing() {
        let result = stateManager.downloadInfo(forBookIdentifier: "nonexistent")
        XCTAssertNil(result)
        // A different unknown ID must also return nil (not a cached fallback)
        let result2 = stateManager.downloadInfo(forBookIdentifier: "also-nonexistent")
        XCTAssertNil(result2, "Multiple unknown identifiers must all return nil")
    }

    // MARK: - Download Progress

    func testDownloadProgress_noInfo_returnsZero() {
        let progress = stateManager.downloadProgress(for: "no-such-book")
        XCTAssertEqual(progress, 0.0, accuracy: 0.001)
        // Must also return 0 for a different unknown identifier
        let progress2 = stateManager.downloadProgress(for: "another-unknown-book")
        XCTAssertEqual(progress2, 0.0, accuracy: 0.001,
                       "downloadProgress must return 0.0 for any unknown book identifier")
    }

    // MARK: - Cleanup

    func testCleanupDownload_removesAllTracking() async {
        let bookId = "cleanup-test"
        let taskId = 42
        let task = fakeDownloadTask()
        let info = MyBooksDownloadInfo(downloadProgress: 0.8, downloadTask: task, rightsManagement: .none)
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)

        await stateManager.bookIdentifierToDownloadInfo.set(bookId, value: info)
        await stateManager.taskIdentifierToBook.set(taskId, value: book)
        await stateManager.downloadCoordinator.cacheDownloadInfo(info, for: bookId)

        await stateManager.cleanupDownload(for: bookId, taskIdentifier: taskId)

        let infoAfter = await stateManager.bookIdentifierToDownloadInfo.get(bookId)
        let bookAfter = await stateManager.taskIdentifierToBook.get(taskId)
        let cachedAfter = await stateManager.downloadCoordinator.getCachedDownloadInfo(for: bookId)

        XCTAssertNil(infoAfter)
        XCTAssertNil(bookAfter)
        XCTAssertNil(cachedAfter)
    }

    func testCleanupDownload_withoutTaskId_stillCleansInfo() async {
        let bookId = "cleanup-no-task"
        let task = fakeDownloadTask()
        let info = MyBooksDownloadInfo(downloadProgress: 1.0, downloadTask: task, rightsManagement: .none)

        await stateManager.bookIdentifierToDownloadInfo.set(bookId, value: info)
        await stateManager.cleanupDownload(for: bookId)

        let infoAfter = await stateManager.bookIdentifierToDownloadInfo.get(bookId)
        XCTAssertNil(infoAfter)
    }

    // MARK: - Reset

    func testResetAll_clearsEverything() async {
        let task1 = fakeDownloadTask()
        let task2 = fakeDownloadTask()
        let info1 = MyBooksDownloadInfo(downloadProgress: 0.5, downloadTask: task1, rightsManagement: .none)
        let info2 = MyBooksDownloadInfo(downloadProgress: 0.7, downloadTask: task2, rightsManagement: .adobe)
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)

        await stateManager.bookIdentifierToDownloadInfo.set("book1", value: info1)
        await stateManager.bookIdentifierToDownloadInfo.set("book2", value: info2)
        await stateManager.taskIdentifierToBook.set(task1.taskIdentifier, value: book)

        await stateManager.resetAll()

        let infoCount = await stateManager.bookIdentifierToDownloadInfo.count()
        let taskCount = await stateManager.taskIdentifierToBook.count()

        XCTAssertEqual(infoCount, 0)
        XCTAssertEqual(taskCount, 0)
    }

    // MARK: - Thread-Safe Dictionaries

    func testBookIdentifierToDownloadTask_storesAndRetrieves() async {
        let task = fakeDownloadTask()
        await stateManager.bookIdentifierToDownloadTask.set("book-abc", value: task)

        let retrieved = await stateManager.bookIdentifierToDownloadTask.get("book-abc")
        XCTAssertNotNil(retrieved)
    }

    func testTaskIdentifierToBook_storesAndRetrieves() async {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        await stateManager.taskIdentifierToBook.set(99, value: book)

        let retrieved = await stateManager.taskIdentifierToBook.get(99)
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.identifier, book.identifier)
    }

    // MARK: - Item #12 — taskIdentifierToBook recycle safety

    /// Item #12 audit: simulates the URLSession.taskIdentifier recycle
    /// scenario the "907 No taskInfo for task" non-fatal hinted at.
    /// The canonical safe pattern is remove(oldTaskId) → set(newTaskId,
    /// book). Pin that explicit sequence: after the swap, the OLD
    /// entry is gone and ONLY the new mapping wins.
    func testTaskIdentifierToBook_recycleSameId_doesNotLeakOldBook() async {
        let bookA = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let bookB = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let taskId = 42

        // Step 1: register taskId → bookA (initial download started)
        await stateManager.taskIdentifierToBook.set(taskId, value: bookA)
        let firstLookup = await stateManager.taskIdentifierToBook.get(taskId)
        XCTAssertEqual(firstLookup?.identifier, bookA.identifier,
                       "Initial registration must resolve taskId → bookA")

        // Step 2: explicit remove (the canonical safe pattern call
        // sites use — e.g. BackgroundDownloadHandler.followAcquisitionLink
        // line 240, DownloadCancellationHandler line 126).
        let removed = await stateManager.taskIdentifierToBook.remove(taskId)
        XCTAssertEqual(removed?.identifier, bookA.identifier,
                       "remove() must return the old value so call sites can audit")

        // Step 3: register the same taskId → bookB (recycled).
        await stateManager.taskIdentifierToBook.set(taskId, value: bookB)
        let secondLookup = await stateManager.taskIdentifierToBook.get(taskId)
        XCTAssertEqual(secondLookup?.identifier, bookB.identifier,
                       "After remove-then-set, recycled taskId must resolve to bookB")
        XCTAssertNotEqual(secondLookup?.identifier, bookA.identifier,
                          "OLD bookA mapping MUST be gone after remove() — no stale entry")
    }

    /// Anti-pattern (intentional contract): set-before-remove on the
    /// same taskId overwrites. Pins that the map has standard
    /// dictionary semantics so call sites can rely on a single
    /// register-step when there's no chained-task swap.
    func testTaskIdentifierToBook_setBeforeRemove_intentionalOverwrite() async {
        let bookA = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let bookB = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let taskId = 17

        await stateManager.taskIdentifierToBook.set(taskId, value: bookA)
        // No remove call — directly overwrite.
        await stateManager.taskIdentifierToBook.set(taskId, value: bookB)

        let result = await stateManager.taskIdentifierToBook.get(taskId)
        XCTAssertEqual(result?.identifier, bookB.identifier,
                       "set() must overwrite the prior value at the same key")

        let count = await stateManager.taskIdentifierToBook.count()
        XCTAssertEqual(count, 1,
                       "Overwrite must NOT create a duplicate entry; count stays 1")
    }

    /// `cleanupDownload(taskIdentifier:)` removes the OLD taskIdentifier
    /// entry. Pin that the post-cleanup state cannot return the old
    /// book from any taskIdentifier — the cleanup is the contract.
    func testCleanupDownload_removesOldTaskIdEntry() async {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let oldTaskId = 100

        await stateManager.taskIdentifierToBook.set(oldTaskId, value: book)
        await stateManager.bookIdentifierToDownloadInfo.set(book.identifier,
            value: MyBooksDownloadInfo(
                downloadProgress: 0.5,
                downloadTask: fakeDownloadTask(),
                rightsManagement: .none))

        await stateManager.cleanupDownload(for: book.identifier, taskIdentifier: oldTaskId)

        let oldEntry = await stateManager.taskIdentifierToBook.get(oldTaskId)
        XCTAssertNil(oldEntry,
                     "cleanupDownload must remove the OLD taskIdentifier so a recycled ID can't resolve to a stale book")
    }

    // MARK: - Concurrent Access Safety

    func testConcurrentAccess_doesNotCrash() async {
        let bookId = "concurrent-test"
        let task = fakeDownloadTask()
        let info = MyBooksDownloadInfo(downloadProgress: 0.0, downloadTask: task, rightsManagement: .none)

        // Run many concurrent reads and writes
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<50 {
                group.addTask {
                    let id = "\(bookId)-\(i)"
                    await self.stateManager.bookIdentifierToDownloadInfo.set(id, value: info)
                    _ = await self.stateManager.downloadInfoAsync(forBookIdentifier: id)
                    await self.stateManager.bookIdentifierToDownloadInfo.remove(id)
                }
            }
        }
        // After all concurrent tasks complete, all entries must have been removed
        let finalCount = await stateManager.bookIdentifierToDownloadInfo.count()
        XCTAssertEqual(finalCount, 0, "All concurrent remove() calls must complete, leaving count=0")
    }

}
