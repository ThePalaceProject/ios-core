//
//  DownloadAlertPresenter.swift
//  Palace
//
//  Owns the two failure-paths on MyBooksDownloadCenter that publish a
//  user-facing download error alert plus the registry / coordinator /
//  retry orchestration that goes with them — `failDownloadWithAlert(for:)`
//  (generic post-failure path) and `alertForProblemDocument(_:error:book:)`
//  (RFC 7807 problem document path, with the "no active loan" registry
//  removal).
//
//  Both methods previously lived on MBDC and tangled together: registry
//  mutation, accessibility announcement, async state cleanup
//  (downloadCoordinator + bookIdentifierToDownloadInfo), retry tracker,
//  publishAndAnnounceError, broadcast — six different collaborators across
//  ~85 LOC. Lifting them onto a presenter that takes those collaborators
//  by injection lets retry/error UI logic be unit-tested with mocks
//  without standing up a full MyBooksDownloadCenter.
//
//  The narrow `DownloadAlertPresenterDelegate` protocol exposes just the
//  two MBDC methods the presenter calls back into: `startDownload(for:)`
//  for the retry-action closure, and `schedulePendingStartsIfPossible()`
//  for the post-failure pump.
//

import Foundation
import PalaceLogging
import PalaceCatalog

// MARK: - DownloadAlertPresenterDelegate

/// Surface MBDC needs to expose for the presenter to drive retries and the
/// pending-starts pump. Both methods already exist on MBDC and are a
/// strict subset of its public surface.
protocol DownloadAlertPresenterDelegate: AnyObject {
    func startDownload(for book: TPPBook, withRequest request: URLRequest?)
    func schedulePendingStartsIfPossible()
}

// MARK: - DownloadAlertPresenter

/// Publishes user-facing download error alerts and runs the registry +
/// download-state cleanup that paired with them on MBDC. No UIKit surface
/// — the alert is published through `progressReporter.publishAndAnnounce
/// Error`, which the host SwiftUI sheet observes via Combine.
final class DownloadAlertPresenter {

    typealias DisplayStrings = Strings.MyDownloadCenter

    weak var delegate: DownloadAlertPresenterDelegate?

    private let bookRegistry: TPPBookRegistryProvider
    private let stateManager: DownloadStateManager
    private let progressReporter: DownloadProgressReporter
    private let downloadAnnouncementService: DownloadAnnouncementService
    private let errorActivityTracker: ErrorActivityTracker
    private let userRetryTracker: UserRetryTracker
    private let problemDocumentCache: TPPProblemDocumentCacheManager

    init(
        bookRegistry: TPPBookRegistryProvider,
        stateManager: DownloadStateManager,
        progressReporter: DownloadProgressReporter,
        downloadAnnouncementService: DownloadAnnouncementService,
        errorActivityTracker: ErrorActivityTracker = .shared,
        userRetryTracker: UserRetryTracker = .shared,
        problemDocumentCache: TPPProblemDocumentCacheManager = .shared
    ) {
        self.bookRegistry = bookRegistry
        self.stateManager = stateManager
        self.progressReporter = progressReporter
        self.downloadAnnouncementService = downloadAnnouncementService
        self.errorActivityTracker = errorActivityTracker
        self.userRetryTracker = userRetryTracker
        self.problemDocumentCache = problemDocumentCache
    }

    // MARK: - failDownloadWithAlert

