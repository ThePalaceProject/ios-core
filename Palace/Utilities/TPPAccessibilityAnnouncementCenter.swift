//
//  TPPAccessibilityAnnouncementCenter.swift
//  Palace
//
//  Created by The Palace Project on 2/6/26.
//

import UIKit

/// Centralized VoiceOver announcements for background events.
///
/// Provides a single place to post `UIAccessibility.announcement`
/// notifications so that VoiceOver announces status changes without
/// moving focus. The center includes deduplication: if the same message
/// is posted within `deduplicationInterval` seconds it is suppressed to
/// avoid flooding the user with repeated announcements (PP-3673).
final class TPPAccessibilityAnnouncementCenter {
    typealias PostHandler = (UIAccessibility.Notification, String) -> Void
    typealias VoiceOverRunningProvider = () -> Bool
    typealias TimeProvider = () -> Date

    private let postHandler: PostHandler
    private let isVoiceOverRunning: VoiceOverRunningProvider
    private let timeProvider: TimeProvider
    private let progressStep: Int
    private let deduplicationInterval: TimeInterval
    private let lock = NSLock()

    private var lastProgressBucketByKey: [String: Int] = [:]
    private var recentAnnouncements: [String: Date] = [:]

    init(
        postHandler: @escaping PostHandler = { UIAccessibility.post(notification: $0, argument: $1) },
        isVoiceOverRunning: @escaping VoiceOverRunningProvider = { UIAccessibility.isVoiceOverRunning },
        timeProvider: @escaping TimeProvider = { Date() },
        progressStep: Int = 20,
        deduplicationInterval: TimeInterval = 2.0
    ) {
        self.postHandler = postHandler
        self.isVoiceOverRunning = isVoiceOverRunning
        self.timeProvider = timeProvider
        self.progressStep = max(5, progressStep)
        self.deduplicationInterval = deduplicationInterval
    }

    // MARK: - Download Announcements

    func announceDownloadStarted(title: String) {
        announce(Strings.DownloadAnnouncements.downloadStarted(title))
    }

    func announceDownloadCompleted(title: String) {
        announce(Strings.DownloadAnnouncements.downloadCompleted(title))
    }

    func announceDownloadFailed(title: String) {
        announce(Strings.DownloadAnnouncements.downloadFailed(title))
    }

    // MARK: - Borrow Announcements

    func announceBorrowStarted(title: String) {
        announce(Strings.DownloadAnnouncements.borrowStarted(title))
    }

    func announceBorrowSucceeded(title: String) {
        announce(Strings.DownloadAnnouncements.borrowSucceeded(title))
    }

    func announceBorrowFailed(title: String) {
        announce(Strings.DownloadAnnouncements.borrowFailed(title))
    }

    // MARK: - Return Announcements

    func announceReturnStarted(title: String) {
        announce(Strings.DownloadAnnouncements.returnStarted(title))
    }

    func announceReturnSucceeded(title: String) {
        announce(Strings.DownloadAnnouncements.returnSucceeded(title))
    }

    func announceReturnFailed(title: String) {
        announce(Strings.DownloadAnnouncements.returnFailed(title))
    }

    // MARK: - Retry Announcements (PP-3707)

    func announceRetryingBorrow(title: String) {
        announce(Strings.DownloadAnnouncements.retryingBorrow(title))
    }

    func announceRetryingReturn(title: String) {
        announce(Strings.DownloadAnnouncements.retryingReturn(title))
    }

    func announceRetryingDownload(title: String) {
        announce(Strings.DownloadAnnouncements.retryingDownload(title))
    }

    // MARK: - Download Progress

    func announceDownloadProgress(title: String, identifier: String, progress: Double) {
        // Intermediate progress announcements are suppressed; only start and
        // completion are announced so VoiceOver users are not interrupted while
        // listening to a book.
    }

    func resetProgress(identifier: String) {
        lock.lock()
        lastProgressBucketByKey.removeValue(forKey: identifier)
        lock.unlock()
    }

    // MARK: - Search Announcements (PP-3673)

    func announceSearchResults(query: String, count: Int) {
        if count > 0 {
            announce(Strings.SearchAnnouncements.searchResultsFound(query, count: count))
        } else {
            announce(Strings.SearchAnnouncements.noSearchResults(query))
        }
    }

    func announceSearchFailed() {
        announce(Strings.SearchAnnouncements.searchFailed())
    }

    func announceLoadingMoreResults() {
        announce(Strings.SearchAnnouncements.loadingMoreResults())
    }

    func announceAdditionalResultsLoaded(count: Int) {
        guard count > 0 else { return }
        announce(Strings.SearchAnnouncements.additionalResultsLoaded(count))
    }

    // MARK: - Error / Status Announcements (PP-3673)

    /// Announces an error message without moving VoiceOver focus.
    /// Duplicate messages within `deduplicationInterval` are suppressed.
    func announceError(_ message: String) {
        announce(Strings.StatusAnnouncements.errorOccurred(message))
    }

    /// Announces a titled status message, e.g. an error alert title + body.
    func announceStatus(title: String, message: String) {
        announce(Strings.StatusAnnouncements.actionFailed(title: title, message: message))
    }

    // MARK: - General Purpose

    /// Post an arbitrary status message as a VoiceOver announcement.
    /// Respects deduplication: the same `message` within `deduplicationInterval`
    /// seconds will be suppressed automatically.
    func announceMessage(_ message: String) {
        announce(message)
    }

    // MARK: - Private

    private func announce(_ message: String) {
        guard isVoiceOverRunning() else { return }
        guard !message.isEmpty else { return }
        guard shouldAnnounce(message: message) else { return }
        DispatchQueue.main.async { [postHandler] in
            postHandler(.announcement, message)
        }
    }

    private func shouldAnnounce(message: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = timeProvider()
        if let lastTime = recentAnnouncements[message],
           now.timeIntervalSince(lastTime) < deduplicationInterval {
            return false
        }
        recentAnnouncements[message] = now
        recentAnnouncements = recentAnnouncements.filter { _, time in
            now.timeIntervalSince(time) < deduplicationInterval
        }
        return true
    }

    // MARK: - Progress Helpers

    private func progressPercent(_ progress: Double) -> Int {
        let clamped = max(0.0, min(1.0, progress))
        return Int((clamped * 100.0).rounded(.down))
    }

    private func progressBucket(for percent: Int) -> Int {
        guard percent > 0 else { return 0 }
        return (percent / progressStep) * progressStep
    }

    private func shouldAnnounceProgress(identifier: String, bucket: Int) -> Bool {
        guard bucket > 0 else { return false }
        lock.lock()
        defer { lock.unlock() }
        let lastBucket = lastProgressBucketByKey[identifier] ?? -progressStep
        guard bucket > lastBucket else { return false }
        lastProgressBucketByKey[identifier] = bucket
        return true
    }
}
