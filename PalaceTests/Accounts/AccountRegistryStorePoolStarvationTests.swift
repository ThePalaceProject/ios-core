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
//  availability. The probe below is the direct expression — an ordinary
//  `.utility` Task must still be schedulable while the pool is saturated with
//  readers. That is exactly the test that hung in the field
//  (`CatalogCrawlSchedulerTests.test_productionSpawn_runsOperation` does nothing
//  but spawn and await such a Task).
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest

@testable import Palace

final class AccountRegistryStorePoolStarvationTests: XCTestCase {

    /// Saturate the cooperative pool with concurrent store readers and writers,
    /// then require that an ordinary Task can still be scheduled and run.
    ///
    /// Under the dispatch-barrier implementation this starves: every pool thread
    /// sits in `accountSetsLock.sync` waiting on a barrier that has no worker
    /// thread left to run it, so the probe never gets to execute.
    func testReadsUnderSaturation_doNotStarveTheCooperativeThreadPool() async {
        let store = AccountRegistryStore(currentHash: "hash")
        // Well past the pool width so every worker is contended.
        let readers = max(64, ProcessInfo.processInfo.activeProcessorCount * 4)

        let hammer = Task.detached(priority: .utility) {
            await withTaskGroup(of: Void.self) { group in
                for i in 0..<readers {
                    group.addTask {
                        // Interleave writes so a barrier is always pending —
                        // the condition that makes a `.sync` reader wait.
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

        // The probe: a plain Task that does nothing. If the pool is exhausted by
        // blocked readers it can never be scheduled, which is the defect.
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

        XCTAssertTrue(
            outcome,
            "A .utility Task could not be scheduled while \(readers) store reads were in "
                + "flight. Reads are blocking cooperative-pool threads on GCD scheduling, so the "
                + "pool (width == core count) is exhausted and NOTHING else can run — the "
                + "189-404s whole-worker freezes seen in CI."
        )
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
