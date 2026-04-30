//
//  DownloadAnnouncementService.swift
//  Palace
//
//  Book-aware façade over TPPAccessibilityAnnouncementCenter for the borrow /
//  return / download lifecycle. Bridges TPPBook → title (and identifier where
//  the announcement state machine needs it) so callers don't repeat the same
//  9-method wrapper boilerplate at every consumer.
//

import Foundation

// MARK: - Lifecycle Announcer Protocol

/// Narrow surface of TPPAccessibilityAnnouncementCenter that DownloadAnnouncementService
/// depends on. Defining a protocol here lets tests substitute a spy without
/// having to drive the full announcement-center deduplication / queueing machinery.
protocol DownloadLifecycleAnnouncing: AnyObject {
    func announceDownloadStarted(title: String, identifier: String?)
    func announceDownloadProgress(title: String, identifier: String, progress: Double)
    func announceDownloadCompleted(title: String)
    func announceDownloadFailed(title: String)
    func announceBorrowStarted(title: String)
    func announceBorrowSucceeded(title: String)
    func announceBorrowFailed(title: String)
    func announceReturnStarted(title: String)
    func announceReturnSucceeded(title: String)
    func announceReturnFailed(title: String)
    func resetProgress(identifier: String)
}

extension TPPAccessibilityAnnouncementCenter: DownloadLifecycleAnnouncing {}

// MARK: - DownloadAnnouncementService

/// Routes TPPBook-keyed lifecycle announcements through the underlying
/// accessibility announcer. Pairs Completed / Failed with `resetProgress` so
/// the per-identifier progress-bucket state machine can re-fire on the next
/// download for the same book.
/// Non-final so test-only subclasses (e.g. `SpyAnnouncementService` in
/// BookReturnServiceTests) can override individual announce methods. The
/// dynamic-dispatch cost is trivial — none of these are on a hot path.
class DownloadAnnouncementService {

    private let announcer: DownloadLifecycleAnnouncing

    init(announcer: DownloadLifecycleAnnouncing = TPPAccessibilityAnnouncementCenter()) {
        self.announcer = announcer
    }

    // MARK: - Download Lifecycle

    func announceDownloadStarted(for book: TPPBook) {
        announcer.announceDownloadStarted(title: book.title, identifier: book.identifier)
    }

    func announceDownloadProgress(for book: TPPBook, progress: Double) {
        announcer.announceDownloadProgress(
            title: book.title,
            identifier: book.identifier,
            progress: progress
        )
    }

    func announceDownloadCompleted(for book: TPPBook) {
        announcer.announceDownloadCompleted(title: book.title)
        announcer.resetProgress(identifier: book.identifier)
    }

    func announceDownloadFailed(for book: TPPBook) {
        announcer.announceDownloadFailed(title: book.title)
        announcer.resetProgress(identifier: book.identifier)
    }

    // MARK: - Borrow

    func announceBorrowStarted(for book: TPPBook) {
        announcer.announceBorrowStarted(title: book.title)
    }

    func announceBorrowSucceeded(for book: TPPBook) {
        announcer.announceBorrowSucceeded(title: book.title)
    }

    func announceBorrowFailed(for book: TPPBook) {
        announcer.announceBorrowFailed(title: book.title)
    }

    // MARK: - Return

    func announceReturnStarted(for book: TPPBook) {
        announcer.announceReturnStarted(title: book.title)
    }

    func announceReturnSucceeded(for book: TPPBook) {
        announcer.announceReturnSucceeded(title: book.title)
    }

    func announceReturnFailed(for book: TPPBook) {
        announcer.announceReturnFailed(title: book.title)
    }
}
