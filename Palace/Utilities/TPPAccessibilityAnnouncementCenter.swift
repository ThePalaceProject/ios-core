//
//  TPPAccessibilityAnnouncementCenter.swift
//  Palace
//
//  Created by The Palace Project on 2/6/26.
//

import UIKit

extension Notification.Name {
    /// Posted by views when a screen transition occurs (sheet presented, page navigated).
    /// The announcement center listens for this to delay announcements until the transition settles
    /// and VoiceOver finishes reading the new screen's elements.
    static let TPPAccessibilityScreenTransition = Notification.Name("TPPAccessibilityScreenTransition")
}

/// Centralized VoiceOver announcements for background events.
///
/// Provides a single place to post `UIAccessibility.announcement`
/// notifications so that VoiceOver announces status changes without
/// moving focus. The center includes deduplication: if the same message
/// is posted within `deduplicationInterval` seconds it is suppressed to
/// avoid flooding the user with repeated announcements (PP-3673).
///
/// **Transition-aware queuing (PP-3839):**
/// When a screen transition is signaled (via `notifyScreenTransition()` or the
/// `TPPAccessibilityScreenTransition` notification), announcements are queued
/// and delivered sequentially after the transition settles, so they don't get
/// cut off by VoiceOver reading new screen elements. Outside transition windows,
/// announcements are delivered immediately (preserving existing behavior).
final class TPPAccessibilityAnnouncementCenter {
    typealias PostHandler = (UIAccessibility.Notification, String) -> Void
    typealias VoiceOverRunningProvider = () -> Bool
    typealias TimeProvider = () -> Date

    private let postHandler: PostHandler
    private let isVoiceOverRunning: VoiceOverRunningProvider
    private let timeProvider: TimeProvider
    private let progressStep: Int
    private let deduplicationInterval: TimeInterval
    private let transitionSettleDelay: TimeInterval
    private let announcementTimeout: TimeInterval
    private let lock = NSLock()

    private var lastProgressBucketByKey: [String: Int] = [:]
    private var recentAnnouncements: [String: Date] = [:]

    // Transition-aware queuing state
    private var lastTransitionDate: Date?
    private var queuedAnnouncements: [String] = []
    private var isProcessingQueue = false
    private var pendingDrainWorkItem: DispatchWorkItem?
    private var transitionObserver: NSObjectProtocol?
    private var announcementFinishedObserver: NSObjectProtocol?

    init(
        postHandler: @escaping PostHandler = { UIAccessibility.post(notification: $0, argument: $1) },
        isVoiceOverRunning: @escaping VoiceOverRunningProvider = { UIAccessibility.isVoiceOverRunning },
        timeProvider: @escaping TimeProvider = { Date() },
        progressStep: Int = 20,
        deduplicationInterval: TimeInterval = 2.0,
        transitionSettleDelay: TimeInterval = 1.5,
        announcementTimeout: TimeInterval = 4.0
    ) {
        self.postHandler = postHandler
        self.isVoiceOverRunning = isVoiceOverRunning
        self.timeProvider = timeProvider
        self.progressStep = max(5, progressStep)
        self.deduplicationInterval = deduplicationInterval
        self.transitionSettleDelay = transitionSettleDelay
        self.announcementTimeout = announcementTimeout
        setupObservers()
    }

    deinit {
        if let observer = transitionObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = announcementFinishedObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        pendingDrainWorkItem?.cancel()
    }

    // MARK: - Screen Transition Awareness (PP-3839)

    /// Signal that a screen transition just occurred. Announcements will be
    /// queued and delivered after `transitionSettleDelay` seconds, giving
    /// VoiceOver time to finish reading the new screen content.
    func notifyScreenTransition() {
        lock.lock()
        lastTransitionDate = timeProvider()
        lock.unlock()
    }

    // MARK: - Download Announcements

    func announceDownloadStarted(title: String, identifier: String? = nil) {
        if let identifier {
            lock.lock()
            lastProgressBucketByKey.removeValue(forKey: identifier)
            lock.unlock()
        }
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
        let percent = progressPercent(progress)
        guard percent < 100 else { return }
        let bucket = progressBucket(for: percent)
        guard shouldAnnounceProgress(identifier: identifier, bucket: bucket) else { return }
        announce(Strings.DownloadAnnouncements.downloadProgress(title, percent))
    }

    func resetProgress(identifier: String) {
        lock.lock()
        lastProgressBucketByKey[identifier] = Int.max
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

    // MARK: - Private — Announcement Delivery

    private func announce(_ message: String) {
        guard isVoiceOverRunning() else { return }
        guard !message.isEmpty else { return }
        guard shouldAnnounce(message: message) else { return }

        lock.lock()
        if isProcessingQueue || isInTransitionPeriod() {
            queuedAnnouncements.append(message)
            if !isProcessingQueue {
                isProcessingQueue = true
                let delay = remainingTransitionDelay()
                lock.unlock()
                scheduleQueueDrain(after: delay)
            } else {
                lock.unlock()
            }
        } else {
            lock.unlock()
            DispatchQueue.main.async { [postHandler] in
                postHandler(.announcement, message)
            }
        }
    }

    // MARK: - Private — Queue Processing

    private func scheduleQueueDrain(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.drainNext()
        }
    }

    private func drainNext() {
        lock.lock()
        guard !queuedAnnouncements.isEmpty else {
            isProcessingQueue = false
            pendingDrainWorkItem?.cancel()
            pendingDrainWorkItem = nil
            lock.unlock()
            return
        }
        let message = queuedAnnouncements.removeFirst()
        lock.unlock()

        postHandler(.announcement, message)

        let workItem = DispatchWorkItem { [weak self] in
            self?.drainNext()
        }
        lock.lock()
        pendingDrainWorkItem = workItem
        lock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + announcementTimeout, execute: workItem)
    }

    private func onAnnouncementFinished() {
        lock.lock()
        guard isProcessingQueue else {
            lock.unlock()
            return
        }
        pendingDrainWorkItem?.cancel()
        pendingDrainWorkItem = nil
        lock.unlock()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.drainNext()
        }
    }

    // MARK: - Private — Transition Helpers

    private func isInTransitionPeriod() -> Bool {
        guard let lastTransition = lastTransitionDate else { return false }
        return timeProvider().timeIntervalSince(lastTransition) < transitionSettleDelay
    }

    private func remainingTransitionDelay() -> TimeInterval {
        guard let lastTransition = lastTransitionDate else { return 0 }
        return max(0, transitionSettleDelay - timeProvider().timeIntervalSince(lastTransition))
    }

    // MARK: - Private — Observer Setup

    private func setupObservers() {
        transitionObserver = NotificationCenter.default.addObserver(
            forName: .TPPAccessibilityScreenTransition,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.notifyScreenTransition()
        }

        announcementFinishedObserver = NotificationCenter.default.addObserver(
            forName: UIAccessibility.announcementDidFinishNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.onAnnouncementFinished()
        }
    }

    // MARK: - Private — Deduplication

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

    // MARK: - Private — Progress Helpers

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
