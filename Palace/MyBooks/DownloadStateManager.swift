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
import PalaceBookModel
import PalaceLogging
import PalaceUtilities

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

    // MARK: - Durable persistence

    /// Crash-durable mirror of the in-flight download records. The
    /// SafeDictionaries above stay the hot cache; this cold store survives a
    /// mid-download kill so launch reconciliation can re-adopt / restart tasks.
    let taskPersistence: DownloadTaskPersistence

    /// Per-book transient-transfer retry counter (content transfer only). Reset
    /// on terminal completion so a later independent failure starts fresh.
    ///
    /// Non-`private` so `@MainActor` tests can await this Sendable actor
    /// directly; sending the non-Sendable manager across actors is rejected by
    /// Swift 6. Mutate only through the retry-attempt methods below.
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
    /// - Parameter task: the live task, so PP-4986 can stamp `account` onto it as
    ///   well as into the record. Stamping here keeps the stamp and the record
    ///   reading one value, matching `persistReissuedTask`.
    func persistStartedTask(
        bookID: String,
        taskIdentifier: Int,
        downloadURL: URL,
        account: String,
        expectedBytes: Int64?,
        stampingAccountOn task: URLSessionDownloadTask? = nil
    ) {
        if let task {
            TaskProvenance.setAccount(account, on: task)
        }
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

    /// Persist a task that REPLACES an in-flight one for a book already being
    /// downloaded — the acquisition-link follow-up and the bearer-token hop.
    ///
    /// Separate from `persistStartedTask`, which stamps the current account:
    /// `BackgroundDownloadHandler.startedForAccount` reads the stored account to
    /// pick which library's credential the next re-issue carries, so overwriting
    /// it after a mid-download library switch would send the new library's token
    /// to the original library's server (PP-4978). The account is carried
    /// forward, never invented; with no record it stays empty, which
    /// `startedForAccount` degrades to the current account.
    ///
    /// `startedAt` and `expectedBytes` carry forward too (the latter is `nil` in
    /// every production write).
    ///
    /// Uses `DownloadTaskPersistence.upsert` rather than `all()` + `record()`,
    /// so a concurrent `remove` cannot land between the read and the write.
    ///
    /// - Parameter inheritingFrom: the book id whose record supplies the carried
    ///   fields when the re-issue registers under a different id;
    ///   `followAcquisitionLink` re-registers under the server's OPDS entry id.
    /// - Parameter task: the live re-issued task, stamped with the inherited
    ///   account (PP-4986). Re-issued tasks never reach
    ///   `persistStartedTaskRecord`, and an unstamped task makes the retry rebuild
    ///   use whichever library is current. The inherited account is only known
    ///   inside the upsert.
    func persistReissuedTask(
        bookID: String,
        taskIdentifier: Int,
        downloadURL: URL,
        inheritingFrom sourceBookID: String? = nil,
        stampingAccountOn task: URLSessionDownloadTask? = nil
    ) {
        taskPersistence.upsert(bookID: bookID, inheritingFrom: sourceBookID) { existing in
            // A coalesce rather than `if existing == nil { log }` so the log adds
            // no branch that no assertion could observe. The log matters: an ""
            // here looks like a genuine empty account, and `startedForAccount`
            // degrades it to the current library, so this is the only signal that
            // a re-issue lost its provenance.
            let inheritedAccount = existing?.account ?? {
                Log.info(#file, "Re-issue for \(bookID) found no record to inherit; account will be empty")
                return ""
            }()
            // PP-4986: the live task carries the same account the record gets, so
            // the retry rebuild and `startedForAccount` cannot diverge.
            if let task {
                TaskProvenance.setAccount(inheritedAccount, on: task)
            }
            return PersistedDownloadRecord(
                bookID: bookID,
                taskIdentifier: taskIdentifier,
                downloadURL: downloadURL,
                account: inheritedAccount,
                expectedBytes: existing?.expectedBytes,
                startedAt: existing?.startedAt ?? Date()
            )
        }
    }

    /// Finish a download's durable bookkeeping: reset the transient-transfer
    /// retry counter, and retire the durable record UNLESS a live task remains.
    ///
    /// `keepRecord` is true when the completion left a task still running — today
    /// only the bearer-token hop, which swaps the fulfilment task for a content
    /// task and resumes it. Such a download has not reached a terminal outcome, so
    /// retiring its record would hide a live task from launch reconciliation
    /// (PP-5023).
    ///
    /// Distinct from `cleanupDownload`, which runs on cancel/delete where no
    /// follow-up can be in flight.
    func finishTerminalBookkeeping(for bookID: String, keepRecord: Bool) async {
        await resetTransferRetryAttempts(for: bookID)
        guard !keepRecord else { return }
        removePersistedRecord(for: bookID)
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
