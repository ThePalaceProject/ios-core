//
//  DownloadStateManager.swift
//  Palace
//
//  Extracted from MyBooksDownloadCenter to provide single-responsibility
//  download state tracking. Manages download info storage, state queries,
//  and the download coordinator (throttling, queuing, concurrency).
//

import Foundation
import Combine

// MARK: - DownloadStateManaging Protocol

protocol DownloadStateManaging: AnyObject {
    /// Thread-safe dictionaries for download tracking
    var bookIdentifierToDownloadInfo: SafeDictionary<String, MyBooksDownloadInfo> { get }
    var bookIdentifierToDownloadTask: SafeDictionary<String, URLSessionDownloadTask> { get }
    var taskIdentifierToBook: SafeDictionary<Int, TPPBook> { get }

    /// The download coordinator (actor-based concurrency control)
    var downloadCoordinator: DownloadCoordinator { get }

    /// Maximum concurrent downloads allowed
    var maxConcurrentDownloads: Int { get set }

    /// Async download info accessor with cache update
    func downloadInfoAsync(forBookIdentifier bookIdentifier: String) async -> MyBooksDownloadInfo?

    /// Synchronous download info accessor for legacy compatibility
    func downloadInfo(forBookIdentifier bookIdentifier: String) -> MyBooksDownloadInfo?

    /// Download progress query
    func downloadProgress(for bookIdentifier: String) -> Double
}

// MARK: - DownloadStateManager

/// Manages all download state tracking: what is downloading, progress, errors,
/// and concurrency coordination via the DownloadCoordinator actor.
/// `@unchecked Sendable`: every stored member is either an immutable `let`
/// binding to a `Sendable` collaborator (the `SafeDictionary` actors, the
/// `DownloadCoordinator`, `taskPersistence`) or the lock-guarded
/// `maxConcurrentDownloads` below. The manager is genuinely safe to reference
/// across concurrency domains — e.g. `cleanupDownload` awaited from a
/// `@MainActor` context — which Swift 6 otherwise rejects.
final class DownloadStateManager: DownloadStateManaging, @unchecked Sendable {

    // MARK: - Thread-safe storage

    let bookIdentifierToDownloadInfo = SafeDictionary<String, MyBooksDownloadInfo>()
    let bookIdentifierToDownloadTask = SafeDictionary<String, URLSessionDownloadTask>()
    let taskIdentifierToBook = SafeDictionary<Int, TPPBook>()

    // MARK: - Coordinator

    let downloadCoordinator = DownloadCoordinator()

    /// Concurrency cap. Written by `DownloadThrottlingService` and read by the
    /// orchestrator / start-coordinator from different threads, so it is
    /// NSLock-guarded (the one piece of mutable state that made the manager
    /// non-Sendable).
    private let maxConcurrentLock = NSLock()
    private var _maxConcurrentDownloads: Int = 4
    var maxConcurrentDownloads: Int {
        get { maxConcurrentLock.withLock { _maxConcurrentDownloads } }
        set { maxConcurrentLock.withLock { _maxConcurrentDownloads = newValue } }
    }

    // MARK: - Durable persistence (seam S1)

    /// Crash-durable mirror of the in-flight download records. The
    /// SafeDictionaries above stay the hot cache; this cold store survives a
    /// mid-download kill so launch reconciliation can re-adopt / restart tasks.
    let taskPersistence: DownloadTaskPersistence

    /// Per-book transient-transfer retry counter (content transfer only). Reset
    /// on terminal completion so a later independent failure starts fresh.
    ///
    /// Non-`private` (but only mutated through the `transferRetryAttempts` /
    /// `incrementTransferRetryAttempts` / `resetTransferRetryAttempts` seam
    /// below) so tests can await the counter directly on this `SafeDictionary`
    /// actor — mirroring how the public `taskIdentifierToBook` /
    /// `bookIdentifierToDownloadInfo` actors are read in tests. Awaiting the
    /// (Sendable) actor avoids sending the non-Sendable `DownloadStateManager`
    /// instance across the actor boundary from a `@MainActor` test, which Swift 6
    /// rejects.
    let transferRetryCounts = SafeDictionary<String, Int>()

