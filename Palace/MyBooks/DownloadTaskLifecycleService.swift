//
//  DownloadTaskLifecycleService.swift
//  Palace
//
//  Owns the URL-session task lifecycle bookkeeping that lived inside
//  MyBooksDownloadCenter as the async block of `addDownloadTask` and
//  the body of `handleTaskCompletionError`. Two responsibilities:
//
//    1. `registerStartedTask(_:book:maxConcurrentDownloads:)` —
//       seeds bookIdentifierToDownloadInfo + taskIdentifierToBook
//       so URLSession callbacks can route the right book, marks the
//       book as `.downloading` in the registry, announces the start,
//       posts the legacy `.TPPMyBooksDownloadCenterDidChange`
//       notification (via the delegate so MBDC stays the
//       `object: self` posting source), then schedules pending
//       starts to fill remaining capacity. Critical: `task.resume()`
//       happens AFTER state seeding so URLSession delegate
//       callbacks find the task in our maps.
//
//    2. `handleTaskCompletionError(task:error:)` — the
//       `URLSessionTaskDelegate` `didCompleteWithError` callback's
//       async body. Clears redirect attempts + registers completion
//       on the download coordinator, logs/alerts on real errors
//       (cancellations are silent), and schedules pending starts.
//

import Foundation
import PalaceLogging
import PalaceBookModel

// MARK: - Delegate

protocol DownloadTaskLifecycleServiceDelegate: AnyObject {
    func logBookDownloadFailure(_ book: TPPBook, reason: String, downloadTask: URLSessionTask, metadata: [String: Any]?)
    func failDownloadWithAlert(for book: TPPBook, withMessage message: String?)
    func notifyDownloadCenterDidChange()
    func schedulePendingStartsIfPossible()
}

// MARK: - DownloadTaskLifecycleService

/// - Sendable invariant (Swift 6 `complete`-mode): the three stored
///   dependencies (`stateManager`, `bookRegistry`, `downloadAnnouncementService`)
///   are immutable `let`s bound at init. The only mutable member is
///   `weak var delegate`, assigned exactly once during owner
///   (`MyBooksDownloadCenter`) construction and never reassigned (weak-ref reads
///   + ARC zeroing are atomic). `registerStartedTask` / `handleTaskCompletionError`
///   are nonisolated `async`; they touch only the actor-serialized
///   `stateManager` storage and hop out to the delegate. Mirrors the
///   `DownloadStartCoordinator` invariant. `@unchecked` only because the stored
///   service types are not themselves `Sendable`.
final class DownloadTaskLifecycleService: @unchecked Sendable {

    weak var delegate: DownloadTaskLifecycleServiceDelegate?

    private let stateManager: DownloadStateManager
    private let bookRegistry: TPPBookRegistryProvider
    private let downloadAnnouncementService: DownloadAnnouncementService

    init(
        stateManager: DownloadStateManager,
        bookRegistry: TPPBookRegistryProvider,
        downloadAnnouncementService: DownloadAnnouncementService
    ) {
        self.stateManager = stateManager
        self.bookRegistry = bookRegistry
        self.downloadAnnouncementService = downloadAnnouncementService
    }

    // MARK: - Start

    func registerStartedTask(
        _ task: URLSessionDownloadTask,
        book: TPPBook,
        maxConcurrentDownloads: Int
    ) async {
        let downloadInfo = MyBooksDownloadInfo(
            downloadProgress: 0.0,
            downloadTask: task,
            rightsManagement: .unknown
        )

        await stateManager.bookIdentifierToDownloadInfo.set(book.identifier, value: downloadInfo)
        await stateManager.taskIdentifierToBook.set(task.taskIdentifier, value: book)

        let currentCount = await stateManager.downloadCoordinator.activeCount
        Log.info(#file, "📊 Active downloads: \(currentCount)/\(maxConcurrentDownloads) (started '\(book.title)')")

        // Resume task AFTER storage so URLSession delegate callbacks
        // find this taskIdentifier in our maps.
        task.resume()

        bookRegistry.addBook(
            book,
            location: bookRegistry.location(forIdentifier: book.identifier),
            state: .downloading,
            fulfillmentId: nil,
            readiumBookmarks: nil,
            genericBookmarks: nil
        )

        downloadAnnouncementService.announceDownloadStarted(for: book)

        delegate?.notifyDownloadCenterDidChange()
        delegate?.schedulePendingStartsIfPossible()
    }

    // MARK: - End

    func handleTaskCompletionError(task: URLSessionTask, error: Error?) async {
        guard let book = await stateManager.taskIdentifierToBook.get(task.taskIdentifier) else {
            return
        }

        await stateManager.downloadCoordinator.clearRedirectAttempts(for: task.taskIdentifier)
        await stateManager.downloadCoordinator.registerCompletion(identifier: book.identifier)
        let remainingCount = await stateManager.downloadCoordinator.activeCount
        Log.info(#file, "📊 Download completed for '\(book.title)', remaining active: \(remainingCount)")

        if let error = error as NSError?, error.code != NSURLErrorCancelled {
            delegate?.logBookDownloadFailure(book, reason: "networking error", downloadTask: task, metadata: ["urlSessionError": error])
            delegate?.failDownloadWithAlert(for: book, withMessage: nil)
            return
        }

        delegate?.schedulePendingStartsIfPossible()
    }
}
