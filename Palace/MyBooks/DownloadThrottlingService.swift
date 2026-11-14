//
//  DownloadThrottlingService.swift
//  Palace
//
//  The active-download concurrency cap, suspend/resume, and the observer that
//  re-applies the cap when the app becomes active. Audiobook tasks are never
//  suspended, because the patron may be streaming. MyBooksDownloadCenter's
//  `limitActiveDownloads(max:)` / `pauseDownloadsForMemoryWarning()` /
//  `resumeIntelligentDownloads()` delegate here.
//

import Foundation
import UIKit
import PalaceLogging

// MARK: - DownloadThrottlingServiceDelegate

/// Surface MBDC needs to expose so the service can re-pump the pending-
/// download queue once the active-task list shrinks (or the cap rises).
/// The async variant is required so `limitActiveDownloadsAsync` can `await`
/// the pump in-line — preserving sequential ordering across the existing
/// behavior.
protocol DownloadThrottlingServiceDelegate: AnyObject {
    func schedulePendingStartsAsync() async
}

// MARK: - Resume scheduling

/// A scheduled resume that a new memory warning can cancel.
protocol DownloadResumeCancellable: AnyObject {
    func cancel()
}

/// Runs work after a delay. Injected so tests control the quiet period after
/// a memory warning without waiting on the clock.
protocol DownloadResumeScheduling {
    func schedule(after delay: TimeInterval, _ work: @escaping @Sendable () -> Void) -> DownloadResumeCancellable
}

extension DispatchWorkItem: DownloadResumeCancellable {}

/// Schedules on the main queue, where the memory warning also arrives.
struct MainQueueResumeScheduler: DownloadResumeScheduling {
    func schedule(after delay: TimeInterval, _ work: @escaping @Sendable () -> Void) -> DownloadResumeCancellable {
        let item = DispatchWorkItem(block: work)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return item
    }
}

// MARK: - DownloadThrottlingService

/// Concurrency policy for the download center. Suspends non-audiobook tasks
/// when over the cap, resumes suspended tasks when under it, and re-applies
/// the cap whenever the app becomes active again.
///
/// - Sendable invariant (Swift 6 `complete`-mode): the stored dependencies
///   (`stateManager`, `notificationCenter`) are `let` bound at init. `weak var
///   delegate` is assigned exactly once during owner (`MyBooksDownloadCenter`)
///   construction (weak-ref reads + ARC zeroing are atomic). The only other
///   mutable member, `didBecomeActiveObserver`, is written only in
///   `setupNetworkMonitoring` (invoked once, on the main thread, during owner
///   wiring) and read in `deinit` — a single-threaded lifecycle, never touched
///   from the `Task { }` hops. Those hops touch only the actor-serialized
///   `stateManager.downloadCoordinator` / `SafeDictionary` members and the
///   `URLSessionTask` suspend/resume API (thread-safe). `pendingMemoryResume`
///   is guarded by `pendingMemoryResumeLock`; `lastMemoryWarningTask` is
///   written by the memory warning step on the main thread. `@unchecked` only
///   because the stored service types are not themselves `Sendable`.
final class DownloadThrottlingService: @unchecked Sendable {

    weak var delegate: DownloadThrottlingServiceDelegate?

    /// Handle to the most recent Task spawned by `limitActiveDownloads(max:)`
    /// (including the app-became-active observer path). That method applies
    /// its suspend/resume policy inside a fire-and-forget `Task { }`; retaining
    /// the handle lets tests `await lastLimitActiveDownloadsTask?.value` to
    /// join the policy deterministically after driving the notification-based
    /// observer, instead of polling task suspend/resume counts against a
    /// deadline. Behavior is unchanged: the same Task is created and runs
    /// exactly as before; only a reference is now kept.
    private(set) var lastLimitActiveDownloadsTask: Task<Void, Never>?

    /// Handle to the Task spawned by `pauseDownloadsForMemoryWarning()`, so
    /// tests can join the pause.
    private(set) var lastMemoryWarningTask: Task<Void, Never>?

    /// The quiet period after the last memory warning before paused
    /// downloads resume (PP-5587).
    static let memoryRecoveryDelay: TimeInterval = 30

    private let stateManager: DownloadStateManager
    private let notificationCenter: NotificationCenter
    private let resumeScheduler: DownloadResumeScheduling
    /// The resume scheduled by the last memory warning. Warnings and the
    /// resume arrive on different threads.
    private var pendingMemoryResume: DownloadResumeCancellable?
    private let pendingMemoryResumeLock = NSLock()

    /// Block-based observer registration handle so `deinit` can clean up
    /// without forcing the service to be `@objc` selector-callable.
    private var didBecomeActiveObserver: NSObjectProtocol?

    init(
        stateManager: DownloadStateManager,
        notificationCenter: NotificationCenter = .default,
        resumeScheduler: DownloadResumeScheduling = MainQueueResumeScheduler()
    ) {
        self.stateManager = stateManager
        self.notificationCenter = notificationCenter
        self.resumeScheduler = resumeScheduler
    }

    deinit {
        if let observer = didBecomeActiveObserver {
            notificationCenter.removeObserver(observer)
        }
    }

    // MARK: - Active-cap orchestration

