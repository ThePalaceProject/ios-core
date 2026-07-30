//
//  DownloadProgressPublisher.swift
//  Palace
//
//  Extracted from MyBooksDownloadCenter to provide single-responsibility
//  Combine-based progress and error reporting for downloads.
//

import Foundation
import Combine
import UIKit

// MARK: - DownloadProgressPublishing Protocol

protocol DownloadProgressPublishing: AnyObject {
    /// Publishes (bookIdentifier, progress) tuples for download progress updates
    var downloadProgressPublisher: PassthroughSubject<(String, Double), Never> { get }

    /// Publishes download/borrow error info for inline alert presentation
    var downloadErrorPublisher: PassthroughSubject<DownloadErrorInfo, Never> { get }

    /// Publishes (bookIdentifier, isActive) for the LCP audiobook *content*
    /// re-download — the background `.lcpa` fetch that runs when a book is
    /// already `.downloadSuccessful` but its content package is missing.
    ///
    /// Separate from `downloadProgressPublisher` because the consumer needs a
    /// definite "a content download is running" edge, not an inference from a
    /// progress value. `BookDetailViewModel` clamps `downloadProgress`
    /// monotonically upward, so a book whose earlier download already reached
    /// 1.0 would clamp every fresh 0.0…1.0 sample back to 1.0 and the UI could
    /// never tell that a new transfer had begun.
    ///
    /// This deliberately does NOT move the book to `.downloading`: that state
    /// maps to `buttons = [.cancel]`, and this transfer runs on an out-of-band
    /// background `URLSession` that is not registered in `downloadInfo`, so the
    /// button would not be able to cancel anything.
    var lcpContentDownloadPublisher: PassthroughSubject<(String, Bool), Never> { get }

    /// Sends a progress update for a book
    func sendProgress(bookIdentifier: String, progress: Double)

    /// Marks the LCP content re-download for `bookIdentifier` as running
    /// (`active == true`) or finished (`active == false`, on success *and*
    /// failure, so the UI cue always closes).
    func sendLCPContentDownloadActive(bookIdentifier: String, active: Bool)

    /// True while an LCP `.lcpa` content transfer is running for this book,
    /// whether it came from first-borrow fulfillment or the background re-download.
    ///
    /// Registry reconciliation consults this to decide whether a book holding a
    /// license but no content is genuinely stranded or simply still downloading.
    /// It cannot use `downloadInfo` for that: the fulfillment transfer belongs to
    /// Readium's own `URLSession` and is never registered there, so reconciliation
    /// saw "license, no content, nothing in flight", scheduled a redundant
    /// re-download, and the archive was fetched twice on every fresh borrow
    /// (measured: two 1.8 GB transfers for one Audible title, the second
    /// discarded on arrival with "an item with the same name already exists").
    ///
    /// Answers synchronously — the publisher delivers on the main actor, and a
    /// reconciliation pass running before that hop must still see the transfer.
    func isLCPContentTransferActive(for bookIdentifier: String) -> Bool

    /// Drops the registration without publishing a UI edge. For the cancel path,
    /// where Readium never calls the fulfillment completion handler at all.
    func clearLCPContentTransfer(for bookIdentifier: String)

    /// Publishes an error and announces it via VoiceOver
    func publishAndAnnounceError(_ errorInfo: DownloadErrorInfo)

    /// Broadcasts a general update notification (throttled)
    func broadcastUpdate()
}

// MARK: - DownloadProgressReporter

/// Handles Combine-based progress reporting, error publishing, and
/// throttled broadcast notifications for download state changes.
final class DownloadProgressReporter: DownloadProgressPublishing {

    // MARK: - Publishers

    let downloadProgressPublisher = PassthroughSubject<(String, Double), Never>()
    let downloadErrorPublisher = PassthroughSubject<DownloadErrorInfo, Never>()
    let lcpContentDownloadPublisher = PassthroughSubject<(String, Bool), Never>()

    // MARK: - Dependencies

    private let accessibilityAnnouncements: TPPAccessibilityAnnouncementCenter
    private let downloadAnnouncementService: DownloadAnnouncementService

    // MARK: - Active LCP content transfers
    //
    // Read from background reconciliation and written from the fulfillment and
    // re-download paths, so it carries its own lock rather than an actor hop.

