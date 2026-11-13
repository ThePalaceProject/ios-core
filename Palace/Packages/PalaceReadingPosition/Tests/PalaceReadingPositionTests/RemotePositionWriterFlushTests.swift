//
//  RemotePositionWriterFlushTests.swift
//  PalaceReadingPositionTests
//
//  `flush(for:)`: the reader-close path that posts the queued snapshot at once
//  instead of when the throttle window ends (PP-5595). Uses the doubles from
//  RemotePositionWriterOwnershipTests; every wait is bounded.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import PalaceReadingPosition

final class RemotePositionWriterFlushTests: XCTestCase {

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

    private func snapshot(_ bookID: String, _ payload: String) -> PositionSnapshot {
        PositionSnapshot(bookID: bookID, format: .epubLocator, payload: Data(payload.utf8),
                         timestamp: Date(), device: "device-1")
    }

    private func waitPosts(_ count: Int, line: UInt = #line) async throws {
        let adapter = self.adapter!
        try await bounded("\(count) posts reaching the adapter", line: line) { await adapter.waitForPosts(count) }
    }

    /// Posts `first` (released at once), then queues `queued` inside the window.
    private func postThenQueue(_ bookID: String = "book-A", queued: String = "queued") async throws {
        let writer = self.writer!
        let first = snapshot(bookID, "first")
        let firstSave = Task { try await writer.save(first) }
        try await waitPosts(adapter.postCount + 1)
        adapter.releaseNext("first-id")
        _ = try await bounded("the first save") { try await firstSave.value }
        clock.advance(by: 2)
        let queuedSnapshot = snapshot(bookID, queued)
        let id = try await bounded("the queued save") { try await writer.save(queuedSnapshot) }
        XCTAssertNil(id, "a save inside the window queues")
    }

    /// Starts `flush(for:)` in its own task and records when it returns.
    private func startFlush(_ bookID: String = "book-A") -> (task: Task<Void, Never>, returned: FlushReturned) {
        let writer = self.writer!
        let returned = FlushReturned()
        let task = Task {
            await writer.flush(for: bookID)
            returned.mark()
        }
        return (task, returned)
    }

    private func finish(_ task: Task<Void, Never>, line: UInt = #line) async throws {
        try await bounded("flush(for:) returning", line: line) { await task.value }
    }

    // MARK: - Tests

    /// Closing the reader sends the queued position without waiting out the 15 s window.
    func testFlush_WithQueuedSnapshot_PostsItBeforeTheWindowEnds() async throws {
        try await postThenQueue(queued: "last")

        let flush = startFlush()
        try await waitPosts(2)

        XCTAssertEqual(adapter.postedPayloads, ["first", "last"])
        adapter.releaseNext()
        try await finish(flush.task)
    }

    /// The window's flush timer finds nothing to send after flush, so the position posts once.
    func testFlush_ThenWindowTimerFires_PostsTheQueuedSnapshotOnce() async throws {
        try await postThenQueue(queued: "last")
        let flush = startFlush()
        try await waitPosts(2)
        adapter.releaseNext()
        try await finish(flush.task)

        scheduler.fireAll()
        await writer.waitForQueue()
        await writer.waitForQueue()

        XCTAssertEqual(adapter.postCount, 2, "the timer must not post the flushed snapshot again")
    }

    /// The flush opens a new window: a later save queues behind it on a new
    /// timer, and the old window's timer posts nothing.
    func testFlush_ThenSaveInsideNewWindow_QueuesOnItsOwnTimer() async throws {
        try await postThenQueue(queued: "last")
        let flush = startFlush()
        try await waitPosts(2)
        adapter.releaseNext()
        try await finish(flush.task)
        let oldTimers = scheduler.takeAll()

        clock.advance(by: 4)
        let writer = self.writer!
        let after = snapshot("book-A", "after")
        let id = try await bounded("the save after flush") { try await writer.save(after) }
        XCTAssertNil(id, "a save inside the flush's window queues")
        XCTAssertEqual(scheduler.delays, [11], "the queued save waits for the flush's window to end")

        oldTimers.forEach { $0() }
        await writer.waitForQueue()
        await writer.waitForQueue()
        XCTAssertEqual(adapter.postCount, 2, "the old window's timer must not post the new save early")
    }

    /// A second close (the reader's view can disappear more than once) does not send the position again.
    func testFlush_CalledTwice_PostsTheQueuedSnapshotOnce() async throws {
        try await postThenQueue(queued: "last")
        let first = startFlush()
        try await waitPosts(2)
        adapter.releaseNext()
        try await finish(first.task)

        let second = startFlush()
        try await finish(second.task)

        XCTAssertEqual(adapter.postCount, 2)
    }

