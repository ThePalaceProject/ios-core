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

/// Regression test for the Wave-2a off-main isolation crash (PR #1338).
///
/// Moving `ImageCacheType` into the Swift-6 `PalaceBookModel` package changed the
/// build context so that the `processingQueue.addOperation` /
/// `BlockOperation.addExecutionBlock` closures FORMED INSIDE `ImageCache`'s
/// members were inferred `@MainActor` — even with class/method/leaf
/// `nonisolated`. Running such a block on the background utility queue trips
/// `dispatch_assert_queue` → EXC_BREAKPOINT (SIGTRAP), crashing the whole test
/// host at bootstrap. The fix forms those closures in free functions
/// (`imageCacheEnqueue*`) that have no enclosing-type isolation to inherit.
///
/// Each test below drives a real image THROUGH one of the off-main blocks and
/// then drains `processingQueue`, forcing the block to execute off-main. On the
/// broken build the drain SIGTRAPs deterministically (no CPU pressure needed);
/// on the fixed build the block runs and the asserted cache behavior holds.
/// `ImageCache` has a private init, so these exercise the `.shared` singleton
/// and clear it in tearDown to avoid cross-test bleed.
@MainActor
final class ImageCacheOffMainIsolationTests: XCTestCase {

    override func tearDown() {
        ImageCache.shared.processingQueue.cancelAllOperations()
        ImageCache.shared.processingQueue.isSuspended = false
        ImageCache.shared.clear()
        super.tearDown()
    }

    /// A small opaque image with a real backing `CGImage` so `resize`,
    /// `imageCost`, and JPEG encoding all run (they early-return on a nil
    /// `cgImage`).
    private func makeImage() -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4))
        return renderer.image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
    }

    /// Blocks until every queued processing operation has finished, forcing the
    /// off-main blocks to execute. `waitUntilAllOperationsAreFinished()` is
    /// `noasync`; this synchronous helper provides a legal (non-async) context
    /// to call it from. The operations run on the queue's own worker threads, so
    /// blocking here cannot deadlock — and the broken build's off-main isolation
    /// trap fires on those worker threads while we wait.
    private func drainProcessingQueue() {
        ImageCache.shared.processingQueue.waitUntilAllOperationsAreFinished()
    }

    /// Drives `set` (off-main store) then `getAsync` (off-main disk→memory
    /// promotion). Evicting the decoded-image cache between them forces
    /// `getAsync` to miss memory and enqueue its `BlockOperation`, so BOTH
    /// off-main blocks execute. A non-nil round-trip proves the blocks ran
    /// off-main without an isolation trap.
    func testSetThenGetAsync_roundTripsOffMainWithoutIsolationTrap() async {
        let cache = ImageCache.shared
        let key = "offmain_roundtrip_\(UUID().uuidString)"

        cache.set(makeImage(), for: key)
        drainProcessingQueue()

        // Drop the decoded UIImage so getAsync misses memory and must run its
        // off-main promotion block (the crashing path on the broken build).
        cache.evictDecodedImages()

        let promoted = await cache.getAsync(for: key)
        XCTAssertNotNil(promoted,
                        "set + getAsync must round-trip the image through the off-main processing queue")
    }

    /// Drives the main-thread `get` miss path: on the main thread a memory miss
    /// schedules a background disk→memory promotion and returns nil immediately.
    /// Draining the queue runs that promotion off-main (the crashing path on the
    /// broken build); the next main-thread `get` then hits the repopulated
    /// memory cache.
    func testMainThreadGetMiss_schedulesOffMainPromotionWithoutIsolationTrap() {
        let cache = ImageCache.shared
        let key = "offmain_promote_\(UUID().uuidString)"

        cache.set(makeImage(), for: key)
        cache.processingQueue.waitUntilAllOperationsAreFinished()
        cache.evictDecodedImages()

        // Main thread + memory miss → schedules background promotion, returns nil.
        XCTAssertNil(cache.get(for: key),
                     "main-thread get returns nil on a memory miss and schedules a background promotion")

        cache.processingQueue.waitUntilAllOperationsAreFinished()

        XCTAssertNotNil(cache.get(for: key),
                        "the off-main promotion must repopulate memory so the next main-thread get hits")
    }
}