    /// identifier -> monotonic timestamp of the last sign of life.
    ///
    /// Timestamped rather than a plain set because the completion handler is not
    /// guaranteed to run: `LicensesService.urlSession(_:task:didCompleteWithError:)`
    /// deliberately swallows `NSURLErrorCancelled` WITHOUT calling the completion
    /// handler, so a cancelled fulfillment would otherwise leave a permanent
    /// registration — pinning the book at `.downloading` and the half-sheet on a
    /// progress bar that never moves. The cancel path clears explicitly; this idle
    /// window is the backstop for every route that never reports at all.
    private var activeLCPContentTransfers: [String: TimeInterval] = [:]
    private let activeTransfersLock = NSLock()

    /// Idle, NOT total duration. A 1.8 GB archive on a slow connection legitimately
    /// runs far longer than any total-duration cap, and an earlier revision of the
    /// sibling claim map used a total window and reintroduced the duplicate it
    /// existed to prevent.
    static let contentTransferIdleTimeout: TimeInterval = 180

    /// Monotonic so a wall-clock adjustment mid-download cannot expire a live
    /// transfer. Injectable for tests.
    var monotonicClock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    // MARK: - Broadcast throttling

    @MainActor private var lastBroadcastTime: Date = Date.distantPast
    @MainActor private var pendingBroadcast: DispatchWorkItem?

    /// The object to use as the notification sender
    /// (typically `AppContainer.production().downloadCenter`).
    weak var notificationSender: AnyObject?

    // MARK: - Init

    init(
        accessibilityAnnouncements: TPPAccessibilityAnnouncementCenter = TPPAccessibilityAnnouncementCenter(),
        downloadAnnouncementService: DownloadAnnouncementService? = nil
    ) {
        self.accessibilityAnnouncements = accessibilityAnnouncements
        // The reporter and the service must share an underlying announcer
        // so deduplication / progress-bucket state are coherent across the
        // announceStatus path (used by publishAndAnnounceError) and the
        // book-level announce paths (used by the lifecycle wrappers below).
        self.downloadAnnouncementService = downloadAnnouncementService ?? DownloadAnnouncementService(announcer: accessibilityAnnouncements)
    }

    // MARK: - Progress

    func sendProgress(bookIdentifier: String, progress: Double) {
        // Heartbeat: a transfer reporting bytes is alive, however long it has run.
        activeTransfersLock.lock()
        if activeLCPContentTransfers[bookIdentifier] != nil {
            activeLCPContentTransfers[bookIdentifier] = monotonicClock()
        }
        activeTransfersLock.unlock()

        Task { @MainActor in
            downloadProgressPublisher.send((bookIdentifier, progress))
        }
    }

    func sendLCPContentDownloadActive(bookIdentifier: String, active: Bool) {
        // Update the queryable set BEFORE the main-actor hop. Reconciliation runs
        // on a background queue and can land between this call and the delivery of
        // the published edge; if it read a stale empty set it would schedule the
        // duplicate re-download this registry exists to prevent.
        activeTransfersLock.lock()
        if active {
            activeLCPContentTransfers[bookIdentifier] = monotonicClock()
        } else {
            activeLCPContentTransfers.removeValue(forKey: bookIdentifier)
        }
        activeTransfersLock.unlock()

        Task { @MainActor in
            lcpContentDownloadPublisher.send((bookIdentifier, active))
        }
    }

    func isLCPContentTransferActive(for bookIdentifier: String) -> Bool {
        activeTransfersLock.lock()
        guard let lastActivity = activeLCPContentTransfers[bookIdentifier] else {
            activeTransfersLock.unlock()
            return false
        }
        guard monotonicClock() - lastActivity > Self.contentTransferIdleTimeout else {
            activeTransfersLock.unlock()
            return true
        }
        // Gone quiet past the idle window — treat as dead so recovery can run.
        activeLCPContentTransfers.removeValue(forKey: bookIdentifier)
        activeTransfersLock.unlock()

        // Publish OUTSIDE the lock. Dropping the entry silently would unstick
        // reconciliation but leave the UI flag latched true, and the half-sheet
        // reads that flag ahead of book state — a determinate bar frozen forever.
        publishTransferEdge(bookIdentifier: bookIdentifier, active: false)
        return false
    }

