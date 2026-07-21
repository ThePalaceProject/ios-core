import XCTest
import UIKit
@testable import Palace

/// Regression test for the `ImageCache.getAsync` continuation leak
/// (Crashlytics `ab80dbb0`).
///
/// `handleMemoryWarning()` calls `processingQueue.cancelAllOperations()`. Before
/// the fix, every `continuation.resume` lived *inside* the processing
/// operation's block, so a cancelled-while-queued operation never ran its block
/// and orphaned its continuation — the awaiting Task then hung forever, pinning
/// the suspended Task + captured graph in memory under the exact pressure the
/// warning was trying to relieve. The fix guarantees exactly one resume via the
/// operation's completion block.
///
/// `ImageCache` has a private init, so only `.shared` is constructible. To make
/// the cancellation deterministic (and avoid spamming a global memory-warning
/// notification through the whole launched app), we suspend the processing
/// queue, enqueue the awaits so they are *guaranteed* still queued, cancel all
/// operations, then resume the queue. Every cancelled-while-queued operation
/// must still resume its continuation.
@MainActor
final class ImageCacheContinuationTests: XCTestCase {

    override func tearDown() {
        // This test deliberately suspends the shared cache's processing queue.
        // Restore it (and drain any operations) so a mid-test assertion failure
        // can't leave the singleton queue suspended and pollute later tests that
        // call `ImageCache.shared.getAsync`. Required by TearDownRequiredLintTests.
        ImageCache.shared.processingQueue.cancelAllOperations()
        ImageCache.shared.processingQueue.isSuspended = false
        super.tearDown()
    }

    func testGetAsync_whenOperationsCancelledWhileQueued_everyCallResumes() async {
        let cache = ImageCache.shared

        // Suspend so nothing starts running: the operations we enqueue below
        // are deterministically still *queued* when we cancel them.
        cache.processingQueue.isSuspended = true

        let count = 50

        // Structured fan-out. Each child awaits `getAsync`; a child returns
        // ONLY when its continuation resumes. `withTaskGroup` returns only when
        // ALL children have returned — so `resumedCount == count` after the
        // group is an EXACT proof that every getAsync resumed, with NO
        // fixed-timeout `XCTestExpectation` gamble.
        //
        // Why this is scheduling-independent (fixes the parallel-clone timeout,
        // CI run 29805821296): the resume is driven by the OperationQueue
        // completion block, not the cooperative pool. Once the driver cancels +
        // unsuspends the queue, every operation's completion block runs (the
        // OperationQueue owns its own worker threads) and resumes its
        // continuation, so every child returns and the group completes. The
        // completion of `withTaskGroup` — which returns ONLY when all 50
        // children have returned — is the exact resume-completeness proof. The
        // previous version spawned 50 unstructured `Task {}` and waited on
        // `XCTestExpectation` timeouts, which under 4-clone CPU oversubscription
        // could exceed 15s purely because the cooperative pool never scheduled
        // the 50 tasks — a wall-clock race this structured form removes.
        let resumedCount = LockIsolated<Int>(0)

        // Detached driver: once the (synchronous) `addOperation` calls inside
        // each `getAsync` have run — observed via `operationCount` reaching
        // `count`, not a fixed sleep — cancel every queued op and unsuspend so
        // the completion blocks fire and resume the continuations.
        let driver = Task.detached {
            while cache.processingQueue.operationCount < count {
                await Task.yield()
            }
            cache.processingQueue.cancelAllOperations()
            cache.processingQueue.isSuspended = false
        }

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<count {
                let key = "imagecache_leak_probe_\(i)_\(UUID().uuidString)"
                group.addTask {
                    _ = await cache.getAsync(for: key)
                    resumedCount.withValue { $0 += 1 }
                }
            }
            await group.waitForAll()
        }
        await driver.value

        XCTAssertEqual(resumedCount.value, count,
                       "Every cancelled-while-queued getAsync must resume its continuation exactly once")
    }
}
