//
//  RemotePositionWriterTests.swift
//  PalaceReadingPositionTests
//
//  Behavior tests for the canonical writer's throttle, queue, cancel,
//  and concurrency contract. Network calls are stubbed via a spy
//  `PositionNetworkAdapter`.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import PalaceReadingPosition

final class RemotePositionWriterTests: XCTestCase {

    // MARK: - save() throttle behavior

    func testSave_firstSnapshotInWindow_postsImmediately_returnsServerID() async throws {
        let adapter = SpyAdapter()
        adapter.postResults = [.success("server-id-1")]
        let writer = RemotePositionWriter(network: adapter, throttle: 15, clock: { Date() })

        let id = try await writer.save(makeSnapshot(bookID: "book-A"))

        XCTAssertEqual(id, "server-id-1")
        XCTAssertEqual(adapter.postCount, 1)
    }

    func testSave_secondSnapshotInWindow_queuesAndReturnsNil() async throws {
        let adapter = SpyAdapter()
        adapter.postResults = [.success("server-id-1")]
        let clock = FrozenClock(start: Date(timeIntervalSince1970: 1_000))
        let writer = RemotePositionWriter(network: adapter, throttle: 15, clock: clock.now)

        _ = try await writer.save(makeSnapshot(bookID: "book-A", timestamp: clock.current))

        // Advance only a few seconds — still inside the window.
        clock.advance(by: 5)
        let id = try await writer.save(makeSnapshot(bookID: "book-A", timestamp: clock.current))

        XCTAssertNil(id, "second snapshot inside window should be queued, not posted")
        XCTAssertEqual(adapter.postCount, 1, "only the first snapshot should have posted")
    }

    func testSave_secondSnapshotInWindow_overwritesQueuedSnapshot_onlyLatestPosted() async throws {
        let adapter = SpyAdapter()
        adapter.postResults = [.success("first"), .success("third")]
        // Use a short, real-wallclock throttle so the deferred-flush dispatch fires
        // within the test budget. (The FrozenClock isolates throttle decisions but
        // can't drive asyncAfter, by design.)
        let writer = RemotePositionWriter(network: adapter, throttle: 0.1)

        // First snapshot posts immediately.
        _ = try await writer.save(makeSnapshot(bookID: "book-A", payload: "p1"))

        // Two queued snapshots inside window — second should overwrite first.
        _ = try await writer.save(makeSnapshot(bookID: "book-A", payload: "p2"))
        _ = try await writer.save(makeSnapshot(bookID: "book-A", payload: "p3"))

        // Wait long enough for the deferred flush to fire.
        try await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertEqual(adapter.postCount, 2, "exactly two POSTs — first and the latest queued")
        // The 2nd POST must carry payload p3, not p2.
        let posted = adapter.postedSnapshots.last
        XCTAssertEqual(posted?.payload, Data("p3".utf8))
    }

    func testSave_atExactThrottleBoundary_postsImmediately() async throws {
        // Kills the `>=` -> `>` boundary mutant. If the writer required
        // strict `>`, this save would queue instead of post.
        let adapter = SpyAdapter()
        adapter.postResults = [.success("first"), .success("boundary")]
        let clock = FrozenClock(start: Date(timeIntervalSince1970: 1_000))
        let writer = RemotePositionWriter(network: adapter, throttle: 15, clock: clock.now)

        _ = try await writer.save(makeSnapshot(bookID: "book-A"))
        clock.advance(by: 15)   // exactly throttle window elapsed
        let id = try await writer.save(makeSnapshot(bookID: "book-A"))

        XCTAssertEqual(id, "boundary", "save at the exact window edge must post, not queue")
        XCTAssertEqual(adapter.postCount, 2)
    }

    func testSave_thirdAfterThrottleElapsed_postsImmediately() async throws {
        let adapter = SpyAdapter()
        adapter.postResults = [.success("first"), .success("second")]
        let clock = FrozenClock(start: Date(timeIntervalSince1970: 1_000))
        let writer = RemotePositionWriter(network: adapter, throttle: 15, clock: clock.now)

        _ = try await writer.save(makeSnapshot(bookID: "book-A"))
        clock.advance(by: 20)
        let id = try await writer.save(makeSnapshot(bookID: "book-A"))

        XCTAssertEqual(id, "second")
        XCTAssertEqual(adapter.postCount, 2)
    }

