//
//  RemotePositionWriterOwnershipTests.swift
//  PalaceReadingPositionTests
//
//  Ownership, cancellation and background-expiration behavior of the deferred
//  flush. The flush timer and the background task are injected, and the
//  adapter holds each post until the test releases it.
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
        writer = RemotePositionWriter(
            network: adapter,
            throttle: 15,
            clock: clock.now,
            scheduleFlush: scheduler.schedule,
            backgroundTasks: background.hooks
        )
    }

    override func tearDown() {
        adapter.releaseAll()
        writer = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func snapshot(_ bookID: String = "book-A", _ payload: String = "p") -> PositionSnapshot {
        PositionSnapshot(bookID: bookID, format: .epubLocator, payload: Data(payload.utf8),
                         timestamp: Date(), device: "device-1")
    }

    /// Posts `first` through save(), then queues `queued` inside the window.
    private func postThenQueue(_ bookID: String = "book-A", queued: String = "queued") async throws {
        let first = Task { [writer, bookID] in try await writer!.save(self.snapshot(bookID, "first")) }
        await adapter.waitForPosts(adapter.postCount + 1)
        adapter.releaseNext("first-id")
        _ = try await first.value
        clock.advance(by: 2)
        let id = try await writer.save(snapshot(bookID, queued))
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
        _ = try await writer.save(snapshot("book-A", "p3"))
        XCTAssertEqual(scheduler.pendingCount, 1, "one flush is scheduled per window")
        XCTAssertEqual(scheduler.delays, [13], "the flush fires when the window ends")

        await fireFlushes()
        await adapter.waitForPosts(2)
        adapter.releaseNext()
        await writer.waitForOwnedFlushes()

        XCTAssertEqual(adapter.postedPayloads, ["first", "p3"])
    }

    /// A save after the window ends posts at once and drops the older queued snapshot.
    func testSave_OutsideWindowWithQueuedSnapshot_PostsNowAndFlushSendsNothing() async throws {
        try await postThenQueue(queued: "stale")
        clock.advance(by: 20)

        let now = Task { [writer] in try await writer!.save(self.snapshot("book-A", "fresh")) }
        await adapter.waitForPosts(2)
        adapter.releaseNext("fresh-id")
        let id = try await now.value
        await fireFlushes()
        await writer.waitForOwnedFlushes()

        XCTAssertEqual(id, "fresh-id")
        XCTAssertEqual(adapter.postedPayloads, ["first", "fresh"])
    }

    /// A save after the window ends posts at once even while a flush still posts.
    func testSave_OutsideWindowWhileFlushPosts_PostsNow() async throws {
        try await postThenQueue(queued: "flushing")
        await fireFlushes()
        await adapter.waitForPosts(2)
        clock.advance(by: 20)

        let now = Task { [writer] in try await writer!.save(self.snapshot("book-A", "fresh")) }
        await adapter.waitForPosts(3)
        adapter.releaseAll()
        _ = try await now.value
        await writer.waitForOwnedFlushes()

        XCTAssertEqual(adapter.postedPayloads, ["first", "flushing", "fresh"])
        XCTAssertEqual(scheduler.pendingCount, 0)
    }

    // MARK: - Ownership

    /// The writer holds the flush Task while it posts and drops it once it ends.
    func testDeferredFlush_AfterPostCompletes_RetainsNoTask() async throws {
        try await postThenQueue()
        await fireFlushes()
        await adapter.waitForPosts(2)
        let whilePosting = await writer.ownedFlushTaskCount()

        adapter.releaseNext()
        await writer.waitForOwnedFlushes()
        let afterPost = await writer.ownedFlushTaskCount()

        XCTAssertEqual(whilePosting, 1)
        XCTAssertEqual(afterPost, 0)
    }

    /// A failed flush post also releases its Task.
    func testDeferredFlush_AfterPostFails_RetainsNoTask() async throws {
        try await postThenQueue()
        await fireFlushes()
        await adapter.waitForPosts(2)

        adapter.failNext(PositionWriterError.networkUnavailable)
        await writer.waitForOwnedFlushes()
        let count = await writer.ownedFlushTaskCount()

        XCTAssertEqual(count, 0)
    }

    // MARK: - cancel(for:)

    /// Cancel before the window ends: the scheduled flush finds nothing to post.
    func testCancel_BeforeFlushStarts_NothingPosts() async throws {
        try await postThenQueue()

        await writer.cancel(for: "book-A")
        await fireFlushes()
        await writer.waitForOwnedFlushes()

        XCTAssertEqual(adapter.postedPayloads, ["first"])
    }

    /// A flush scheduled before cancel must not post a snapshot queued after it.
    func testCancel_ThenNewWindow_OldFlushTimerDoesNotPostEarly() async throws {
        try await postThenQueue(queued: "old")
        await writer.cancel(for: "book-A")
        let staleFlush = scheduler.takeAll()

        let fresh = Task { [writer] in try await writer!.save(self.snapshot("book-A", "after-cancel")) }
        await adapter.waitForPosts(2)
        adapter.releaseNext()
        _ = try await fresh.value
        clock.advance(by: 1)
        _ = try await writer.save(snapshot("book-A", "new-queued"))

        staleFlush.forEach { $0() }
        await writer.waitForQueue()
        await writer.waitForOwnedFlushes()
        XCTAssertEqual(adapter.postedPayloads, ["first", "after-cancel"],
                       "the timer from before cancel belongs to a dropped window")

        await fireFlushes()
        await adapter.waitForPosts(3)
        adapter.releaseNext()
        await writer.waitForOwnedFlushes()
        XCTAssertEqual(adapter.postedPayloads, ["first", "after-cancel", "new-queued"])
    }

    /// Cancel while the flush posts: its Task is cancelled and cancel returns once
    /// it has ended, even though this adapter ignores cancellation.
    func testCancel_DuringFlushPost_CancelsTaskAndReturnsAfterItEnds() async throws {
        try await postThenQueue()
        await fireFlushes()
        await adapter.waitForPosts(2)

        await writer.cancel(for: "book-A")
        let afterCancel = await writer.ownedFlushTaskCount()

        XCTAssertEqual(afterCancel, 0, "cancel returned with the flush Task still alive")
        XCTAssertEqual(adapter.pendingCount, 1, "the adapter call is still outstanding")
        XCTAssertEqual(background.endedIDs, background.begunIDs, "the flush post released its background task")
    }

    /// A post that completes after cancel brings back no state: no queued
    /// snapshot, no second post, and the next save posts at once.
    func testCancel_FlushPostCompletesLate_NoStateReturns() async throws {
        try await postThenQueue()
        await fireFlushes()
        await adapter.waitForPosts(2)
        await writer.cancel(for: "book-A")

        adapter.releaseNext("late-id")
        await adapter.waitForAllCallsToReturn()
        await fireFlushes()
        await writer.waitForOwnedFlushes()
        XCTAssertEqual(adapter.postCount, 2)
        XCTAssertEqual(scheduler.pendingCount, 0)

        let next = Task { [writer] in try await writer!.save(self.snapshot("book-A", "next")) }
        await adapter.waitForPosts(3)
        adapter.releaseNext("next-id")
        let id = try await next.value
        XCTAssertEqual(id, "next-id", "no throttle stamp came back with the late completion")
    }

    /// Cancelling book B leaves book A's running flush alone.
    func testCancel_OtherBook_LeavesRunningFlushAlone() async throws {
        try await postThenQueue("book-A")
        await fireFlushes()
        await adapter.waitForPosts(2)

        await writer.cancel(for: "book-B")
        let count = await writer.ownedFlushTaskCount()
        adapter.releaseNext()
        await writer.waitForOwnedFlushes()

        XCTAssertEqual(count, 1)
        XCTAssertEqual(adapter.cancelledCallCount, 0)
    }

    /// Cancelling book B leaves book A's scheduled flush alone.
    func testCancel_OtherBook_LeavesScheduledFlushAlone() async throws {
        try await postThenQueue("book-A", queued: "a-queued")

        await writer.cancel(for: "book-B")
        await fireFlushes()
        await adapter.waitForPosts(2)
        adapter.releaseNext()
        await writer.waitForOwnedFlushes()

        XCTAssertEqual(adapter.postedPayloads, ["first", "a-queued"])
    }

    /// Posts started by save() run in the caller's task; cancel(for:) does not stop them.
    func testCancel_DuringSavePost_LeavesCallerPostRunning() async throws {
        let save = Task { [writer] in try await writer!.save(self.snapshot("book-A", "caller")) }
        await adapter.waitForPosts(1)

        await writer.cancel(for: "book-A")
        adapter.releaseNext("caller-id")
        let id = try await save.value

        XCTAssertEqual(id, "caller-id")
    }

    /// A caller that cancels its own task ends the wait with `.cancelled`.
    func testSave_CallerCancels_ThrowsCancelledAndReleasesBackgroundTask() async throws {
        let save = Task { [writer] in try await writer!.save(self.snapshot("book-A", "caller")) }
        await adapter.waitForPosts(1)

        save.cancel()

        do {
            _ = try await save.value
            XCTFail("expected cancelled")
        } catch {
            XCTAssertEqual(error as? PositionWriterError, .cancelled)
        }
        XCTAssertEqual(adapter.cancelledCallCount, 1, "the adapter call was cancelled")
        XCTAssertEqual(background.endCount, 1)
    }

    // MARK: - Background task

    /// Every post begins one background task and ends it once.
    func testPost_Completes_EndsBackgroundTaskOnce() async throws {
        let save = Task { [writer] in try await writer!.save(self.snapshot()) }
        await adapter.waitForPosts(1)
        XCTAssertEqual(background.begunIDs.count, 1)
        XCTAssertEqual(background.endCount, 0, "held for the length of the post")

        adapter.releaseNext()
        _ = try await save.value

        XCTAssertEqual(background.endedIDs, background.begunIDs)
    }

    /// Expiration during a flush post cancels it and ends the background task
    /// exactly once, including when the post later completes.
    func testExpiration_DuringFlushPost_CancelsPostAndEndsOnce() async throws {
        try await postThenQueue()
        await fireFlushes()
        await adapter.waitForPosts(2)
        let flushTaskID = try XCTUnwrap(background.begunIDs.last)

        background.expire(flushTaskID)
        await writer.waitForOwnedFlushes()
        XCTAssertEqual(adapter.cancelledCallCount, 1)
        XCTAssertEqual(background.endedIDs.filter { $0 == flushTaskID }.count, 1)

        adapter.releaseNext()
        await adapter.waitForAllCallsToReturn()
        XCTAssertEqual(background.endedIDs.filter { $0 == flushTaskID }.count, 1,
                       "the post's own exit must not end the task a second time")
    }

    /// Expiration during a save() post ends that caller's wait with `.cancelled`.
    func testExpiration_DuringSavePost_ThrowsCancelledAndEndsOnce() async throws {
        let save = Task { [writer] in try await writer!.save(self.snapshot()) }
        await adapter.waitForPosts(1)
        let id = try XCTUnwrap(background.begunIDs.first)

        background.expire(id)

        do {
            _ = try await save.value
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
        await adapter.waitForPosts(2)
        clock.advance(by: 1)
        _ = try await writer.save(snapshot("book-A", "q2"))

        background.expire(try XCTUnwrap(background.begunIDs.last))
        await writer.waitForOwnedFlushes()
        await fireFlushes()
        await adapter.waitForPosts(3)
        adapter.releaseAll()
        await writer.waitForOwnedFlushes()

        XCTAssertEqual(adapter.postedPayloads, ["first", "q1", "q2"])
    }

    /// The system can call the expiration handler before `begin` hands back the
    /// identifier; the task is then ended as soon as the identifier is known.
    func testExpiration_BeforeBeginReturns_EndsTaskOnceAndCancelsPost() async throws {
        background.expireDuringBegin = true

        do {
            _ = try await writer.save(snapshot())
            XCTFail("expected cancelled")
        } catch {
            XCTAssertEqual(error as? PositionWriterError, .cancelled)
        }

        XCTAssertEqual(background.endedIDs, background.begunIDs)
        XCTAssertEqual(background.begunIDs.count, 1)
        XCTAssertEqual(adapter.postCount, 0, "an expired post never reaches the adapter")
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
    var expireDuringBegin = false

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
                    return (id, expireDuringBegin)
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