    /// Sets the new max-concurrent-downloads target and applies it
    /// immediately: suspends excess non-audiobook tasks if running > max,
    /// resumes suspended tasks if running < max. Then asks the delegate to
    /// re-pump pending starts in case the cap rose.
    func limitActiveDownloads(max: Int) {
        stateManager.maxConcurrentDownloads = max

        lastLimitActiveDownloadsTask = Task { [weak self] in
            await self?.limitActiveDownloadsAsync(max: max)
        }
    }

    /// Async body of `limitActiveDownloads`. `internal` (not `private`) so
    /// callers already inside an `async` context — and tests — can `await`
    /// the suspend/resume + pending-pump to completion deterministically
    /// instead of polling for the delegate's schedule call. Behavior is
    /// unchanged; only the access level widened.
    func limitActiveDownloadsAsync(max: Int) async {
        let allInfo = await stateManager.bookIdentifierToDownloadInfo.values()
        let running = allInfo.compactMap { $0.downloadTask }.filter { $0.state == .running }
        let suspended = allInfo.compactMap { $0.downloadTask }.filter { $0.state == .suspended }

        if running.count > max {
            var nonAudiobookTasks: [URLSessionTask] = []
            for task in running {
                if let book = await stateManager.taskIdentifierToBook.get(task.taskIdentifier) {
                    if book.defaultBookContentType != .audiobook {
                        nonAudiobookTasks.append(task)
                    }
                } else {
                    nonAudiobookTasks.append(task)
                }
            }

            let tasksToSuspend = nonAudiobookTasks.dropFirst(Swift.max(0, max - (running.count - nonAudiobookTasks.count)))
            for task in tasksToSuspend {
                Log.info(#file, "Suspending non-audiobook download to respect limits")
                task.suspend()
            }
        } else if running.count < max {
            let toResume = min(max - running.count, suspended.count)
            if toResume > 0 {
                for task in suspended.prefix(toResume) { task.resume() }
            }
        }
        await delegate?.schedulePendingStartsAsync()
    }

    /// Suspends every non-audiobook download task. Audiobook tasks survive
    /// because the user may be streaming — a suspend would tear the
    /// connection mid-stream. `internal` (not `private`) so
    /// callers already inside an `async` context — and tests — can `await` the
    /// suspend fan-out to completion deterministically instead of polling.
    func pauseAllDownloadsAsync() async {
        let allInfo = await stateManager.bookIdentifierToDownloadInfo.values()
        for info in allInfo {
            if let book = await stateManager.taskIdentifierToBook.get(info.downloadTask.taskIdentifier),
               book.defaultBookContentType == .audiobook {
                Log.info(#file, "Preserving audiobook download/streaming for: \(book.title)")
                continue
            }
            info.downloadTask.suspend()
        }
    }

    // MARK: - Memory warning

    /// Pauses non-audiobook downloads for a memory warning, then resumes them
    /// once `memoryRecoveryDelay` passes with no further warning (PP-5587).
    /// Without the resume they stay paused until the app next becomes active.
    func pauseDownloadsForMemoryWarning() {
        // Cancel now, not inside the Task: a resume that fires before the
        // Task runs would undo this warning's pause.
        cancelPendingMemoryResume()
        lastMemoryWarningTask = Task { [weak self] in
            await self?.pauseDownloadsForMemoryWarningAsync()
        }
    }

    func pauseDownloadsForMemoryWarningAsync() async {
        await pauseAllDownloadsAsync()
        let resume = resumeScheduler.schedule(after: Self.memoryRecoveryDelay) { [weak self] in
            self?.resumeAfterMemoryRecovery()
        }
        pendingMemoryResumeLock.withLock {
            pendingMemoryResume?.cancel()
            pendingMemoryResume = resume
        }
    }

    /// Re-applies the current cap, so a thermal or power limit set during the
    /// wait still applies, and only suspended tasks resume.
    private func resumeAfterMemoryRecovery() {
        Log.info(#file, "Resuming downloads paused by a memory warning")
        limitActiveDownloads(max: stateManager.maxConcurrentDownloads)
    }

    private func cancelPendingMemoryResume() {
        pendingMemoryResumeLock.withLock {
            pendingMemoryResume?.cancel()
            pendingMemoryResume = nil
        }
    }

    /// Re-applies the current cap. Used by the network-conditions observer
    /// (and by external resume-after-throttle callers) — gives previously-
    /// suspended tasks a chance to resume now that the network is back.
    func resumeIntelligentDownloads() {
        limitActiveDownloads(max: stateManager.maxConcurrentDownloads)
    }

    // MARK: - Network monitoring

    /// Registers the app-became-active observer that re-applies the
    /// concurrency cap whenever the app foregrounds. The handle is kept on
    /// the service so `deinit` can clean up cleanly.
    func setupNetworkMonitoring() {
        // Unregister any prior observer in case `setupNetworkMonitoring` is
        // ever called more than once on the same instance.
        if let prior = didBecomeActiveObserver {
            notificationCenter.removeObserver(prior)
        }
        didBecomeActiveObserver = notificationCenter.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.limitActiveDownloads(max: self.stateManager.maxConcurrentDownloads)
        }
        Log.info(#file, "Network monitoring setup for download optimization")
    }
}
