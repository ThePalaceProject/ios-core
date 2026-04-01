//
//  DownloadStateManagerTests.swift
//  PalaceTests
//
//  Unit tests for DownloadStateManager: state tracking, progress queries,
//  cleanup, and reset operations.
//

import XCTest
@testable import Palace

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
        let task = URLSession.shared.downloadTask(with: URL(string: "https://example.com")!)
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
        let task = URLSession.shared.downloadTask(with: URL(string: "https://example.com")!)
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
    }

    // MARK: - Download Progress

    func testDownloadProgress_noInfo_returnsZero() {
        let progress = stateManager.downloadProgress(for: "no-such-book")
        XCTAssertEqual(progress, 0.0, accuracy: 0.001)
    }

    // MARK: - Cleanup

    func testCleanupDownload_removesAllTracking() async {
        let bookId = "cleanup-test"
        let taskId = 42
        let task = URLSession.shared.downloadTask(with: URL(string: "https://example.com")!)
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
        let task = URLSession.shared.downloadTask(with: URL(string: "https://example.com")!)
        let info = MyBooksDownloadInfo(downloadProgress: 1.0, downloadTask: task, rightsManagement: .none)

        await stateManager.bookIdentifierToDownloadInfo.set(bookId, value: info)
        await stateManager.cleanupDownload(for: bookId)

        let infoAfter = await stateManager.bookIdentifierToDownloadInfo.get(bookId)
        XCTAssertNil(infoAfter)
    }

    // MARK: - Reset

    func testResetAll_clearsEverything() async {
        let task1 = URLSession.shared.downloadTask(with: URL(string: "https://example.com/1")!)
        let task2 = URLSession.shared.downloadTask(with: URL(string: "https://example.com/2")!)
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
        let task = URLSession.shared.downloadTask(with: URL(string: "https://example.com")!)
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

    // MARK: - Concurrent Access Safety

    func testConcurrentAccess_doesNotCrash() async {
        let bookId = "concurrent-test"
        let task = URLSession.shared.downloadTask(with: URL(string: "https://example.com")!)
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
        // Should complete without crash
    }

    // MARK: - Max Concurrent Downloads

    func testMaxConcurrentDownloads_canBeChanged() {
        stateManager.maxConcurrentDownloads = 8
        XCTAssertEqual(stateManager.maxConcurrentDownloads, 8)

        stateManager.maxConcurrentDownloads = 1
        XCTAssertEqual(stateManager.maxConcurrentDownloads, 1)
    }
}
