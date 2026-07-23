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

    /// Sends a progress update for a book
    func sendProgress(bookIdentifier: String, progress: Double)

    /// Publishes an error and announces it via VoiceOver
    func publishAndAnnounceError(_ errorInfo: DownloadErrorInfo)

    /// Broadcasts a general update notification (throttled)
    func broadcastUpdate()
}

// MARK: - DownloadProgressReporter

/// Handles Combine-based progress reporting, error publishing, and
/// throttled broadcast notifications for download state changes.
///
/// - Sendable invariant (Swift 6 `complete`-mode): the stored dependencies
///   (`accessibilityAnnouncements`, `downloadAnnouncementService`) plus the two
///   `PassthroughSubject` publishers are `let` bound at init. All broadcast-
///   throttling mutable state (`lastBroadcastTime`, `pendingBroadcast`) is
///   `@MainActor`-isolated and only touched inside the `@MainActor` broadcast
///   methods. The one non-isolated mutable member is `weak var notificationSender`,
///   assigned once by the owner during composition-root wiring (weak-ref reads +
///   ARC zeroing are atomic). `sendProgress` / `broadcastUpdate` hop to
///   `@MainActor` before touching any of that state. `@unchecked` only because
///   the stored service types are not themselves `Sendable`.
final class DownloadProgressReporter: DownloadProgressPublishing, @unchecked Sendable {

    // MARK: - Publishers

    let downloadProgressPublisher = PassthroughSubject<(String, Double), Never>()
    let downloadErrorPublisher = PassthroughSubject<DownloadErrorInfo, Never>()

    // MARK: - Dependencies

    private let accessibilityAnnouncements: TPPAccessibilityAnnouncementCenter
    private let downloadAnnouncementService: DownloadAnnouncementService

    // MARK: - Broadcast throttling

    @MainActor private var lastBroadcastTime: Date = Date.distantPast
    @MainActor private var pendingBroadcast: DispatchWorkItem?

    /// Minimum interval between broadcast notifications — the intrinsic throttle
    /// that coalesces rapid download-progress bursts into at most one
    /// `TPPMyBooksDownloadCenterDidChange` post per window. Injectable ONLY so
    /// tests can set it to `0` for deterministic (un-delayed) broadcasts; the
    /// production default is `0.5`s, so a default-constructed reporter behaves
    /// byte-identically to the previous hard-coded literal. `let` (immutable
    /// after init) keeps the `@unchecked Sendable` invariant honest.
    let throttleInterval: TimeInterval

    /// The object to use as the notification sender
    /// (typically `AppContainer.production().downloadCenter`).
    weak var notificationSender: AnyObject?

    // MARK: - Init

    init(
        accessibilityAnnouncements: TPPAccessibilityAnnouncementCenter = TPPAccessibilityAnnouncementCenter(),
        downloadAnnouncementService: DownloadAnnouncementService? = nil,
        throttleInterval: TimeInterval = 0.5
    ) {
        self.accessibilityAnnouncements = accessibilityAnnouncements
        self.throttleInterval = throttleInterval
        // The reporter and the service must share an underlying announcer
        // so deduplication / progress-bucket state are coherent across the
        // announceStatus path (used by publishAndAnnounceError) and the
        // book-level announce paths (used by the lifecycle wrappers below).
        self.downloadAnnouncementService = downloadAnnouncementService ?? DownloadAnnouncementService(announcer: accessibilityAnnouncements)
    }

    // MARK: - Progress

    func sendProgress(bookIdentifier: String, progress: Double) {
        Task { @MainActor in
            downloadProgressPublisher.send((bookIdentifier, progress))
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
        // Injectable throttle window (production default 0.5s). The asyncAfter
        // throttle below is preserved — only its interval is now configurable.
        let minimumBroadcastInterval = throttleInterval

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