    init(taskPersistence: DownloadTaskPersistence = DownloadTaskPersistence()) {
        self.taskPersistence = taskPersistence
    }

    // MARK: - Download Info Queries

    /// Async-first download info accessor with cache update
    func downloadInfoAsync(forBookIdentifier bookIdentifier: String) async -> MyBooksDownloadInfo? {
        guard let downloadInfo = await bookIdentifierToDownloadInfo.get(bookIdentifier) else {
            await downloadCoordinator.removeCachedDownloadInfo(for: bookIdentifier)
            return nil
        }

        await downloadCoordinator.cacheDownloadInfo(downloadInfo, for: bookIdentifier)
        return downloadInfo
    }

    /// Synchronous accessor for legacy compatibility (@objc, UIKit delegates).
    /// Reads from SafeDictionary's lock-protected synchronous mirror — no async
    /// bridging, no semaphores, no data races.
    func downloadInfo(forBookIdentifier bookIdentifier: String) -> MyBooksDownloadInfo? {
        bookIdentifierToDownloadInfo.syncGet(bookIdentifier)
    }

    /// Returns the current download progress for a book (0.0 to 1.0).
    func downloadProgress(for bookIdentifier: String) -> Double {
        Double(self.downloadInfo(forBookIdentifier: bookIdentifier)?.downloadProgress ?? 0.0)
    }

    // MARK: - Durable persistence API

    /// Persist a started task so a mid-download kill can be reconciled at launch.
    func persistStartedTask(
        bookID: String,
        taskIdentifier: Int,
        downloadURL: URL,
        account: String,
        expectedBytes: Int64?
    ) {
        taskPersistence.record(
            PersistedDownloadRecord(
                bookID: bookID,
                taskIdentifier: taskIdentifier,
                downloadURL: downloadURL,
                account: account,
                expectedBytes: expectedBytes,
                startedAt: Date()
            )
        )
    }

    /// Drop the durable record for a book on terminal completion.
    func removePersistedRecord(for bookID: String) {
        taskPersistence.remove(bookID: bookID)
    }

    /// All durable records (for launch reconciliation).
    func persistedRecords() -> [PersistedDownloadRecord] {
        taskPersistence.all()
    }

    // MARK: - Transient-transfer retry counters

    func transferRetryAttempts(for bookID: String) async -> Int {
        await transferRetryCounts.get(bookID) ?? 0
    }

    func incrementTransferRetryAttempts(for bookID: String) async {
        let current = await transferRetryCounts.get(bookID) ?? 0
        await transferRetryCounts.set(bookID, value: current + 1)
    }

    func resetTransferRetryAttempts(for bookID: String) async {
        await transferRetryCounts.remove(bookID)
    }

    // MARK: - Cleanup

    /// Removes all tracking state for a completed or failed download.
    func cleanupDownload(for bookIdentifier: String, taskIdentifier: Int? = nil) async {
        await bookIdentifierToDownloadInfo.remove(bookIdentifier)
        await downloadCoordinator.removeCachedDownloadInfo(for: bookIdentifier)
        await downloadCoordinator.registerCompletion(identifier: bookIdentifier)
        await transferRetryCounts.remove(bookIdentifier)
        removePersistedRecord(for: bookIdentifier)

        if let taskId = taskIdentifier {
            await taskIdentifierToBook.remove(taskId)
        }
    }

    /// Resets all state (used during account reset).
    func resetAll() async {
        let allInfo = await bookIdentifierToDownloadInfo.values()
        for info in allInfo {
            info.downloadTask.cancel(byProducingResumeData: { _ in })
        }

        await bookIdentifierToDownloadInfo.removeAll()
        await taskIdentifierToBook.removeAll()
        await transferRetryCounts.removeAll()
        taskPersistence.removeAll()
        await downloadCoordinator.reset()
    }
}
