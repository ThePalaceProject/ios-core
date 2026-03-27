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
final class DownloadStateManager: DownloadStateManaging {

    // MARK: - Thread-safe storage

    let bookIdentifierToDownloadInfo = SafeDictionary<String, MyBooksDownloadInfo>()
    let bookIdentifierToDownloadTask = SafeDictionary<String, URLSessionDownloadTask>()
    let taskIdentifierToBook = SafeDictionary<Int, TPPBook>()

    // MARK: - Coordinator

    let downloadCoordinator = DownloadCoordinator()
    var maxConcurrentDownloads: Int = 4

    // MARK: - Download Info Queries

    /// Async-first download info accessor with cache update
    func downloadInfoAsync(forBookIdentifier bookIdentifier: String) async -> MyBooksDownloadInfo? {
        guard let downloadInfo = await bookIdentifierToDownloadInfo.get(bookIdentifier) else {
            await downloadCoordinator.removeCachedDownloadInfo(for: bookIdentifier)
            return nil
        }

        if downloadInfo is MyBooksDownloadInfo {
            await downloadCoordinator.cacheDownloadInfo(downloadInfo, for: bookIdentifier)
            return downloadInfo
        } else {
            Log.error(#file, "Corrupted download info detected for book \(bookIdentifier), removing entry")
            await bookIdentifierToDownloadInfo.remove(bookIdentifier)
            await downloadCoordinator.removeCachedDownloadInfo(for: bookIdentifier)
            return nil
        }
    }

    /// Synchronous wrapper for legacy compatibility (@objc, UIKit delegates).
    /// Uses semaphore with short timeout to avoid UI blocking.
    func downloadInfo(forBookIdentifier bookIdentifier: String) -> MyBooksDownloadInfo? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: MyBooksDownloadInfo?

        Task.detached(priority: .userInitiated) {
            result = await self.downloadCoordinator.getCachedDownloadInfo(for: bookIdentifier)

            if result == nil {
                result = await self.downloadInfoAsync(forBookIdentifier: bookIdentifier)
            }

            semaphore.signal()
        }

        _ = semaphore.wait(timeout: .now() + 0.05)
        return result
    }

    /// Returns the current download progress for a book (0.0 to 1.0).
    func downloadProgress(for bookIdentifier: String) -> Double {
        Double(self.downloadInfo(forBookIdentifier: bookIdentifier)?.downloadProgress ?? 0.0)
    }

    // MARK: - Cleanup

    /// Removes all tracking state for a completed or failed download.
    func cleanupDownload(for bookIdentifier: String, taskIdentifier: Int? = nil) async {
        await bookIdentifierToDownloadInfo.remove(bookIdentifier)
        await downloadCoordinator.removeCachedDownloadInfo(for: bookIdentifier)
        await downloadCoordinator.registerCompletion(identifier: bookIdentifier)

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
        await downloadCoordinator.reset()
    }
}