    // MARK: - error propagation

    func testSave_networkFailure_propagatesError() async {
        let adapter = SpyAdapter()
        adapter.postResults = [.failure(PositionWriterError.networkUnavailable)]
        let writer = RemotePositionWriter(network: adapter, throttle: 15)

        do {
            _ = try await writer.save(makeSnapshot(bookID: "book-A"))
            XCTFail("expected network error")
        } catch let error as PositionWriterError {
            XCTAssertEqual(error, .networkUnavailable)
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    // MARK: - cancel

    func testSave_cancelDuringPending_dropsQueuedSnapshot_noPostFires() async throws {
        let adapter = SpyAdapter()
        adapter.postResults = [.success("first")]
        let clock = FrozenClock(start: Date(timeIntervalSince1970: 1_000))
        let writer = RemotePositionWriter(network: adapter, throttle: 15, clock: clock.now)

        _ = try await writer.save(makeSnapshot(bookID: "book-A"))
        clock.advance(by: 2)
        _ = try await writer.save(makeSnapshot(bookID: "book-A"))
        XCTAssertEqual(adapter.postCount, 1)

        await writer.cancel(for: "book-A")
        clock.advance(by: 30)
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(adapter.postCount, 1, "cancel must drop the queued snapshot")
    }

    func testCancel_isIdempotent_canBeCalledTwice() async {
        let adapter = SpyAdapter()
        let writer = RemotePositionWriter(network: adapter, throttle: 15)

        await writer.cancel(for: "book-A")
        await writer.cancel(for: "book-A")
        // Reaching here without crash is the assertion.
    }

    func testCancel_differentBookID_doesNotAffectOtherQueue() async throws {
        let adapter = SpyAdapter()
        adapter.postResults = [.success("a1"), .success("b1"), .success("a2")]
        // Real-wallclock throttle so the deferred flush fires inside the test budget.
        let writer = RemotePositionWriter(network: adapter, throttle: 0.1)

        _ = try await writer.save(makeSnapshot(bookID: "book-A"))
        _ = try await writer.save(makeSnapshot(bookID: "book-B"))
        _ = try await writer.save(makeSnapshot(bookID: "book-A"))  // queued

        await writer.cancel(for: "book-B")  // should not touch book-A

        try await Task.sleep(nanoseconds: 400_000_000)

        // 3 posts: A initial, B initial, A flushed from queue.
        XCTAssertEqual(adapter.postCount, 3)
        let bookIDs = adapter.postedSnapshots.map(\.bookID)
        XCTAssertEqual(bookIDs.filter { $0 == "book-A" }.count, 2)
        XCTAssertEqual(bookIDs.filter { $0 == "book-B" }.count, 1)
    }

    // MARK: - load

    func testLoad_returnsSnapshotFromAdapter() async throws {
        let adapter = SpyAdapter()
        let expected = makeSnapshot(bookID: "book-A", payload: "remote")
        adapter.fetchResults = ["book-A": .success(expected)]
        let writer = RemotePositionWriter(network: adapter)

        let loaded = try await writer.load(for: "book-A")
        XCTAssertEqual(loaded, expected)
        XCTAssertEqual(adapter.fetchCount, 1)
    }

    func testLoad_adapterReturnsNil_returnsNil() async throws {
        let adapter = SpyAdapter()
        adapter.fetchResults = ["book-A": .success(nil)]
        let writer = RemotePositionWriter(network: adapter)

        let loaded = try await writer.load(for: "book-A")
        XCTAssertNil(loaded)
    }

    func testLoad_adapterThrows_propagatesError() async {
        let adapter = SpyAdapter()
        adapter.fetchResults = ["book-A": .failure(PositionWriterError.unauthorized)]
        let writer = RemotePositionWriter(network: adapter)

        do {
            _ = try await writer.load(for: "book-A")
            XCTFail("expected unauthorized")
        } catch let error as PositionWriterError {
            XCTAssertEqual(error, .unauthorized)
        } catch {
            XCTFail("unexpected error type")
        }
    }

    // MARK: - concurrency

    func testConcurrent_saveDifferentBookIDs_doNotInterfere() async throws {
        let adapter = SpyAdapter()
        adapter.postResults = Array(repeating: .success("ok"), count: 10)
        let writer = RemotePositionWriter(network: adapter, throttle: 15)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                let bookID = "book-\(i)"
                group.addTask {
                    _ = try await writer.save(makeSnapshotStandalone(bookID: bookID))
                }
            }
            try await group.waitForAll()
        }

        // All 10 distinct books should have posted at least once.
        XCTAssertEqual(adapter.postCount, 10)
        XCTAssertEqual(Set(adapter.postedSnapshots.map(\.bookID)).count, 10)
    }

