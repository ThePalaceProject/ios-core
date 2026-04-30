//
//  DownloadThrottlingService.swift
//  Palace
//
//  Owns the active-download concurrency cap, suspend/resume orchestration,
//  and the network-conditions observer that re-applies the cap whenever the
//  app becomes active. Extracted from MyBooksDownloadCenter so the
//  concurrency policy can be exercised in isolation with a test
//  DownloadStateManager + NotificationCenter.
//
//  Audiobooks are special: pauseAllDownloads / limitActiveDownloads-when-
//  over-cap both refuse to suspend audiobook tasks because the user may be
//  streaming and a suspend would interrupt playback.
//
//  MyBooksDownloadCenter still exposes the same `limitActiveDownloads(max:)`
//  / `pauseAllDownloads()` / `resumeIntelligentDownloads()` API surface for
//  the @objc TPPAppDelegate + memoryPressureMonitor callers — those methods
//  now delegate here.
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

// MARK: - DownloadThrottlingService

/// Concurrency policy for the download center. Suspends non-audiobook tasks
/// when over the cap, resumes suspended tasks when under it, and re-applies
/// the cap whenever the app becomes active again.
final class DownloadThrottlingService {

    weak var delegate: DownloadThrottlingServiceDelegate?

    private let stateManager: DownloadStateManager
    private let notificationCenter: NotificationCenter

    /// Block-based observer registration handle so `deinit` can clean up
    /// without forcing the service to be `@objc` selector-callable.
    private var didBecomeActiveObserver: NSObjectProtocol?

    init(
        stateManager: DownloadStateManager,
        notificationCenter: NotificationCenter = .default
    ) {
        self.stateManager = stateManager
        self.notificationCenter = notificationCenter
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

        Task { [weak self] in
            await self?.limitActiveDownloadsAsync(max: max)
        }
    }

    private func limitActiveDownloadsAsync(max: Int) async {
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
    /// connection mid-stream.
    func pauseAllDownloads() {
        Task { [weak self] in
            await self?.pauseAllDownloadsAsync()
        }
    }

    private func pauseAllDownloadsAsync() async {
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
