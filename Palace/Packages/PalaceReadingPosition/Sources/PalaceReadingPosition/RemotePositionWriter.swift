//
//  RemotePositionWriter.swift
//  PalaceReadingPosition
//
//  The canonical, network-backed `PositionWriter`. Throttles per-book to
//  a configurable window, coalesces queued snapshots inside the window,
//  and wraps every POST in a UIApplication background-task on iOS so
//  callers don't need to think about app suspension.
//
//  Concurrency: a serial `DispatchQueue` guards all bookkeeping. The
//  network calls themselves are dispatched off-queue via Swift
//  concurrency, so the queue never blocks on I/O.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import PalaceLogging
#if canImport(UIKit)
import UIKit
#endif

/// Concrete `PositionWriter` that posts via an injected
/// `PositionNetworkAdapter` and applies per-`bookID` throttling.
///
/// Not an `actor`: the writer owns `UIBackgroundTaskIdentifier` lifetime,
/// and `UIApplication.beginBackgroundTask`/`endBackgroundTask` are not
/// actor-isolated. The existing `TPPLastReadPositionPoster.serialQueue`
/// pattern is the template.
public final class RemotePositionWriter: PositionWriter, @unchecked Sendable {

    // MARK: - Dependencies

    private let network: PositionNetworkAdapter
    private let throttle: TimeInterval
    private let clock: @Sendable () -> Date

    // MARK: - State (guarded by `queue`)

    private let queue = DispatchQueue(
        label: "org.thepalaceproject.palacereadingposition.RemotePositionWriter",
        qos: .utility
    )

    /// Per-book bookkeeping. Keyed by bookID.
    private var state: [String: BookState] = [:]

    private struct BookState {
        /// Wall-clock time of the most recent in-flight or completed POST.
        /// New snapshots within `throttle` of this time are queued, not
        /// posted immediately.
        var lastPostAttempt: Date
        /// The snapshot waiting for the throttle window to elapse. Older
        /// queued snapshots are silently dropped when a newer one arrives.
        var queued: PositionSnapshot?
        /// Set when a deferred-flush task is scheduled. We only ever have
        /// one deferred flush pending per book.
        var deferredFlushScheduled: Bool
    }

    // MARK: - Init

    public init(
        network: PositionNetworkAdapter,
        throttle: TimeInterval = 15.0,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.network = network
        self.throttle = throttle
        self.clock = clock
    }

    // MARK: - PositionWriter

    public func save(_ snapshot: PositionSnapshot) async throws -> ServerPositionID? {
        // Decide synchronously on the serial queue whether to post now or
        // queue for later. If we post now, we return the server ID from
        // the network call; if we queue, we return `nil`.
        let decision: SaveDecision = await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: .drop)
                    return
                }
                continuation.resume(returning: self.decideOnQueue(for: snapshot))
            }
        }

        switch decision {
        case .postNow(let snapshot):
            return try await performPost(snapshot)
        case .queueAndDefer:
            return nil
        case .drop:
            return nil
        }
    }

    public func load(for bookID: String) async throws -> PositionSnapshot? {
        try await network.fetch(bookID: bookID)
    }

    public func cancel(for bookID: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [weak self] in
                self?.state.removeValue(forKey: bookID)
                continuation.resume()
            }
        }
    }

    // MARK: - Decision (serial-queue isolated)

    private enum SaveDecision {
        case postNow(PositionSnapshot)
        case queueAndDefer
        case drop
    }

    /// Called from `queue`. Mutates `state`.
    private func decideOnQueue(for snapshot: PositionSnapshot) -> SaveDecision {
        let now = clock()
        var bookState = state[snapshot.bookID] ?? BookState(
            lastPostAttempt: .distantPast,
            queued: nil,
            deferredFlushScheduled: false
        )

        let elapsed = now.timeIntervalSince(bookState.lastPostAttempt)
        if elapsed >= throttle {
            // Window open — post now. Reserve the slot by stamping
            // `lastPostAttempt` so concurrent calls queue.
            bookState.lastPostAttempt = now
            // Posting now supersedes any queued snapshot.
            bookState.queued = nil
            state[snapshot.bookID] = bookState
            return .postNow(snapshot)
        }

        // Inside window — queue the latest snapshot, scheduling a deferred
        // flush if one isn't already scheduled.
        bookState.queued = snapshot
        let remaining = max(throttle - elapsed, 0)
        if !bookState.deferredFlushScheduled {
            bookState.deferredFlushScheduled = true
            scheduleDeferredFlush(for: snapshot.bookID, after: remaining)
        }
        state[snapshot.bookID] = bookState
        return .queueAndDefer
    }

    /// Schedules a deferred flush. Called from `queue`.
    private func scheduleDeferredFlush(for bookID: String, after delay: TimeInterval) {
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            guard var bookState = self.state[bookID] else { return }
            bookState.deferredFlushScheduled = false
            guard let queued = bookState.queued else {
                self.state[bookID] = bookState
                return
            }
            // Stamp the slot before launching the POST so any concurrent
            // saves queue against the new window.
            bookState.lastPostAttempt = self.clock()
            bookState.queued = nil
            self.state[bookID] = bookState

            // Fire-and-forget — the deferred flush has no caller to
            // surface errors to. Log and move on.
            Task {
                do {
                    _ = try await self.performPost(queued)
                } catch {
                    Log.error("PalaceReadingPosition",
                              "Deferred flush for \(bookID) failed: \(error)")
                }
            }
        }
    }

    // MARK: - Network

    private func performPost(_ snapshot: PositionSnapshot) async throws -> ServerPositionID {
        let taskID = beginBackgroundTask()
        defer { endBackgroundTask(taskID) }
        return try await network.post(snapshot)
    }

    // MARK: - Background-task lifetime

#if canImport(UIKit)
    private func beginBackgroundTask() -> UIBackgroundTaskIdentifier {
        UIApplication.shared.beginBackgroundTask(withName: "PalaceReadingPosition.post") {
            // Expiration handler intentionally empty — we don't have a
            // hook to cancel an in-flight URL request from here, and
            // the iOS watchdog will tear the task down anyway.
        }
    }

    private func endBackgroundTask(_ id: UIBackgroundTaskIdentifier) {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
    }
#else
    private func beginBackgroundTask() -> Int { 0 }
    private func endBackgroundTask(_ id: Int) {}
#endif
}
