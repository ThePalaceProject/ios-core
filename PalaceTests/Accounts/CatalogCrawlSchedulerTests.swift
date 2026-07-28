//
//  CatalogCrawlSchedulerTests.swift
//  PalaceTests
//
//  Unit tests for the PP-4754 owned-crawl infrastructure split out of
//  AccountsManager: `OwnedCrawlTaskRegistry` (self-pruning, insert-vs-complete
//  race guard) and `CrawlTaskScheduler` (the two-arm injectable spawn seam).
//
//  These are pure, offline, network-free tests — no AccountsManager, no crawl,
//  no wall-clock. They pin the registry's ownership invariants (the thing that
//  makes the test-boundary drain complete) and the scheduler's spawn contract.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class CatalogCrawlSchedulerTests: XCTestCase {

    // MARK: - OwnedCrawlTaskRegistry: self-pruning

    /// A registered task that later `complete`s prunes its token — the live set
    /// returns to zero. Kills a mutant that drops the `removeValue` in
    /// `complete`.
    func test_registerThenComplete_prunesTokenToZero() {
        let registry = OwnedCrawlTaskRegistry()
        let token = UUID()
        let task = Task<Void, Never> {}

        registry.register(token, task)
        XCTAssertEqual(registry.count, 1, "register must add the token to the live set")

        registry.complete(token)
        XCTAssertEqual(registry.count, 0, "complete must prune the token from the live set")
    }

    /// Insert-vs-complete race: when `complete` runs BEFORE `register` (the task
    /// finished before the spawning code registered it), the tombstone must make
    /// `register` skip the insert so no finished handle leaks. Kills a mutant
    /// that removes the `completedBeforeInsert` tombstone guard in `register`
    /// (without it, count would be 1 — a permanently-leaked finished task).
    func test_completeBeforeRegister_tombstoneSkipsInsert() {
        let registry = OwnedCrawlTaskRegistry()
        let token = UUID()
        let task = Task<Void, Never> {}

        // Completion beats the (still-pending) registration.
        registry.complete(token)
        XCTAssertEqual(registry.count, 0, "a completion with no prior registration must not add anything")

        // The late registration must observe the tombstone and skip the insert.
        registry.register(token, task)
        XCTAssertEqual(registry.count, 0,
                       "register must skip a token already tombstoned by an earlier complete — else a finished task leaks forever")
    }

    /// Two distinct tokens are tracked independently — completing one does not
    /// prune the other. Guards against a mutant that clears the whole map on any
    /// completion.
    func test_independentTokens_pruneIndependently() {
        let registry = OwnedCrawlTaskRegistry()
        let a = UUID(), b = UUID()
        registry.register(a, Task<Void, Never> {})
        registry.register(b, Task<Void, Never> {})
        XCTAssertEqual(registry.count, 2)

        registry.complete(a)
        XCTAssertEqual(registry.count, 1, "completing one token must leave the other live")

        let liveTokens = Set(registry.snapshot().map { $0.0 })
        XCTAssertEqual(liveTokens, [b], "the surviving token must be the one not completed")
    }

    // MARK: - OwnedCrawlTaskRegistry: cancellation

    /// `cancelAll()` cancels every live task. Kills a mutant that no-ops
    /// cancelAll (the suspended task would never observe cancellation and the
    /// await below would hang the test).
    func test_cancelAll_cancelsEveryLiveTask() async {
        let registry = OwnedCrawlTaskRegistry()
        let suspicious = Task<Void, Never> {
            // Suspends until cancelled; `Task.sleep` throws on cancel so `try?`
            // lets it complete cleanly. No wall-clock dependence — the value is
            // `.max` and only cancellation ends the sleep.
            try? await Task.sleep(nanoseconds: .max)
        }
        registry.register(UUID(), suspicious)

        registry.cancelAll()
        _ = await suspicious.value

        XCTAssertTrue(suspicious.isCancelled,
                      "cancelAll must request cancellation of every registered task")
    }

    /// `snapshot()` returns the live (token, task) pairs so the drain can await
    /// them. Confirms the returned handle is the one registered.
    func test_snapshot_returnsRegisteredHandles() {
        let registry = OwnedCrawlTaskRegistry()
        let token = UUID()
        let task = Task<Void, Never> {}
        registry.register(token, task)

        let snap = registry.snapshot()
        XCTAssertEqual(snap.count, 1)
        XCTAssertEqual(snap.first?.0, token, "snapshot must return the registered token")
    }

    // MARK: - CrawlTaskScheduler: two-arm spawn contract

    /// The production `spawn` arm runs the supplied operation to completion.
    func test_productionSpawn_runsOperation() async {
        let ran = TestFlag()
        let task = CrawlTaskScheduler.production.spawn(.utility) {
            ran.set()
        }
        _ = await task.value
        XCTAssertTrue(ran.value, "production.spawn must execute the operation")
    }

    /// The production `spawnDetached` arm runs the supplied operation to
    /// completion.
    func test_productionSpawnDetached_runsOperation() async {
        let ran = TestFlag()
        let task = CrawlTaskScheduler.production.spawnDetached(.userInitiated) {
            ran.set()
        }
        _ = await task.value
        XCTAssertTrue(ran.value, "production.spawnDetached must execute the operation")
    }

    /// A recording scheduler captures the (priority, detached) of each spawn AND
    /// still runs the operation — the exact seam a characterization test uses to
    /// pin the crawl scheduling contract. Proves both arms record distinctly.
    func test_recordingScheduler_capturesPriorityAndArm() async {
        let recorder = RecordingScheduler()
        let scheduler = recorder.scheduler()

        let ran1 = TestFlag(), ran2 = TestFlag()
        let t1 = scheduler.spawn(.userInitiated) { ran1.set() }
        let t2 = scheduler.spawnDetached(.utility) { ran2.set() }
        _ = await t1.value
        _ = await t2.value

        XCTAssertTrue(ran1.value && ran2.value, "recording scheduler must still run the operations")
        XCTAssertEqual(recorder.spawns, [
            .init(priority: .userInitiated, detached: false),
            .init(priority: .utility, detached: true),
        ], "recording scheduler must capture each spawn's priority and detached arm in order")
    }
}

// MARK: - Test helpers

/// Thread-safe one-shot flag so `@Sendable` operation closures can signal they
/// ran without data races.
private final class TestFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return _value }
    func set() { lock.lock(); _value = true; lock.unlock() }
}

/// A `CrawlTaskScheduler` that records each spawn's `(priority, detached)` and
/// delegates to the production spawns so the operation still runs.
private final class RecordingScheduler: @unchecked Sendable {
    struct Spawn: Equatable {
        let priority: TaskPriority
        let detached: Bool
    }
    private let lock = NSLock()
    private var _spawns: [Spawn] = []
    var spawns: [Spawn] { lock.lock(); defer { lock.unlock() }; return _spawns }

    func scheduler() -> CrawlTaskScheduler {
        CrawlTaskScheduler(
            spawn: { [self] priority, op in
                record(priority, detached: false)
                return Task(priority: priority) { await op() }
            },
            spawnDetached: { [self] priority, op in
                record(priority, detached: true)
                return Task.detached(priority: priority) { await op() }
            }
        )
    }

    private func record(_ priority: TaskPriority, detached: Bool) {
        lock.lock(); _spawns.append(Spawn(priority: priority, detached: detached)); lock.unlock()
    }
}
