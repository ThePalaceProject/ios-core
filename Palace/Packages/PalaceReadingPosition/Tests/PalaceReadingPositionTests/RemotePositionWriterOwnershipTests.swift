//
//  RemotePositionWriterOwnershipTests.swift
//  PalaceReadingPositionTests
//
//  Ownership, cancellation and background-expiration behavior of the deferred
//  flush. The flush timer and the background task are injected, and the
//  adapter holds each post until the test releases it. Every wait is bounded,
//  so a regression fails a named test instead of hanging `swift test`.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import PalaceReadingPosition

final class RemotePositionWriterOwnershipTests: XCTestCase {

    private var clock: FrozenClock!
    private var scheduler: ManualFlushScheduler!
    private var adapter: GatedAdapter!
    private var background: FakeBackgroundTasks!
    private var writer: RemotePositionWriter!

    override func setUp() {
        super.setUp()
        clock = FrozenClock(start: Date(timeIntervalSince1970: 1_000))
        scheduler = ManualFlushScheduler()
        adapter = GatedAdapter()
        background = FakeBackgroundTasks()
        writer = makeWriter()
    }

    override func tearDown() {
        adapter.releaseAll()
        writer = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeWriter() -> RemotePositionWriter {
        RemotePositionWriter(
            network: adapter,
            throttle: 15,
            clock: clock.now,
            scheduleFlush: scheduler.schedule,
            backgroundTasks: background.hooks
        )
    }

    private func snapshot(_ bookID: String = "book-A", _ payload: String = "p") -> PositionSnapshot {
        PositionSnapshot(bookID: bookID, format: .epubLocator, payload: Data(payload.utf8),
                         timestamp: Date(), device: "device-1")
    }

    /// Starts a save in its own task, so the test can hold its post at the adapter.
    private func startSave(_ payload: String, book: String = "book-A") -> Task<ServerPositionID?, Error> {
        let writer = self.writer!
        let snapshot = self.snapshot(book, payload)
        return Task { try await writer.save(snapshot) }
    }

    private func save(_ payload: String, book: String = "book-A",
                      line: UInt = #line) async throws -> ServerPositionID? {
        let writer = self.writer!
        let snapshot = self.snapshot(book, payload)
        return try await bounded("save(\(payload))", line: line) { try await writer.save(snapshot) }
    }

    private func value<T: Sendable>(_ task: Task<T, Error>, line: UInt = #line) async throws -> T {
        try await bounded("the save task", line: line) { try await task.value }
    }

    private func waitPosts(_ count: Int, line: UInt = #line) async throws {
        let adapter = self.adapter!
        try await bounded("\(count) posts reaching the adapter", line: line) { await adapter.waitForPosts(count) }
    }

    private func waitReturns(line: UInt = #line) async throws {
        let adapter = self.adapter!
        try await bounded("adapter calls returning", line: line) { await adapter.waitForAllCallsToReturn() }
    }

    private func cancel(_ bookID: String, line: UInt = #line) async throws {
        let writer = self.writer!
        try await bounded("cancel(for: \(bookID))", line: line) { await writer.cancel(for: bookID) }
    }

    /// Waits for the flush Tasks the writer holds now, then for their
    /// self-removal, which they queue before they end.
    private func awaitHeldFlushes(line: UInt = #line) async throws {
        for task in await writer.ownedFlushTasks() {
            try await bounded("a flush Task ending", line: line) { await task.value }
        }
        await writer.waitForQueue()
    }

    /// Posts `first` through save(), then queues `queued` inside the window.
    private func postThenQueue(_ bookID: String = "book-A", queued: String = "queued") async throws {
        let first = startSave("first", book: bookID)
        try await waitPosts(adapter.postCount + 1)
        adapter.releaseNext("first-id")
        _ = try await value(first)
        clock.advance(by: 2)
        let id = try await save(queued, book: bookID)
        XCTAssertNil(id, "a save inside the window queues")
    }

    /// Fires the flush timers, then waits until the writer has acted on them.
    private func fireFlushes() async {
        scheduler.fireAll()
        await writer.waitForQueue()
    }

    // MARK: - Coalescing

    /// One post per window per book; the newest queued snapshot is the one sent.
    func testDeferredFlush_ThreeSavesInWindow_PostsOnlyTheNewest() async throws {
        try await postThenQueue(queued: "p2")
        _ = try await save("p3")
        XCTAssertEqual(scheduler.pendingCount, 1, "one flush is scheduled per window")
        XCTAssertEqual(scheduler.delays, [13], "the flush fires when the window ends")

        await fireFlushes()
        try await waitPosts(2)
        adapter.releaseNext()
        try await awaitHeldFlushes()

        XCTAssertEqual(adapter.postedPayloads, ["first", "p3"])
    }

    /// A save after the window ends posts at once and drops the older queued snapshot.
    func testSave_OutsideWindowWithQueuedSnapshot_PostsNowAndFlushSendsNothing() async throws {
        try await postThenQueue(queued: "stale")
        clock.advance(by: 20)

        let now = startSave("fresh")
        try await waitPosts(2)
        adapter.releaseNext("fresh-id")
        let id = try await value(now)
        await fireFlushes()
        try await awaitHeldFlushes()

        XCTAssertEqual(id, "fresh-id")
        XCTAssertEqual(adapter.postedPayloads, ["first", "fresh"])
    }

    /// A save after the window ends posts at once even while a flush still posts.
    func testSave_OutsideWindowWhileFlushPosts_PostsNow() async throws {
        try await postThenQueue(queued: "flushing")
        await fireFlushes()
        try await waitPosts(2)
        clock.advance(by: 20)

        let now = startSave("fresh")
        try await waitPosts(3)
        adapter.releaseAll()
        _ = try await value(now)
        try await awaitHeldFlushes()

        XCTAssertEqual(adapter.postedPayloads, ["first", "flushing", "fresh"])
        XCTAssertEqual(scheduler.pendingCount, 0)
    }

    /// The flush opens a new window when it posts, not when the first save did.
    func testDeferredFlush_OpensNewWindow_SaveSoonAfterFlushQueues() async throws {
        try await postThenQueue()
        clock.advance(by: 11)
        await fireFlushes()
        try await waitPosts(2)
        adapter.releaseNext()
        try await awaitHeldFlushes()

        clock.advance(by: 3)
        let id = try await save("soon-after-flush")

        XCTAssertNil(id, "16 s after the first post but 3 s after the flush")
        XCTAssertEqual(adapter.postCount, 2)
        XCTAssertEqual(scheduler.delays, [12])
    }

    /// A failed flush still used its window: the next save inside it queues.
    func testDeferredFlush_PostFails_SaveInWindowStillQueues() async throws {
        try await postThenQueue()
        await fireFlushes()
        try await waitPosts(2)
        adapter.failNext(PositionWriterError.networkUnavailable)
        try await awaitHeldFlushes()

        clock.advance(by: 1)
        let id = try await save("after-failure")

        XCTAssertNil(id)
        XCTAssertEqual(adapter.postCount, 2)
        XCTAssertEqual(scheduler.pendingCount, 1)
    }

    // MARK: - Ownership

    /// The writer holds the flush Task while it posts and drops it once it ends.
    func testDeferredFlush_AfterPostCompletes_RetainsNoTask() async throws {
        try await postThenQueue()
        await fireFlushes()
        try await waitPosts(2)
        let whilePosting = await writer.ownedFlushTaskCount()

        adapter.releaseNext()
        try await awaitHeldFlushes()
        let afterPost = await writer.ownedFlushTaskCount()

        XCTAssertEqual(whilePosting, 1)
        XCTAssertEqual(afterPost, 0)
    }

    /// A failed flush post also releases its Task.
    func testDeferredFlush_AfterPostFails_RetainsNoTask() async throws {
        try await postThenQueue()
        await fireFlushes()
        try await waitPosts(2)
        let whilePosting = await writer.ownedFlushTaskCount()

        adapter.failNext(PositionWriterError.networkUnavailable)
        try await awaitHeldFlushes()
        let afterPost = await writer.ownedFlushTaskCount()

        XCTAssertEqual(whilePosting, 1)
        XCTAssertEqual(afterPost, 0)
    }

    /// A timer that fires after the writer is gone posts nothing.
    func testDeferredFlush_WriterReleasedWithTimerScheduled_PostsNothing() async throws {
        try await postThenQueue()
        weak var released = writer
        writer = nil
        // Finished save tasks and queue blocks drop their references a moment
        // after they resume the test, so wait for the release, up to 2 s.
        for _ in 0..<2_000 where released != nil {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertNil(released, "nothing else holds the writer")

        scheduler.fireAll()

        XCTAssertEqual(adapter.postCount, 1)
    }

    // MARK: - cancel(for:)

    /// Cancel before the window ends: the scheduled flush finds nothing to post.
    func testCancel_BeforeFlushStarts_NothingPosts() async throws {
        try await postThenQueue()

        try await cancel("book-A")
        await fireFlushes()
        try await awaitHeldFlushes()

        XCTAssertEqual(adapter.postedPayloads, ["first"])
    }

    /// A flush scheduled before cancel must not post a snapshot queued after it.
    func testCancel_ThenNewWindow_OldFlushTimerDoesNotPostEarly() async throws {
        try await postThenQueue(queued: "old")
        try await cancel("book-A")
        let staleFlush = scheduler.takeAll()
        XCTAssertEqual(staleFlush.count, 1)

        let fresh = startSave("after-cancel")
        try await waitPosts(2)
        adapter.releaseNext()
        _ = try await value(fresh)
        clock.advance(by: 1)
        _ = try await save("new-queued")

        staleFlush.forEach { $0() }
        await writer.waitForQueue()
        try await awaitHeldFlushes()
        XCTAssertEqual(adapter.postedPayloads, ["first", "after-cancel"],
                       "the timer from before cancel belongs to a dropped window")

        await fireFlushes()
        try await waitPosts(3)
        adapter.releaseNext()
        try await awaitHeldFlushes()
        XCTAssertEqual(adapter.postedPayloads, ["first", "after-cancel", "new-queued"])
    }

    /// Cancel while the flush posts: its Task is cancelled and cancel returns once
    /// it has ended, even though this adapter ignores cancellation.
    func testCancel_DuringFlushPost_CancelsTaskAndReturnsAfterItEnds() async throws {
        try await postThenQueue()
        await fireFlushes()
        try await waitPosts(2)

        try await cancel("book-A")
        // The flush Task queues its own removal before it ends, and cancel
        // returns only after it ends, so this queue read follows the removal.
        let afterCancel = await writer.ownedFlushTaskCount()

        XCTAssertEqual(afterCancel, 0, "cancel returned with the flush Task still alive")
        XCTAssertEqual(adapter.cancelledCallCount, 1)
        XCTAssertEqual(adapter.pendingCount, 1, "the adapter call is still outstanding")
        XCTAssertEqual(background.endedIDs, background.begunIDs, "the flush post released its background task")
    }

    /// A post that completes after cancel brings back no state: no queued
    /// snapshot, no second post, and the next save posts at once.
    func testCancel_FlushPostCompletesLate_NoStateReturns() async throws {
        try await postThenQueue()
        await fireFlushes()
        try await waitPosts(2)
        try await cancel("book-A")

        adapter.releaseNext("late-id")
        try await waitReturns()
        await fireFlushes()
        try await awaitHeldFlushes()
        XCTAssertEqual(adapter.postCount, 2)
        XCTAssertEqual(scheduler.pendingCount, 0)

        let next = startSave("next")
        try await waitPosts(3)
        adapter.releaseNext("next-id")
        let id = try await value(next)
        XCTAssertEqual(id, "next-id", "no throttle stamp came back with the late completion")
    }

    /// Cancelling book B leaves book A's running flush alone.
    func testCancel_OtherBook_LeavesRunningFlushAlone() async throws {
        try await postThenQueue("book-A")
        await fireFlushes()
        try await waitPosts(2)

        try await cancel("book-B")
        let count = await writer.ownedFlushTaskCount()
        adapter.releaseNext()
        try await awaitHeldFlushes()

        XCTAssertEqual(count, 1)
        XCTAssertEqual(adapter.cancelledCallCount, 0)
    }

    /// Cancelling book B leaves book A's scheduled flush alone.
    func testCancel_OtherBook_LeavesScheduledFlushAlone() async throws {
        try await postThenQueue("book-A", queued: "a-queued")

        try await cancel("book-B")
        await fireFlushes()
        try await waitPosts(2)
        adapter.releaseNext()
        try await awaitHeldFlushes()

        XCTAssertEqual(adapter.postedPayloads, ["first", "a-queued"])
    }

    /// Posts started by save() run in the caller's task; cancel(for:) does not stop them.
    func testCancel_DuringSavePost_LeavesCallerPostRunning() async throws {
        let save = startSave("caller")
        try await waitPosts(1)

        try await cancel("book-A")
        adapter.releaseNext("caller-id")
        let id = try await value(save)

        XCTAssertEqual(id, "caller-id")
    }

    /// A caller that cancels its own task ends the wait with `.cancelled`.
    func testSave_CallerCancels_ThrowsCancelledAndReleasesBackgroundTask() async throws {
        let save = startSave("caller")
        try await waitPosts(1)

        save.cancel()

        do {
            _ = try await value(save)
            XCTFail("expected cancelled")
        } catch {
            XCTAssertEqual(error as? PositionWriterError, .cancelled)
        }
        XCTAssertEqual(adapter.cancelledCallCount, 1, "the adapter call was cancelled")
        XCTAssertEqual(background.endCount, 1)
    }

    /// A save in a task that is already cancelled posts nothing and leaves the
    /// window open, so the next save posts at once.
    func testSave_InCancelledTask_PostsNothingAndKeepsWindowOpen() async throws {
        let writer = self.writer!
        let snapshot = self.snapshot("book-A", "cancelled")
        let cancelled = Task { () -> ServerPositionID? in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await writer.save(snapshot)
        }
        do {
            _ = try await value(cancelled)
            XCTFail("expected cancelled")
        } catch {
            XCTAssertEqual(error as? PositionWriterError, .cancelled)
        }

        let next = startSave("next")
        try await waitPosts(1)
        adapter.releaseNext("next-id")
        let id = try await value(next)

        XCTAssertEqual(id, "next-id")
        XCTAssertEqual(adapter.postedPayloads, ["next"])
    }

    // MARK: - Background task

    /// Every post begins one background task and ends it once.
    func testPost_Completes_EndsBackgroundTaskOnce() async throws {
        let save = startSave("p")
        try await waitPosts(1)
        XCTAssertEqual(background.begunIDs.count, 1)
        XCTAssertEqual(background.endCount, 0, "held for the length of the post")

        adapter.releaseNext()
        _ = try await value(save)

        XCTAssertEqual(background.endedIDs, background.begunIDs)
    }

    /// Expiration during a flush post cancels it and ends the background task
    /// exactly once, including when the post later completes.
    func testExpiration_DuringFlushPost_CancelsPostAndEndsOnce() async throws {
        try await postThenQueue()
        await fireFlushes()
        try await waitPosts(2)
        let flushTaskID = try XCTUnwrap(background.begunIDs.last)

        background.expire(flushTaskID)
        try await awaitHeldFlushes()
        XCTAssertEqual(adapter.cancelledCallCount, 1)
        XCTAssertEqual(background.endedIDs.filter { $0 == flushTaskID }.count, 1)

        adapter.releaseNext()
        try await waitReturns()
        XCTAssertEqual(background.endedIDs.filter { $0 == flushTaskID }.count, 1,
                       "the post's own exit must not end the task a second time")
    }

    /// Expiration during a save() post ends that caller's wait with `.cancelled`.
    func testExpiration_DuringSavePost_ThrowsCancelledAndEndsOnce() async throws {
        let save = startSave("p")
        try await waitPosts(1)
        let id = try XCTUnwrap(background.begunIDs.first)

        background.expire(id)

        do {
            _ = try await value(save)
            XCTFail("expected cancelled")
        } catch {
            XCTAssertEqual(error as? PositionWriterError, .cancelled)
        }
        XCTAssertEqual(background.endedIDs, [id])
    }

    /// Expiration keeps a snapshot queued for the next window.
    func testExpiration_DuringFlushPost_KeepsLaterQueuedSnapshot() async throws {
        try await postThenQueue(queued: "q1")
        await fireFlushes()
        try await waitPosts(2)
        clock.advance(by: 1)
        _ = try await save("q2")

        background.expire(try XCTUnwrap(background.begunIDs.last))
        XCTAssertEqual(adapter.cancelledCallCount, 1, "expiration cancelled the q1 post")
        try await awaitHeldFlushes()
        await fireFlushes()
        try await waitPosts(3)
        adapter.releaseAll()
        try await awaitHeldFlushes()

        XCTAssertEqual(adapter.postedPayloads, ["first", "q1", "q2"])
    }

    /// The system can call the expiration handler before `begin` hands back the
    /// identifier; the task is then ended as soon as the identifier is known.
    func testExpiration_BeforeBeginReturns_EndsTaskOnceAndCancelsPost() async throws {
        background.expireDuringBegin = true

        do {
            _ = try await save("p")
            XCTFail("expected cancelled")
        } catch {
            XCTAssertEqual(error as? PositionWriterError, .cancelled)
        }

        XCTAssertEqual(background.endedIDs, background.begunIDs)
        XCTAssertEqual(background.begunIDs.count, 1)
        XCTAssertEqual(adapter.postCount, 0, "an expired post never reaches the adapter")
    }

    /// A save whose post expired before reaching the adapter leaves the window
    /// open, so the next save posts at once.
    func testExpiration_BeforeAdapterCall_NextSavePostsAtOnce() async throws {
        background.expireDuringBegin = true
        _ = try? await save("expired")
        background.expireDuringBegin = false

        let next = startSave("next")
        try await waitPosts(1)
        adapter.releaseNext("next-id")
        let id = try await value(next)

        XCTAssertEqual(id, "next-id")
    }
}

// MARK: - Bounded waits

struct BoundedWaitTimedOut: Error {
    let label: String
}

/// Resumes a continuation with whichever result arrives first.
private final class FirstResult<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var timer: Task<Void, Never>?

    func install(_ continuation: CheckedContinuation<T, Error>) {
        lock.lock(); defer { lock.unlock() }
        self.continuation = continuation
    }

    func setTimer(_ timer: Task<Void, Never>) {
        lock.lock(); defer { lock.unlock() }
        self.timer = timer
    }

    /// Returns whether this call delivered the result.
    @discardableResult
    func deliver(_ result: Result<T, Error>) -> Bool {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let timer = self.timer
        lock.unlock()
        guard let continuation else { return false }
        timer?.cancel()
        continuation.resume(with: result)
        return true
    }
}

extension XCTestCase {
    /// Runs `operation`, failing the test and throwing if it has not finished
    /// within `seconds`. The operation is not awaited after the deadline, so
    /// an operation that ignores cancellation cannot hang the run.
    func bounded<T>(_ label: String, seconds: UInt64 = 10, file: StaticString = #filePath, line: UInt = #line,
                    _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let first = FirstResult<T>()
        do {
            return try await withCheckedThrowingContinuation { continuation in
                first.install(continuation)
                let work = Task {
                    do {
                        first.deliver(.success(try await operation()))
                    } catch {
                        first.deliver(.failure(error))
                    }
                }
                first.setTimer(Task {
                    try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                    if Task.isCancelled { return }
                    if first.deliver(.failure(BoundedWaitTimedOut(label: label))) {
                        work.cancel()
                    }
                })
            }
        } catch let timedOut as BoundedWaitTimedOut {
            XCTFail("\(timedOut.label) did not finish within \(seconds) s", file: file, line: line)
            throw timedOut
        }
    }
}

// MARK: - Test doubles

/// Records flush timers; the test fires them.
final class ManualFlushScheduler: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(delay: TimeInterval, work: @Sendable () -> Void)] = []

    var schedule: RemotePositionWriter.FlushScheduler {
        { [self] delay, work in
            lock.lock(); defer { lock.unlock() }
            items.append((delay, work))
        }
    }

    var pendingCount: Int { lock.lock(); defer { lock.unlock() }; return items.count }
    var delays: [TimeInterval] { lock.lock(); defer { lock.unlock() }; return items.map(\.delay) }

    func takeAll() -> [@Sendable () -> Void] {
        lock.lock(); defer { lock.unlock() }
        let work = items.map(\.work)
        items = []
        return work
    }

    func fireAll() { takeAll().forEach { $0() } }
}