    func testConcurrent_saveSameBookID_serializesProperly_noDataRace() async throws {
        let adapter = SpyAdapter()
        adapter.postResults = Array(repeating: .success("ok"), count: 5)
        let writer = RemotePositionWriter(network: adapter, throttle: 15)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    _ = try? await writer.save(makeSnapshotStandalone(bookID: "book-A"))
                }
            }
            try await group.waitForAll()
        }

        // Inside the 15s window only the first save should have posted;
        // others queue. So we expect exactly 1 POST (no deferred flush
        // fired because the wallclock advance is bounded).
        XCTAssertEqual(adapter.postCount, 1, "concurrent saves on same bookID coalesce to 1 POST inside window")
    }

    // MARK: - Helpers

    private func makeSnapshot(
        bookID: String,
        payload: String = "default",
        timestamp: Date = Date()
    ) -> PositionSnapshot {
        PositionSnapshot(
            bookID: bookID,
            format: .epubLocator,
            payload: Data(payload.utf8),
            timestamp: timestamp,
            device: "device-1"
        )
    }
}

// Standalone factory used inside detached Tasks where `self` isn't capturable.
private func makeSnapshotStandalone(bookID: String) -> PositionSnapshot {
    PositionSnapshot(
        bookID: bookID,
        format: .epubLocator,
        payload: Data("default".utf8),
        timestamp: Date(),
        device: "device-1"
    )
}

// MARK: - Test Doubles

/// Thread-safe clock; tests advance it manually.
final class FrozenClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date

    init(start: Date) { self._now = start }

    var current: Date {
        lock.lock(); defer { lock.unlock() }
        return _now
    }

    func advance(by interval: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        _now = _now.addingTimeInterval(interval)
    }

    var now: @Sendable () -> Date {
        { [weak self] in self?.current ?? Date() }
    }
}

/// Recording spy adapter that returns scripted results.
final class SpyAdapter: PositionNetworkAdapter, @unchecked Sendable {
    private let lock = NSLock()
    private var _postResults: [Result<ServerPositionID, Error>] = []
    private var _fetchResults: [String: Result<PositionSnapshot?, Error>] = [:]
    private(set) var postedSnapshots: [PositionSnapshot] = []
    private(set) var fetchedBookIDs: [String] = []

    var postResults: [Result<ServerPositionID, Error>] {
        get { lock.lock(); defer { lock.unlock() }; return _postResults }
        set { lock.lock(); defer { lock.unlock() }; _postResults = newValue }
    }

    var fetchResults: [String: Result<PositionSnapshot?, Error>] {
        get { lock.lock(); defer { lock.unlock() }; return _fetchResults }
        set { lock.lock(); defer { lock.unlock() }; _fetchResults = newValue }
    }

    var postCount: Int {
        lock.lock(); defer { lock.unlock() }
        return postedSnapshots.count
    }

    var fetchCount: Int {
        lock.lock(); defer { lock.unlock() }
        return fetchedBookIDs.count
    }

    func post(_ snapshot: PositionSnapshot) async throws -> ServerPositionID {
        let result: Result<ServerPositionID, Error>
        do {
            try lock.withLock {
                guard !_postResults.isEmpty else {
                    throw PositionWriterError.serverError(statusCode: 500, body: "spy exhausted")
                }
                postedSnapshots.append(snapshot)
            }
            result = lock.withLock { _postResults.removeFirst() }
        } catch {
            throw error
        }
        switch result {
        case .success(let id): return id
        case .failure(let err): throw err
        }
    }

    func fetch(bookID: String) async throws -> PositionSnapshot? {
        lock.withLock { fetchedBookIDs.append(bookID) }
        guard let r = lock.withLock({ _fetchResults[bookID] }) else { return nil }
        switch r {
        case .success(let snap): return snap
        case .failure(let err): throw err
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
}
