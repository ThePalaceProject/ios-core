//
//  AccountRegistryStorePoolStarvationTests.swift
//  PalaceTests
//
//  `AccountRegistryStore` reads must not consume cooperative-pool threads while
//  waiting on GCD to schedule work.
//
//  THE DEFECT. `performRead` was `accountSetsLock.sync { }` on a concurrent
//  queue, and writes were `.async(flags: .barrier)`. A `.sync` read must wait
//  for any queued barrier — and that barrier needs a GCD WORKER THREAD to run.
//  When the readers are Swift Tasks, each blocked reader occupies one
//  cooperative-pool thread, and that pool's width is the core count. Enough
//  concurrent readers and every worker is blocked waiting for a barrier that
//  cannot be scheduled because the threads it needs are the ones blocked. It
//  resolves only when GCD's thread-explosion heuristic slowly adds threads.
//
//  Measured on device/CI: 24 threads (== core count) parked in `__ulock_wait`
//  inside `performRead`, with NO barrier writer running. Whole-worker freezes of
//  189-404 SECONDS between two 0.001s tests in an unrelated suite — the CI job
//  spends 1600-2500s of its 3600s budget stalled, which is what pushes it over
//  the 60-minute ceiling.
//
//  THE CONTRACT PINNED HERE. Reads and writes are safe to issue from Task
//  context: they block only for an actual critical section, never on thread
//  availability. The always-on test expresses that as COMPLETION — every
//  concurrent store operation finishes — because the broken implementation did
//  not finish at all: it deadlocked the whole bundle (exit 124 at 20 minutes).
//
//  It deliberately does NOT require an unrelated Task to be SCHEDULED within a
//  deadline. That formulation measures the machine rather than the store; it
//  passed 3/3 CI iterations once and then failed one iteration at 69 SECONDS on
//  a build whose only delta added `Task { await MainActor.run { … } }` hops
//  elsewhere. The stress variant that does require scheduling is kept, gated
//  behind PALACE_STRESS_POOL=1, where a quiet machine makes it meaningful.
//
//  The field symptom this all came from:
//  `CatalogCrawlSchedulerTests.test_productionSpawn_runsOperation` does nothing
//  but spawn a `.utility` Task and await it, and it hung.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest

@testable import Palace

final class AccountRegistryStorePoolStarvationTests: XCTestCase {

    /// Every concurrent store operation must COMPLETE. That is the property the
    /// lock change buys, and it is the one this asserts.
    ///
    /// Under the dispatch-barrier implementation this did not merely run slowly
    /// — the whole test bundle DEADLOCKED and had to be killed (exit 124 after
    /// 20 minutes), because each blocked reader held a cooperative-pool thread
    /// while waiting on a barrier that needed one of those same threads to run.
    /// So "all operations finished" cleanly separates fixed from broken.
    ///
    /// DELIBERATELY NOT a scheduler race. The first version of this test spawned
    /// a separate `.utility` probe Task and required it to be SCHEDULED within a
    /// deadline while the pool was hammered. That measured whatever else the
    /// machine was doing: it passed 3/3 iterations on one CI run and then, on
    /// the next, passed twice and failed once after 69 SECONDS — on a build
    /// whose only delta was a toolkit bump that added `Task { await
    /// MainActor.run { … } }` hops to the audiobook completion paths. A test
    /// that flips with unrelated pool traffic reports the runner, not the store,
    /// and it can hide a real regression just as easily as invent one (retry
    /// would have swallowed the failure). The load-sensitive variant is kept
    /// below, opt-in.
    func testConcurrentReadsAndWrites_allComplete() async {
        let store = AccountRegistryStore(currentHash: "hash")
        // MUST exceed the cooperative pool's width, which is the core count —
        // that is the precondition for the deadlock, not an arbitrary "lots".
        // At 32 this test PASSED against the reintroduced defect (0.007s) and
        // caught nothing; the count is load-bearing and is why it scales.
        let operations = max(64, ProcessInfo.processInfo.activeProcessorCount * 4)

        let finished = TestBox()
        let work = Task.detached(priority: .utility) {
            await withTaskGroup(of: Void.self) { group in
                for i in 0..<operations {
                    group.addTask {
                        // Interleave writes: under the old model a queued barrier
                        // is exactly what a `.sync` reader had to wait for.
                        if i % 8 == 0 {
                            store.mutate { $0["hash", default: []] = [] }
                        }
                        _ = store.bucketIsNonEmpty(hash: "hash")
                        _ = store.account("nobody")
                        _ = store.currentHash
                    }
                }
            }
            finished.set()
        }

        // Generous bound: this separates DEADLOCK from slow, not fast from slow.
        // A loaded runner may take seconds; a broken lock never finishes at all.
        let completed = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask { _ = await work.value; return true }
            group.addTask {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }

        XCTAssertTrue(
            completed,
            "\(operations) concurrent store operations did not all complete. Reads are blocking "
                + "on GCD scheduling again, so cooperative-pool threads are held waiting for work "
                + "that needs those same threads — the deadlock that killed the bundle outright."
        )
        XCTAssertTrue(finished.value, "the work group must have actually run to completion")
    }

