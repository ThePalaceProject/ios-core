//
//  TPPAccessibilityAnnouncementCenter.swift
//  Palace
//
//  Created by The Palace Project on 2/6/26.
//

import UIKit
import PalaceCatalog

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
// `@unchecked Sendable`: all mutable stored state (progress buckets, recent
// announcements, transition/queue state, pending work item, observers) is
// guarded by `lock` (NSLock); the injected handlers are immutable `let`s.
// Safe to capture `self` in the main-queue dispatch and observer closures.
final class TPPAccessibilityAnnouncementCenter: @unchecked Sendable {
    // Swift 6 `complete`: the injected handlers are stored `let`s captured into
    // `@Sendable` main-queue dispatches (e.g. `[postHandler]` in `announce`), so the
    // handler types are `@Sendable`. `PostHandler` is additionally `@MainActor`
    // because posting a VoiceOver announcement is a main-actor UIKit operation and
    // is only ever invoked on the main queue; the default value calls the
    // `@MainActor` `UIAccessibility.post`. The VoiceOver-running and time providers
    // stay nonisolated `@Sendable` (read from `announce`, which may run off-main);
    // their defaults read thread-safe values.
    typealias PostHandler = @MainActor @Sendable (UIAccessibility.Notification, String) -> Void
    typealias VoiceOverRunningProvider = @Sendable () -> Bool
    typealias TimeProvider = @Sendable () -> Date

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
    private var voiceOverStatusObserver: NSObjectProtocol?

    /// Thread-safe cache of `UIAccessibility.isVoiceOverRunning` (which is
    /// `@MainActor`-isolated under `complete`). `announce(_:)` — the caller of the
    /// VoiceOver provider — can run off the main thread (e.g. background download
    /// progress callbacks), so it needs an off-main-readable value. This lock-backed
    /// box is seeded once on the main actor and refreshed by the
    /// `voiceOverStatusDidChange` observer; the default provider closure reads it
    /// nonisolated. Preserves the prior behavior (the old code read the thread-safe
    /// flag directly off-main) without an off-main `@MainActor` access.
    private let voiceOverRunningCache = LockedFlag(initialValue: false)

    /// Seeds `voiceOverRunningCache` from the real flag on the main actor.
    @MainActor private func seedVoiceOverRunningCache() {
        voiceOverRunningCache.set(UIAccessibility.isVoiceOverRunning)
    }

    init(
        postHandler: @escaping PostHandler = { UIAccessibility.post(notification: $0, argument: $1) },
        isVoiceOverRunning: VoiceOverRunningProvider? = nil,
        timeProvider: @escaping TimeProvider = { Date() },
        progressStep: Int = 20,
        deduplicationInterval: TimeInterval = 2.0,
        transitionSettleDelay: TimeInterval = 1.5,
        announcementTimeout: TimeInterval = 4.0
    ) {
        self.postHandler = postHandler
        // When no provider is injected (production), read the lock-backed
        // VoiceOver-running cache, which is seeded/refreshed on the main actor.
        // Tests inject their own deterministic provider.
        let cache = voiceOverRunningCache
        self.isVoiceOverRunning = isVoiceOverRunning ?? { cache.get() }
        self.timeProvider = timeProvider
        self.progressStep = max(5, progressStep)
        self.deduplicationInterval = deduplicationInterval
        self.transitionSettleDelay = transitionSettleDelay
        self.announcementTimeout = announcementTimeout
        setupObservers()
        // Seed the cache from the real flag. When constructed on the main thread
        // (the production path, via AppContainer) seed SYNCHRONOUSLY so there is
        // no startup window in which `announce()` reads a stale `false` and
        // suppresses a VoiceOver announcement; otherwise seed as soon as we can
        // hop to the main actor.
        if Thread.isMainThread {
            MainActor.assumeIsolated { seedVoiceOverRunningCache() }
        } else {
            Task { @MainActor [weak self] in self?.seedVoiceOverRunningCache() }
        }
    }

    deinit {
        if let observer = transitionObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = announcementFinishedObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = voiceOverStatusObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        pendingDrainWorkItem?.cancel()
    }

    // MARK: - Screen Transition Awareness

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

    // MARK: - Retry Announcements

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

    // MARK: - Search Announcements

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

    // MARK: - Error / Status Announcements

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
                // On the main queue; `assumeIsolated` to call the `@MainActor`
                // post handler.
                MainActor.assumeIsolated {
                    postHandler(.announcement, message)
                }
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

        // `drainNext` is only ever scheduled via `DispatchQueue.main.asyncAfter`
        // (see `scheduleQueueDrain` and the work item below), so we are provably
        // on the main actor; `assumeIsolated` to call the `@MainActor` post handler.
        MainActor.assumeIsolated {
            postHandler(.announcement, message)
        }

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

        // Refresh the off-main-readable VoiceOver-running cache whenever the OS
        // toggles VoiceOver. Delivered on `.main`, so the `@MainActor`
        // `UIAccessibility.isVoiceOverRunning` read is valid.
        voiceOverStatusObserver = NotificationCenter.default.addObserver(
            forName: UIAccessibility.voiceOverStatusDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.seedVoiceOverRunningCache() }
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

// MARK: - LockedFlag

/// Minimal lock-protected `Bool`, readable/writable from any thread. Backs the
/// off-main VoiceOver-running cache in `TPPAccessibilityAnnouncementCenter`.
/// Mirrors the `AccountBoolFlag` lock-backed-`Bool` precedent.
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool

    init(initialValue: Bool) { self.value = initialValue }

    func get() -> Bool { lock.withLock { value } }
    func set(_ newValue: Bool) { lock.withLock { value = newValue } }
}