/// Background-task hooks the test can expire.
final class FakeBackgroundTasks: @unchecked Sendable {
    private let lock = NSLock()
    private var nextID = 1
    private var handlers: [Int: @Sendable () -> Void] = [:]
    private var _begun: [Int] = []
    private var _ended: [Int] = []
    private var _expireDuringBegin = false

    var expireDuringBegin: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _expireDuringBegin }
        set { lock.lock(); defer { lock.unlock() }; _expireDuringBegin = newValue }
    }

    var begunIDs: [Int] { lock.lock(); defer { lock.unlock() }; return _begun }
    var endedIDs: [Int] { lock.lock(); defer { lock.unlock() }; return _ended }
    var endCount: Int { endedIDs.count }

    var hooks: PositionBackgroundTasks {
        PositionBackgroundTasks(
            begin: { [self] onExpiration in
                let (id, expireNow): (Int, Bool) = {
                    lock.lock(); defer { lock.unlock() }
                    let id = nextID
                    nextID += 1
                    _begun.append(id)
                    handlers[id] = onExpiration
                    return (id, _expireDuringBegin)
                }()
                if expireNow { onExpiration() }
                return id
            },
            end: { [self] id in
                lock.lock(); defer { lock.unlock() }
                _ended.append(id)
            }
        )
    }

    func expire(_ id: Int) {
        let handler: (@Sendable () -> Void)? = {
            lock.lock(); defer { lock.unlock() }
            return handlers[id]
        }()
        handler?()
    }
}

