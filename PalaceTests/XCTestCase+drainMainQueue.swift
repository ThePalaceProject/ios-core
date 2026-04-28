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
    /// - Parameter timeout: Maximum seconds to wait for the no-op to flush.
    ///   Default 5s — generous under heavy suite load while still failing
    ///   visibly on a genuinely starved main thread.
    func drainMainQueue(timeout: TimeInterval = 5.0) {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: timeout)
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
}
