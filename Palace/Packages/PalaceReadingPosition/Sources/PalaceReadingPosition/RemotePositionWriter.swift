//
//  RemotePositionWriter.swift
//  PalaceReadingPosition
//
//  Network-backed `PositionWriter`. Throttles per book, coalesces snapshots
//  inside the window, and wraps each POST in a background task so app
//  suspension does not drop it. A serial queue guards bookkeeping; network
//  calls run off-queue so it never blocks on I/O.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import PalaceLogging

/// Concrete `PositionWriter` that posts via an injected
/// `PositionNetworkAdapter` and applies per-`bookID` throttling.
///
/// Throttle: the first save for a book posts at once and opens a window of
/// `throttle` seconds. Saves inside the window replace one queued snapshot,
/// and one deferred flush posts the newest of them when the window ends.
///
/// Ownership and cancellation:
/// - The writer owns each deferred-flush post: it holds the flush's `Task`
///   until that Task ends and keeps no Task that has finished.
/// - `cancel(for:)` drops the book's queued snapshot, stops a scheduled flush
///   from posting, and cancels a deferred-flush post that is running. It
///   returns after that post's Task has ended. Other books are unaffected.
/// - A post started by `save(_:)` runs in the caller's task, and only the
///   caller can cancel it; the save then throws `PositionWriterError.cancelled`.
///   If that happens before the adapter is called, the save does not use up
///   the throttle window, so the next save posts at once.
/// - A cancelled post stops waiting for the adapter. If the adapter ignores
///   task cancellation (`EPUBPositionAdapter` does), its HTTP request can
///   still reach the server after `cancel(for:)` returns.
/// - A post that completes after cancel changes no writer state: no queued
///   snapshot comes back and no second post starts.
/// - When the background task expires, the running post is cancelled and the
///   background task is ended exactly once. A queued snapshot is kept for its
///   flush.
///
/// Not an `actor`: the writer owns `UIBackgroundTaskIdentifier` lifetime,
/// and `UIApplication.beginBackgroundTask`/`endBackgroundTask` are not
/// actor-isolated. The existing `TPPLastReadPositionPoster.serialQueue`
/// pattern is the template.
public final class RemotePositionWriter: PositionWriter, @unchecked Sendable {

    /// Runs `work` once `delay` seconds have passed.
    typealias FlushScheduler = @Sendable (_ delay: TimeInterval, _ work: @escaping @Sendable () -> Void) -> Void

