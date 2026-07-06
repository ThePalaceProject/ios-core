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

// MARK: - RetryBookBox

/// Carrier box that lets the non-Sendable `TPPBook` ride inside a
/// `@Sendable` retry closure. The book is read-only after construction and
/// the closure is only ever invoked on the main actor (from the alert's
/// Retry button), so `@unchecked Sendable` is sound. Mirrors the
/// carrier-box precedent (`CarPlayImageCompletionBox`, `ReadiumBookmarkBox`).
private final class RetryBookBox: @unchecked Sendable {
    let book: TPPBook
    init(_ book: TPPBook) { self.book = book }
}

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
///
/// `@unchecked Sendable` invariant (Swift 6 `complete`-mode slice): every
/// injected collaborator is an immutable `let` (`bookRegistry`,
/// `stateManager`, `progressReporter`, `downloadAnnouncementService`,
/// `errorActivityTracker`, `userRetryTracker`, `problemDocumentCache`). The
/// only mutable instance storage is `weak var delegate`, which is assigned
/// exactly once on the main thread during `MyBooksDownloadCenter` init and
/// only read from `@MainActor`-hopped or awaited contexts thereafter — never
/// mutated concurrently. The class does not add
/// any concurrency of its own beyond hopping alert publication to
/// `@MainActor` (`runOnMainAsync`) and cleanup to a detached `Task`; both
/// already run on their own actors. `@unchecked` is required only so `self`
/// can be captured by those `@Sendable` closures — not because any state is
/// racy. Mirrors sibling presenters in this module
/// (`DownloadAuthRetryHandler`, `RightsManagementDispatcher`,
/// `BookReturnService`, `BookSignInRedirectHandler`).
final class DownloadAlertPresenter: @unchecked Sendable {

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

        // Snapshot the Sendable String facets of `book` before the detached
        // Task so the non-Sendable `TPPBook` does not have to cross the
        // `@Sendable` boundary. The task only ever reads the identifier/title.
        let bookId = book.identifier
        let bookTitle = book.title
        Task { [weak self] in
            await self?.errorActivityTracker.log(
                "Download failed for '\(bookTitle)': \(message ?? "unknown reason")",
                category: .download
            )
            guard let self else { return }
            // CRITICAL: Remove from bookIdentifierToDownloadInfo so retry
            // works. Also sweep any matching taskIdentifierToBook entries so
            // a later airplane-mode toggle can't misread a no-longer-active
            // task as in-flight and flip the book to .downloadFailed again
            // (the regression of PP-4114 — same root cause as the
            // success-path leak).
            await self.stateManager.bookIdentifierToDownloadInfo.remove(bookId)
            let stalePairs = await self.stateManager.taskIdentifierToBook.allPairs()
            for (taskId, mappedBook) in stalePairs where mappedBook.identifier == bookId {
                await self.stateManager.taskIdentifierToBook.remove(taskId)
            }
            await self.stateManager.downloadCoordinator.removeCachedDownloadInfo(for: bookId)
            await self.stateManager.downloadCoordinator.registerCompletion(identifier: bookId)
            let remainingCount = await self.stateManager.downloadCoordinator.activeCount
            Log.info(#file, "📊 Download failed for '\(bookTitle)', remaining active: \(remainingCount)")
            self.delegate?.schedulePendingStartsIfPossible()
        }

        // Most callers (DownloadTaskLifecycleService, AdobeDRMHandler,
        // OverdriveDownloadHandler, RightsManagementDispatcher) pass
        // `nil` when the underlying NSError has no user-actionable
        // localizedDescription. Previously this coalesced to the
        // developer placeholder "No error message" which shipped to
        // users in 3.1.0 (Cinema-beyond-the-human repro). Treat empty
        // strings the same — both are caller-side "I don't know why".
        let trimmedMessage = message?.trimmingCharacters(in: .whitespacesAndNewlines)
        let errorMessage: String
        if let trimmedMessage, !trimmedMessage.isEmpty {
            errorMessage = trimmedMessage
        } else {
            errorMessage = DisplayStrings.downloadFailedUnknownReason
        }
        let formattedMessage = String.localizedStringWithFormat(DisplayStrings.downloadFailedMessage, book.title)
        let finalMessage = "\(formattedMessage)\n\(errorMessage)"

        let retryAction = makeRetryAction(for: book)

        // `bookId` (snapshotted above) is the Sendable identifier so the
        // non-Sendable `book` does not cross into the `@MainActor @Sendable`
        // closure. `retryAction` is now `@Sendable` (see `makeRetryAction`),
        // so it too is safe to capture.
        // Publish error and announce via VoiceOver
        runOnMainAsync { [weak self] in
            self?.progressReporter.publishAndAnnounceError(
                DownloadErrorInfo(bookId: bookId,
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

        // Snapshot the Sendable identifier so the non-Sendable `book` does not
        // cross into the `@MainActor @Sendable` closure. `retryAction` is now
        // `@Sendable` (see `makeRetryAction`), so it too is safe to capture.
        let bookId = book.identifier

        // Publish error and announce via VoiceOver
        runOnMainAsync { [weak self] in
            self?.progressReporter.publishAndAnnounceError(
                DownloadErrorInfo(bookId: bookId,
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
    // Returns a `@Sendable` closure so it can be captured by the
    // `@MainActor @Sendable` alert-publication closures. The closure needs the
    // whole non-Sendable `book` to re-drive `startDownload`, so it is threaded
    // through a `RetryBookBox` carrier: the book is read-only inside the
    // closure and the closure is only ever invoked on the main actor (from the
    // alert's Retry button), so `@unchecked Sendable` on the box is sound.
    private func makeRetryAction(for book: TPPBook) -> (@Sendable () -> Void)? {
        let operationId = "download-\(book.identifier)"
        guard userRetryTracker.canRetry(operationId: operationId) else { return nil }
        let bookBox = RetryBookBox(book)
        return { [weak self] in
            guard let self else { return }
            self.userRetryTracker.recordRetry(operationId: operationId)
            self.delegate?.startDownload(for: bookBox.book, withRequest: nil)
        }
    }
}