    /// Closing one book does not wait for another book's upload.
    func testFlush_OtherBookPostHeld_ReturnsWithoutWaitingForIt() async throws {
        try await postThenQueue("book-B", queued: "b-last")
        scheduler.fireAll()
        try await waitPosts(2)

        let flush = startFlush("book-A")
        try await finish(flush.task)

        XCTAssertEqual(adapter.pendingCount, 1, "book B's post is still held")
    }

    /// The call returns only after the post ends, so a caller that awaits it knows the upload finished.
    func testFlush_ReturnsOnlyAfterThePostEnds() async throws {
        try await postThenQueue(queued: "last")

        let flush = startFlush()
        try await waitPosts(2)
        await writer.waitForQueue()
        XCTAssertFalse(flush.returned.value, "flush returned while its post was still held")

        adapter.releaseNext()
        try await finish(flush.task)
        XCTAssertTrue(flush.returned.value)
    }

    /// The post runs inside a background task, so suspension after close does not drop it.
    func testFlush_HoldsABackgroundTaskUntilThePostEnds() async throws {
        try await postThenQueue(queued: "last")

        let flush = startFlush()
        try await waitPosts(2)
        XCTAssertEqual(background.begunIDs.count, 2, "the flush post began its own background task")
        XCTAssertEqual(background.endCount, 1, "only the first post's background task has ended")

        adapter.releaseNext()
        try await finish(flush.task)
        XCTAssertEqual(background.endedIDs.sorted(), background.begunIDs.sorted())
    }

    /// The writer keeps the flush post: a caller that does not await still gets the upload.
    func testFlush_CallerDoesNotAwait_PostStillReachesTheServer() async throws {
        try await postThenQueue(queued: "last")

        let flush = startFlush()
        flush.task.cancel()
        try await waitPosts(2)

        XCTAssertEqual(adapter.postedPayloads.last, "last")
        XCTAssertEqual(adapter.cancelledCallCount, 0, "cancelling the caller must not cancel the writer's post")
        adapter.releaseNext()
        try await finish(flush.task)
    }

    /// With nothing queued there is nothing to send.
    func testFlush_NothingQueued_PostsNothing() async throws {
        let writer = self.writer!
        let only = snapshot("book-A", "only")
        let save = Task { try await writer.save(only) }
        try await waitPosts(1)
        adapter.releaseNext()
        _ = try await bounded("the save") { try await save.value }

        let flush = startFlush()
        try await finish(flush.task)

        XCTAssertEqual(adapter.postCount, 1)
    }

    /// A window flush already posting is waited for, not duplicated.
    func testFlush_WhileWindowFlushIsPosting_WaitsForItAndPostsNothingNew() async throws {
        try await postThenQueue(queued: "last")
        scheduler.fireAll()
        try await waitPosts(2)

        let flush = startFlush()
        await writer.waitForQueue()
        XCTAssertFalse(flush.returned.value, "flush returned before the running flush post ended")

        adapter.releaseNext()
        try await finish(flush.task)
        XCTAssertEqual(adapter.postCount, 2)
    }

    /// Closing one book leaves another book's queued position on its own timer.
    func testFlush_OtherBookQueued_LeavesItForItsTimer() async throws {
        try await postThenQueue("book-A", queued: "a-last")
        try await postThenQueue("book-B", queued: "b-last")

        let flush = startFlush("book-A")
        try await waitPosts(3)
        adapter.releaseNext()
        try await finish(flush.task)
        XCTAssertEqual(adapter.postedPayloads, ["first", "first", "a-last"])

        scheduler.fireAll()
        try await waitPosts(4)
        XCTAssertEqual(adapter.postedPayloads.last, "b-last")
    }

    /// A loan return after close still cancels the flush post (the return path calls cancel).
    func testCancel_WhileFlushPostRuns_CancelsItAndFlushReturns() async throws {
        try await postThenQueue(queued: "last")
        let flush = startFlush()
        try await waitPosts(2)

        let writer = self.writer!
        try await bounded("cancel(for:)") { await writer.cancel(for: "book-A") }

        XCTAssertEqual(adapter.cancelledCallCount, 1)
        try await finish(flush.task)
    }
}

/// Set when `flush(for:)` returns.
private final class FlushReturned: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return _value }
    func mark() { lock.lock(); defer { lock.unlock() }; _value = true }
}