    /// Production flush timer.
    static let afterDelay: FlushScheduler = { delay, work in
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - Dependencies

    private let network: PositionNetworkAdapter
    private let throttle: TimeInterval
    private let clock: @Sendable () -> Date
    private let scheduleFlush: FlushScheduler
    private let backgroundTasks: PositionBackgroundTasks

    // MARK: - State (guarded by `queue`)

    private let queue = DispatchQueue(
        label: "org.thepalaceproject.palacereadingposition.RemotePositionWriter",
        qos: .utility
    )

    /// Per-book bookkeeping. Keyed by bookID.
    private var state: [String: BookState] = [:]

    /// Deferred-flush posts that are running, keyed by a token. Each Task
    /// removes its own entry when it ends.
    private var ownedFlushes: [UInt64: OwnedFlush] = [:]

    /// Source of flush and task tokens.
    private var lastID: UInt64 = 0

    private struct BookState {
        /// Wall-clock time of the most recent in-flight or completed POST.
        /// New snapshots within `throttle` of this time are queued, not
        /// posted immediately.
        var lastPostAttempt: Date
        /// The snapshot waiting for the throttle window to elapse. Older
        /// queued snapshots are dropped when a newer one arrives.
        var queued: PositionSnapshot?
        /// The flush timer scheduled for this window. A timer whose ID no
        /// longer matches belongs to a window that `cancel(for:)` dropped.
        var scheduledFlush: UInt64?
    }

    private struct OwnedFlush {
        let bookID: String
        let task: Task<Void, Never>
    }

    // MARK: - Init

    public convenience init(
        network: PositionNetworkAdapter,
        throttle: TimeInterval = 15.0,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.init(
            network: network,
            throttle: throttle,
            clock: clock,
            scheduleFlush: RemotePositionWriter.afterDelay,
            backgroundTasks: .application
        )
    }

    /// Tests inject the flush timer and the background-task calls.
    init(
        network: PositionNetworkAdapter,
        throttle: TimeInterval,
        clock: @escaping @Sendable () -> Date,
        scheduleFlush: @escaping FlushScheduler,
        backgroundTasks: PositionBackgroundTasks
    ) {
        self.network = network
        self.throttle = throttle
        self.clock = clock
        self.scheduleFlush = scheduleFlush
        self.backgroundTasks = backgroundTasks
    }

    // MARK: - PositionWriter

    public func save(_ snapshot: PositionSnapshot) async throws -> ServerPositionID? {
        switch await onQueue({ self.decideOnQueue(for: snapshot) }) {
        case .postNow(let snapshot, let window):
            do {
                return try await performPost(snapshot)
            } catch is InFlightPost.NotStarted {
                // Nothing reached the adapter, so the next save may post at once.
                await onQueue { self.releaseWindow(window, for: snapshot.bookID) }
                throw PositionWriterError.cancelled
            }
        case .queueAndDefer:
            return nil
        }
    }

    public func load(for bookID: String) async throws -> PositionSnapshot? {
        try await network.fetch(bookID: bookID)
    }

    public func cancel(for bookID: String) async {
        let running = await onQueue { () -> [Task<Void, Never>] in
            self.state.removeValue(forKey: bookID)
            let tasks = self.ownedFlushes.values.filter { $0.bookID == bookID }.map(\.task)
            tasks.forEach { $0.cancel() }
            return tasks
        }
        for task in running {
            await task.value
        }
    }

    // PUBLIC_INTENT: witness for the public `PositionWriter.flush(for:)` requirement; the app calls it across the package boundary.
    public func flush(for bookID: String) async {
        let running = await onQueue { () -> [Task<Void, Never>] in
            if var bookState = self.state[bookID], let queued = bookState.queued {
                // Clearing `scheduledFlush` makes the window's timer a no-op,
                // and the new stamp makes later saves queue behind this post.
                bookState.queued = nil
                bookState.scheduledFlush = nil
                bookState.lastPostAttempt = self.clock()
                self.state[bookID] = bookState
                self.startOwnedFlush(of: queued)
            }
            return self.ownedFlushes.values.filter { $0.bookID == bookID }.map(\.task)
        }
        for task in running {
            await task.value
        }
    }

    // MARK: - Decision (serial-queue isolated)

    private enum SaveDecision: Sendable {
        case postNow(PositionSnapshot, Window)
        case queueAndDefer
    }

    /// The throttle stamp a post-now save took, and the stamp it replaced.
    private struct Window: Sendable {
        let opened: Date
        let previous: Date
    }

    /// Restores the previous stamp unless a later post has taken the window.
    /// Called from `queue`.
    private func releaseWindow(_ window: Window, for bookID: String) {
        guard var bookState = state[bookID], bookState.lastPostAttempt == window.opened else { return }
        bookState.lastPostAttempt = window.previous
        state[bookID] = bookState
    }

    /// Called from `queue`. Mutates `state`.
    private func decideOnQueue(for snapshot: PositionSnapshot) -> SaveDecision {
        let now = clock()
        var bookState = state[snapshot.bookID] ?? BookState(
            lastPostAttempt: .distantPast,
            queued: nil,
            scheduledFlush: nil
        )

        let elapsed = now.timeIntervalSince(bookState.lastPostAttempt)
        if elapsed >= throttle {
            // Window open — post now. Reserve the slot by stamping
            // `lastPostAttempt` so concurrent calls queue.
            let window = Window(opened: now, previous: bookState.lastPostAttempt)
            bookState.lastPostAttempt = now
            // Posting now supersedes any queued snapshot.
            bookState.queued = nil
            state[snapshot.bookID] = bookState
            return .postNow(snapshot, window)
        }

        // Inside window — queue the latest snapshot, scheduling a deferred
        // flush if one isn't already scheduled.
        bookState.queued = snapshot
        if bookState.scheduledFlush == nil {
            let flushID = makeID()
            bookState.scheduledFlush = flushID
            scheduleDeferredFlush(for: snapshot.bookID, flushID: flushID, after: max(throttle - elapsed, 0))
        }
        state[snapshot.bookID] = bookState
        return .queueAndDefer
    }

    /// Called from `queue`.
    private func makeID() -> UInt64 {
        lastID += 1
        return lastID
    }

    /// Schedules a deferred flush. Called from `queue`.
    private func scheduleDeferredFlush(for bookID: String, flushID: UInt64, after delay: TimeInterval) {
        scheduleFlush(delay) { [weak self] in
            guard let self else { return }
            self.queue.async { self.flushOnQueue(bookID: bookID, flushID: flushID) }
        }
    }

    /// Called from `queue` when a flush timer fires.
    private func flushOnQueue(bookID: String, flushID: UInt64) {
        guard var bookState = state[bookID], bookState.scheduledFlush == flushID else { return }
        bookState.scheduledFlush = nil
        guard let queued = bookState.queued else {
            state[bookID] = bookState
            return
        }
        // Stamp the slot before launching the POST so any concurrent
        // saves queue against the new window.
        bookState.lastPostAttempt = clock()
        bookState.queued = nil
        state[bookID] = bookState
        startOwnedFlush(of: queued)
    }

    /// Starts the flush post and records its Task. Called from `queue`.
    ///
    /// The Task removes its entry with a block on `queue`, and this block
    /// inserts the entry before it returns, so the removal always finds it.
    private func startOwnedFlush(of snapshot: PositionSnapshot) {
        let token = makeID()
        let bookID = snapshot.bookID
        let task = Task {
            do {
                _ = try await self.performPost(snapshot)
            } catch PositionWriterError.cancelled, is InFlightPost.NotStarted {
                Log.info("PalaceReadingPosition", "Deferred flush for \(bookID) was cancelled")
            } catch {
                Log.error("PalaceReadingPosition", "Deferred flush for \(bookID) failed: \(error)")
            }
            self.queue.async { self.ownedFlushes[token] = nil }
        }
        ownedFlushes[token] = OwnedFlush(bookID: bookID, task: task)
    }

    private func onQueue<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: body()) }
        }
    }

    // MARK: - Network

    private func performPost(_ snapshot: PositionSnapshot) async throws -> ServerPositionID {
        let post = InFlightPost(backgroundTasks: backgroundTasks)
        post.beginBackgroundTask()
        defer { post.endBackgroundTask() }
        let network = self.network
        return try await post.run { try await network.post(snapshot) }
    }

    // MARK: - Test seams

    /// Number of deferred-flush Tasks the writer holds.
    func ownedFlushTaskCount() async -> Int {
        await onQueue { self.ownedFlushes.count }
    }

    /// Returns after every block already submitted to the writer's queue has run.
    func waitForQueue() async {
        await onQueue {}
    }

    /// The deferred-flush Tasks the writer holds now.
    func ownedFlushTasks() async -> [Task<Void, Never>] {
        await onQueue { self.ownedFlushes.values.map(\.task) }
    }
}