/// Adapter whose post suspends until the test releases it. It records task
/// cancellation but keeps waiting, as `EPUBPositionAdapter` does.
final class GatedAdapter: PositionNetworkAdapter, @unchecked Sendable {
    private let lock = NSLock()
    private var posted: [PositionSnapshot] = []
    private var pending: [CheckedContinuation<ServerPositionID, Error>] = []
    private var postWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var returnWaiters: [CheckedContinuation<Void, Never>] = []
    private var _returned = 0
    private var _cancelled = 0

    var postCount: Int { lock.lock(); defer { lock.unlock() }; return posted.count }
    var postedPayloads: [String] {
        lock.lock(); defer { lock.unlock() }
        return posted.map { String(decoding: $0.payload, as: UTF8.self) }
    }
    var pendingCount: Int { lock.lock(); defer { lock.unlock() }; return pending.count }
    var cancelledCallCount: Int { lock.lock(); defer { lock.unlock() }; return _cancelled }

    func post(_ snapshot: PositionSnapshot) async throws -> ServerPositionID {
        defer { noteReturned() }
        return try await withTaskCancellationHandler {
            try await suspend(snapshot)
        } onCancel: {
            lock.lock(); defer { lock.unlock() }
            _cancelled += 1
        }
    }

    private func suspend(_ snapshot: PositionSnapshot) async throws -> ServerPositionID {
        try await withCheckedThrowingContinuation { continuation in
            let ready: [CheckedContinuation<Void, Never>] = {
                lock.lock(); defer { lock.unlock() }
                posted.append(snapshot)
                pending.append(continuation)
                let count = posted.count
                let ready = postWaiters.filter { $0.count <= count }.map(\.continuation)
                postWaiters.removeAll { $0.count <= count }
                return ready
            }()
            ready.forEach { $0.resume() }
        }
    }