    /// Generic download-failure path. Marks the book `.downloadFailed`,
    /// announces via VoiceOver, runs async cleanup of the in-flight
    /// download tracking state, and publishes a retry-able error alert
    /// through the progress reporter's error publisher.
    func failDownloadWithAlert(for book: TPPBook, withMessage message: String? = nil) {
        let location = bookRegistry.location(forIdentifier: book.identifier)

        bookRegistry.addBook(book,
                             location: location,
                             state: .downloadFailed,
                             fulfillmentId: nil,
                             readiumBookmarks: nil,
                             genericBookmarks: nil)

        downloadAnnouncementService.announceDownloadFailed(for: book)

        Task { [weak self] in
            await self?.errorActivityTracker.log(
                "Download failed for '\(book.title)': \(message ?? "unknown reason")",
                category: .download
            )
            guard let self else { return }
            // CRITICAL: Remove from bookIdentifierToDownloadInfo so retry works
            await self.stateManager.bookIdentifierToDownloadInfo.remove(book.identifier)
            await self.stateManager.downloadCoordinator.removeCachedDownloadInfo(for: book.identifier)
            await self.stateManager.downloadCoordinator.registerCompletion(identifier: book.identifier)
            let remainingCount = await self.stateManager.downloadCoordinator.activeCount
            Log.info(#file, "📊 Download failed for '\(book.title)', remaining active: \(remainingCount)")
            self.delegate?.schedulePendingStartsIfPossible()
        }

        let errorMessage = message ?? "No error message"
        let formattedMessage = String.localizedStringWithFormat(NSLocalizedString("The download for %@ could not be completed.", comment: ""), book.title)
        let finalMessage = "\(formattedMessage)\n\(errorMessage)"

        let retryAction = makeRetryAction(for: book)

        // Publish error and announce via VoiceOver (PP-3673)
        runOnMainAsync { [weak self] in
            self?.progressReporter.publishAndAnnounceError(
                DownloadErrorInfo(bookId: book.identifier,
                                  title: DisplayStrings.downloadFailed,
                                  message: finalMessage,
                                  kind: .download,
                                  retryAction: retryAction)
            )
        }

        progressReporter.broadcastUpdate()
    }

    // MARK: - alertForProblemDocument

    /// Problem-document failure path. Caches the problem document for
    /// later inspection, removes the book from the registry on
    /// `no-active-loan`, and publishes a (sometimes) retry-able alert.
    func alertForProblemDocument(_ problemDoc: TPPProblemDocument?, error: Error?, book: TPPBook) {
        let msg = String(format: NSLocalizedString("The download for %@ could not be completed.", comment: ""), book.title)

        var finalMessage = msg
        if let problemDoc = problemDoc {
            problemDocumentCache.cacheProblemDocument(problemDoc, key: book.identifier)
            if let detail = problemDoc.detail {
                finalMessage = "\(msg)\n\n\(detail)"
            }

            if problemDoc.type == TPPProblemDocument.TypeNoActiveLoan {
                bookRegistry.removeBook(forIdentifier: book.identifier)
            }
        } else if let error = error {
            finalMessage = String(format: "%@\n\nError: %@", msg, error.localizedDescription)
        }

        let isNoActiveLoan = problemDoc?.type == TPPProblemDocument.TypeNoActiveLoan
        // Download failures are generally retryable unless it's a "no active loan" error
        let retryAction = isNoActiveLoan ? nil : makeRetryAction(for: book)

        // Publish error and announce via VoiceOver (PP-3673)
        runOnMainAsync { [weak self] in
            self?.progressReporter.publishAndAnnounceError(
                DownloadErrorInfo(bookId: book.identifier,
                                  title: DisplayStrings.downloadFailed,
                                  message: finalMessage,
                                  kind: .download,
                                  retryAction: retryAction)
            )
        }
    }

    // MARK: - Retry action

    /// Builds the retry closure that the alert UI invokes when the user
    /// taps "Try again". Returns nil if the per-operation retry budget
    /// (`userRetryTracker`) has been exhausted, so the UI can hide the
    /// retry button instead of letting the user hammer a permanent
    /// failure.
    private func makeRetryAction(for book: TPPBook) -> (() -> Void)? {
        let operationId = "download-\(book.identifier)"
        guard userRetryTracker.canRetry(operationId: operationId) else { return nil }
        return { [weak self] in
            guard let self else { return }
            self.userRetryTracker.recordRetry(operationId: operationId)
            self.delegate?.startDownload(for: book, withRequest: nil)
        }
    }
}