    /// Opt-in stress variant of the above: requires an unrelated Task to be
    /// SCHEDULED while the pool is saturated. It reproduces the original defect
    /// vividly on a quiet machine, and is meaningless on a busy one, so it is
    /// gated out of CI rather than left to flap.
    ///
    ///     PALACE_STRESS_POOL=1 (via TEST_RUNNER_PALACE_STRESS_POOL=1)
    func testStress_readsUnderSaturationDoNotStarveTheCooperativeThreadPool() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["PALACE_STRESS_POOL"] == "1",
            // TEST_RUNNER_ prefix required. xcodebuild forwards only
            // TEST_RUNNER_-prefixed variables into the test process, so the
            // bare form this message used to name set the variable in the
            // shell and the test skipped anyway — an opt-in that could not be
            // opted into. Verified both ways before changing the wording.
            "load-sensitive; run with TEST_RUNNER_PALACE_STRESS_POOL=1"
        )
        let store = AccountRegistryStore(currentHash: "hash")
        let readers = max(64, ProcessInfo.processInfo.activeProcessorCount * 4)

        let hammer = Task.detached(priority: .utility) {
            await withTaskGroup(of: Void.self) { group in
                for i in 0..<readers {
                    group.addTask {
                        if i % 8 == 0 {
                            store.mutate { $0["hash", default: []] = [] }
                        }
                        _ = store.bucketIsNonEmpty(hash: "hash")
                        _ = store.account("nobody")
                        _ = store.currentHash
                    }
                }
            }
        }

        let probeRan = TestBox()
        let probe = Task(priority: .utility) { probeRan.set() }
        let outcome = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask { _ = await probe.value; return true }
            group.addTask {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        _ = await hammer.value

        XCTAssertTrue(outcome, "a .utility Task could not be scheduled while \(readers) reads were in flight")
        XCTAssertTrue(probeRan.value, "probe Task must have actually executed")
    }

    /// The lock change must not weaken the index-coherence invariant: a reader
    /// must never observe updated `accountSets` with a stale `accountByUUID`.
    func testConcurrentMutation_keepsAccountIndexCoherent() async {
        let store = AccountRegistryStore(currentHash: "hash")
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<64 {
                group.addTask {
                    if i % 2 == 0 {
                        store.mutate { $0["hash", default: []] = [] }
                    } else {
                        XCTAssertTrue(
                            store._coherentSnapshot(),
                            "accountByUUID desynced from accountSets — the index must be "
                                + "rebuilt inside the SAME critical section as the mutation."
                        )
                    }
                }
            }
        }
    }
}

/// Minimal thread-safe flag; the test target's shared helpers are not visible
/// from every file and this needs to be `Sendable` for the Task capture.
private final class TestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}