/// One network post: the adapter call, the task waiting for it, and the
/// background task around it.
///
/// Cancelling the waiting task, or the background task expiring, ends the
/// wait with `PositionWriterError.cancelled` and cancels the adapter call
/// without waiting for it to return. Before the adapter is called, the wait
/// ends with `NotStarted` instead.
///
/// `@unchecked Sendable`: all mutable state is guarded by `lock`.
private final class InFlightPost: @unchecked Sendable {
    /// The post was cancelled before the adapter was called.
    struct NotStarted: Error, Equatable {}

    private let lock = NSLock()
    private let backgroundTasks: PositionBackgroundTasks
    private var waiter: CheckedContinuation<ServerPositionID, Error>?
    private var adapterCall: Task<Void, Never>?
    private var abandoned = false
    private var backgroundID: Int?
    private var endRequested = false
    private var backgroundEnded = false

    init(backgroundTasks: PositionBackgroundTasks) {
        self.backgroundTasks = backgroundTasks
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// UIKit may run the expiration handler before `begin` returns the
    /// identifier; the end it requested then happens here.
    func beginBackgroundTask() {
        let id = backgroundTasks.begin { self.expire() }
        let endNow = locked { () -> Bool in
            backgroundID = id
            guard endRequested, !backgroundEnded else { return false }
            backgroundEnded = true
            return true
        }
        if endNow {
            backgroundTasks.end(id)
        }
    }

    /// Ends the background task. Both the expiration handler and the post's
    /// exit call this; only the first call ends it.
    func endBackgroundTask() {
        let id = locked { () -> Int? in
            endRequested = true
            guard let id = backgroundID, !backgroundEnded else { return nil }
            backgroundEnded = true
            return id
        }
        if let id {
            backgroundTasks.end(id)
        }
    }

    func run(_ call: @escaping @Sendable () async throws -> ServerPositionID) async throws -> ServerPositionID {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let started = locked { () -> Bool in
                    guard !abandoned else { return false }
                    waiter = continuation
                    adapterCall = Task {
                        let result: Result<ServerPositionID, Error>
                        do {
                            result = .success(try await call())
                        } catch {
                            result = .failure(error)
                        }
                        self.deliver(result)
                    }
                    return true
                }
                if !started {
                    continuation.resume(throwing: NotStarted())
                }
            }
        } onCancel: {
            abandon()
        }
    }

    private func deliver(_ result: Result<ServerPositionID, Error>) {
        let waiter = locked { () -> CheckedContinuation<ServerPositionID, Error>? in
            defer { self.waiter = nil }
            return self.waiter
        }
        waiter?.resume(with: result)
    }

    private func abandon() {
        let (waiter, call) = locked { () -> (CheckedContinuation<ServerPositionID, Error>?, Task<Void, Never>?) in
            abandoned = true
            defer { self.waiter = nil }
            return (self.waiter, adapterCall)
        }
        call?.cancel()
        waiter?.resume(throwing: PositionWriterError.cancelled)
    }

    private func expire() {
        abandon()
        endBackgroundTask()
    }
}