    func clearLCPContentTransfer(for bookIdentifier: String) {
        activeTransfersLock.lock()
        let wasRegistered = activeLCPContentTransfers.removeValue(forKey: bookIdentifier) != nil
        activeTransfersLock.unlock()

        // Same reason as above: the UI flag is driven ONLY by this publisher, so a
        // silent drop leaves a cancelled download rendering a bar that never moves.
        // Only publish if something was actually registered, so a cancel for an
        // unrelated book cannot emit a spurious edge.
        if wasRegistered {
            publishTransferEdge(bookIdentifier: bookIdentifier, active: false)
        }
    }

    private func publishTransferEdge(bookIdentifier: String, active: Bool) {
        Task { @MainActor in
            lcpContentDownloadPublisher.send((bookIdentifier, active))
        }
    }

    // MARK: - Error Publishing

    /// Publishes an error to `downloadErrorPublisher` and simultaneously announces
    /// it via VoiceOver so assistive technology users hear the error without
    /// needing to navigate to the alert element.
    func publishAndAnnounceError(_ errorInfo: DownloadErrorInfo) {
        downloadErrorPublisher.send(errorInfo)
        accessibilityAnnouncements.announceStatus(title: errorInfo.title, message: errorInfo.message)
    }

    // MARK: - Broadcast

    func broadcastUpdate() {
        Task { @MainActor [weak self] in
            self?.broadcastUpdateOnMain()
        }
    }

    @MainActor private func broadcastUpdateOnMain() {
        pendingBroadcast?.cancel()

        let timeSinceLastBroadcast = Date().timeIntervalSince(lastBroadcastTime)
        let minimumBroadcastInterval: TimeInterval = 0.5

        if timeSinceLastBroadcast >= minimumBroadcastInterval {
            broadcastUpdateNow()
        } else {
            let delay = minimumBroadcastInterval - timeSinceLastBroadcast
            let workItem = DispatchWorkItem { [weak self] in
                Task { @MainActor in
                    self?.broadcastUpdateNow()
                }
            }
            pendingBroadcast = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    }

    @MainActor private func broadcastUpdateNow() {
        lastBroadcastTime = Date()
        pendingBroadcast = nil

        NotificationCenter.default.post(
            name: Notification.Name.TPPMyBooksDownloadCenterDidChange,
            object: notificationSender
        )
    }

    // MARK: - Accessibility Announcements
    //
    // All book-level announce paths route through DownloadAnnouncementService —
    // the single source of truth for the book→title (+identifier) bridge.
    // Kept here as thin wrappers because BackgroundDownloadHandler reaches
    // these methods via `delegate.progressReporter.announceXxx(for:)`; that
    // call shape stays stable until the broker extraction lets us flatten it.

    func announceDownloadStarted(for book: TPPBook) {
        downloadAnnouncementService.announceDownloadStarted(for: book)
    }

    func announceDownloadProgress(for book: TPPBook, progress: Double) {
        downloadAnnouncementService.announceDownloadProgress(for: book, progress: progress)
    }

    func announceDownloadCompleted(for book: TPPBook) {
        downloadAnnouncementService.announceDownloadCompleted(for: book)
    }

    func announceDownloadFailed(for book: TPPBook) {
        downloadAnnouncementService.announceDownloadFailed(for: book)
    }

    func announceBorrowStarted(for book: TPPBook) {
        downloadAnnouncementService.announceBorrowStarted(for: book)
    }

    func announceBorrowSucceeded(for book: TPPBook) {
        downloadAnnouncementService.announceBorrowSucceeded(for: book)
    }

    func announceBorrowFailed(for book: TPPBook) {
        downloadAnnouncementService.announceBorrowFailed(for: book)
    }

    func announceReturnStarted(for book: TPPBook) {
        downloadAnnouncementService.announceReturnStarted(for: book)
    }

    func announceReturnSucceeded(for book: TPPBook) {
        downloadAnnouncementService.announceReturnSucceeded(for: book)
    }

    func announceReturnFailed(for book: TPPBook) {
        downloadAnnouncementService.announceReturnFailed(for: book)
    }
}