    func fetch(bookID: String) async throws -> PositionSnapshot? { nil }

    /// Returns once `count` posts have reached the adapter.
    func waitForPosts(_ count: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let reached: Bool = {
                lock.lock(); defer { lock.unlock() }
                if posted.count >= count { return true }
                postWaiters.append((count, continuation))
                return false
            }()
            if reached { continuation.resume() }
        }
    }

    /// Returns once every post that reached the adapter has returned.
    func waitForAllCallsToReturn() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let done: Bool = {
                lock.lock(); defer { lock.unlock() }
                if _returned == posted.count { return true }
                returnWaiters.append(continuation)
                return false
            }()
            if done { continuation.resume() }
        }
    }

    func releaseNext(_ id: ServerPositionID = "ok") { takeNext()?.resume(returning: id) }

    func failNext(_ error: Error) { takeNext()?.resume(throwing: error) }

    func releaseAll() {
        while let next = takeNext() { next.resume(returning: "ok") }
    }

    private func takeNext() -> CheckedContinuation<ServerPositionID, Error>? {
        lock.lock(); defer { lock.unlock() }
        return pending.isEmpty ? nil : pending.removeFirst()
    }

    private func noteReturned() {
        let waiters: [CheckedContinuation<Void, Never>] = {
            lock.lock(); defer { lock.unlock() }
            _returned += 1
            guard _returned == posted.count else { return [] }
            let waiters = returnWaiters
            returnWaiters = []
            return waiters
        }()
        waiters.forEach { $0.resume() }
    }
}
