//
//  XCTestCase+drainMainQueue.swift
//  PalaceTests
//
//  Replaces the banned `DispatchQueue.main.asyncAfter(N) + wait(for:timeout:)`
//  sleep-as-expectation pattern. The asyncAfter form was a fixed-delay sleep
//  disguised as an expectation: under main-thread contention the timer would
//  fire too late and the test would fail with "Asynchronous wait failed".
//
//  `drainMainQueue` enqueues a no-op on the main queue and waits for it to
//  flush. Because DispatchQueue.main is FIFO, all earlier-queued blocks have
//  run by the time the no-op fires — no fixed delay, no timing guess.
//
//  Per CLAUDE.md: "never use sleep/delay waits, always use XCTestExpectation".
//

import XCTest

extension XCTestCase {

    /// Drains pending blocks on the main queue.
    ///
    /// Use after async work whose downstream main-queue dispatch (Combine
    /// `.receive(on: .main)`, NotificationCenter post on a main observer,
    /// `subject.send()` chains) needs to land before the next assertion.
    ///
    /// Does NOT wait for `Task { ... }`-based async work — Tasks don't
    /// hop through the main queue. Use `awaitCondition` for those.
    ///
    /// **DO NOT call this from `async` test methods.** Synchronous
    /// `wait(for:)` blocks the executor that the `DispatchQueue.main.async`
    /// block is waiting to run on — deadlock under `@MainActor async`
    /// tests. Use `await drainMainQueueAsync()` instead (below).
    ///
    /// - Parameter timeout: Maximum seconds to wait for the no-op to flush.
    ///   Default 5s — generous under heavy suite load while still failing
    ///   visibly on a genuinely starved main thread.
    func drainMainQueue(timeout: TimeInterval = 5.0) {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: timeout)
    }

    /// Async sibling of `drainMainQueue` for `async` test bodies.
    ///
    /// Synchronous `drainMainQueue()` deadlocks inside `@MainActor async`
    /// tests because `wait(for:)` blocks the main executor while the
    /// `.main.async` block is queued on the same executor. `await
    /// fulfillment(of:)` suspends correctly, letting the main queue drain.
    ///
    /// Promoted to the shared helper from MyBooksDownloadCenterOfflineTests
    /// after CI on PR #989 surfaced this gap in HoldsViewModelTests'
    /// async-test migrations (HoldsSyncFailureTests×3 deadlocked when
    /// `await fulfillment(...)` was naively replaced with sync
    /// `drainMainQueue()`).
    ///
    /// - Parameter timeout: Maximum seconds to wait. Default 5s.
    func drainMainQueueAsync(timeout: TimeInterval = 5.0) async {
        let drained = expectation(description: "main queue drained (async)")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: timeout)
    }

    /// Polls a synchronous predicate until it returns true, or fails on timeout.
    ///
    /// Use for `Task`-based async work where the production code spawns a
    /// detached Task and the test needs to wait for the resulting main-thread
    /// state mutation. `drainMainQueue` is not enough because Tasks don't
    /// schedule through the main queue.
    ///
    /// - Parameters:
    ///   - timeout: Maximum seconds to wait. Default 5s.
    ///   - pollInterval: How often to re-check. Default 50ms.
    ///   - predicate: A synchronous closure that returns true once the
    ///     observed state has converged.
    func awaitCondition(
        timeout: TimeInterval = 5.0,
        pollInterval: TimeInterval = 0.05,
        _ predicate: @escaping () -> Bool
    ) {
        let met = expectation(description: "condition met")
        var fulfilled = false
        func poll() {
            if fulfilled { return }
            if predicate() {
                fulfilled = true
                met.fulfill()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval) { poll() }
        }
        poll()
        wait(for: [met], timeout: timeout)
    }

    /// Async sibling of `awaitCondition` for `async` test bodies that need
    /// to poll a synchronous predicate between awaits. Same semantics:
    /// fails the test loudly via `XCTFail` on timeout — never returns
    /// silently with a stale predicate, which causes the next assertion
    /// to read the wrong value (the historic test-flake pattern this
    /// helper replaces).
    ///
    /// Use over a hand-rolled `while Date() < deadline { ... }` loop.
    /// Default timeout 10s — async test bodies typically chain more
    /// actor hops than sync ones; the extra headroom tolerates CI-runner
    /// load without masking real stuck conditions.
    ///
    /// - Parameters:
    ///   - timeout: Maximum seconds to wait. Default 10s.
    ///   - pollInterval: How often to re-check. Default 25ms.
    ///   - file/line: For accurate XCTFail attribution.
    ///   - predicate: Synchronous closure returning true once converged.
    func awaitConditionAsync(
        timeout: TimeInterval = 10.0,
        pollInterval: TimeInterval = 0.025,
        file: StaticString = #file,
        line: UInt = #line,
        _ predicate: @escaping () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            await Task.yield()
        }
        XCTFail(
            "awaitConditionAsync timed out after \(timeout)s without the predicate becoming true. " +
            "Bump timeout if CI is the issue, OR fix the production code that should have signalled.",
            file: file,
            line: line
        )
    }

    /// Async-predicate sibling of `awaitConditionAsync` for waits that need
    /// to read actor-isolated state inside the predicate (e.g. polling an
    /// actor's queue count, awaiting a NotificationCenter publish on a
    /// specific thread). Same loud-on-timeout semantics.
    ///
    /// Prefer the sync-predicate overload when the predicate doesn't
    /// require `await`; this overload exists so callers can avoid
    /// hand-rolling another silent while-deadline loop just because their
    /// observable is `async`.
    func awaitConditionAsync(
        timeout: TimeInterval = 10.0,
        pollInterval: TimeInterval = 0.025,
        file: StaticString = #file,
        line: UInt = #line,
        _ predicate: @escaping () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await predicate() { return }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            await Task.yield()
        }
        XCTFail(
            "awaitConditionAsync timed out after \(timeout)s without the async predicate becoming true. " +
            "Bump timeout if CI is the issue, OR fix the production code that should have signalled.",
            file: file,
            line: line
        )
    }
}
