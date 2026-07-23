//
//  DownloadQueueOrchestrator.swift
//  Palace
//
//  Owns the pending-download queue management that lived inside
//  MyBooksDownloadCenter as `enqueuePending(_:)` /
//  `schedulePendingStartsIfPossible()` / `schedulePendingStartsAsync()`.
//
//  Encapsulates the read of the active-count + max-concurrent-downloads
//  cap, the dequeue-up-to-capacity step, and the per-book startDownload
//  fan-out — the policy that runs every time the active set shrinks or a
//  new download is requested past the cap.
//
//  MyBooksDownloadCenter keeps `schedulePendingStartsIfPossible()` as a
//  1-line delegator so the existing public surface (called from
//  BackgroundDownloadHandler / DownloadAlertPresenter / multiple internal
//  call sites) is preserved, AND keeps `schedulePendingStartsAsync()` as
//  a 1-line delegator so DownloadThrottlingService's delegate protocol
//  still resolves through the same MBDC seam.
//
//  The `enqueuePending` path is internal-only and only had a single
//  caller in `startDownloadAsync`, so MBDC routes through
//  `queueOrchestrator.enqueuePending(book)` directly rather than keeping
//  a wrapper.
//

import Foundation
import PalaceLogging
import PalaceBookModel

// MARK: - DownloadQueueOrchestratorDelegate

/// Surface MBDC needs to expose so the orchestrator can spin up the
/// per-book download workflow once a queued book has been dequeued.
/// `startDownloadAsync(for:withRequest:)` already exists on MBDC's
/// surface — promoted from `private` to `internal` so the delegate
/// protocol's empty conformance resolves.
protocol DownloadQueueOrchestratorDelegate: AnyObject {
    func startDownloadAsync(for book: TPPBook, withRequest request: URLRequest?) async
}

// MARK: - DownloadQueueOrchestrator

/// Coordinates the pending-download queue: parks books past the
/// concurrency cap with the right state-broadcast UX, and pumps the
/// queue whenever capacity opens up.
///
/// - Sendable invariant (Swift 6 `complete`-mode): the stored dependencies
///   (`bookRegistry`, `stateManager`, `notificationCenter`) are all `let` bound
///   at init; the only mutable member is `weak var delegate`, assigned exactly
///   once during owner (`MyBooksDownloadCenter`) construction and never
///   reassigned (weak-ref reads + ARC zeroing are atomic). The enqueue / pump
///   paths hop into `Task { }`, touching only the actor-serialized
///   `stateManager.downloadCoordinator` and posting on `notificationCenter`
///   (thread-safe). `@unchecked` only because the stored service types are not
///   themselves `Sendable`.
final class DownloadQueueOrchestrator: @unchecked Sendable {

    weak var delegate: DownloadQueueOrchestratorDelegate?

    private let bookRegistry: TPPBookRegistryProvider
    private let stateManager: DownloadStateManager
    private let notificationCenter: NotificationCenter

    /// `downloadCoordinator` and `maxConcurrentDownloads` resolve through
    /// `stateManager` so the orchestrator and MBDC share the same view of
    /// the download state machine — no duplicated state, no drift.
    private var downloadCoordinator: DownloadCoordinator { stateManager.downloadCoordinator }
    private var maxConcurrentDownloads: Int { stateManager.maxConcurrentDownloads }

    init(
        bookRegistry: TPPBookRegistryProvider,
        stateManager: DownloadStateManager,
        notificationCenter: NotificationCenter = .default
    ) {
        self.bookRegistry = bookRegistry
        self.stateManager = stateManager
        self.notificationCenter = notificationCenter
    }

    // MARK: - Enqueue

    /// Parks `book` on the pending-download queue. Sets the registry
    /// state to `.downloading` first so the UI shows a "Downloading"
    /// label immediately — without this the borrow button looks
    /// unresponsive once the active-cap is hit. After enqueueing,
    /// broadcasts a NotificationCenter update so MyBooks / detail / cell
    /// views refresh.
    func enqueuePending(_ book: TPPBook) {
        // CRITICAL UI FIX: Update book state so button shows "Downloading" feedback
        // Otherwise button appears unresponsive when hitting queue limit
        bookRegistry.setState(.downloading, for: book.identifier)

        Task { [weak self] in
            await self?.enqueuePendingAsync(book)
        }
    }

    /// Async body of `enqueuePending`: the actor-hopping portion (coordinator
    /// enqueue + DidChange broadcast) that `enqueuePending` fires as a
    /// detached `Task`. Exposed so callers already inside an `async` context
    /// — and tests — can `await` the enqueue to completion deterministically
    /// instead of polling for the resulting queue/notification state. Mirrors
    /// the `schedulePendingStartsIfPossible()` → `schedulePendingStartsAsync()`
    /// split. The synchronous `.downloading` state broadcast stays in
    /// `enqueuePending` (it runs before the Task hop, same as before).
    func enqueuePendingAsync(_ book: TPPBook) async {
        await self.downloadCoordinator.enqueuePending(book)
        let queueSize = await self.downloadCoordinator.queueCount
        Log.debug(#file, "📋 Enqueued '\(book.title)' for download, queue size: \(queueSize)")

        // Notify UI to refresh
        runOnMainAsync {
            self.notificationCenter.post(name: .TPPMyBooksDownloadCenterDidChange, object: nil)
        }
    }

    // MARK: - Schedule pending starts

    /// Fire-and-forget kickoff for `schedulePendingStartsAsync()`. The
    /// async variant is also exposed so callers already inside an
    /// `async` context can `await` it directly without re-entering the
    /// Task hop.
    func schedulePendingStartsIfPossible() {
        Task { [weak self] in
            await self?.schedulePendingStartsAsync()
        }
    }

    /// Computes remaining capacity (cap - active), dequeues up to that
    /// many books, and asks the delegate to start each one. No-ops when
    /// already at the cap or when the queue is empty.
    func schedulePendingStartsAsync() async {
        let activeCount = await downloadCoordinator.activeCount
        let capacity = maxConcurrentDownloads - activeCount

        guard capacity > 0 else { return }

        let toStart = await downloadCoordinator.dequeuePending(capacity: capacity)
        guard !toStart.isEmpty else { return }

        let queueRemaining = await downloadCoordinator.queueCount
        Log.info(#file, "📋 Starting \(toStart.count) pending downloads (capacity: \(capacity), queue remaining: \(queueRemaining))")

        for book in toStart {
            await delegate?.startDownloadAsync(for: book, withRequest: nil)
        }
    }
}
