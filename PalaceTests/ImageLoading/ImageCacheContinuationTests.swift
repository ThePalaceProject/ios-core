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
/// The test runs on its own cache instance: the shared queue also carries the
/// test host app's cover loads, so its `operationCount` cannot say whether the
/// test's own operations are queued yet. It suspends the queue, enqueues the
/// awaits so they are still queued, cancels all operations, then resumes the
/// queue. Every cancelled-while-queued operation must still resume its
/// continuation.
@MainActor
final class ImageCacheContinuationTests: XCTestCase {

    private var cache: ImageCache?

    override func tearDown() {
        // Resume the queue even when an assertion failed mid-test, so no
        // operation stays parked. Required by TearDownRequiredLintTests.
        cache?.processingQueue.cancelAllOperations()
        cache?.processingQueue.isSuspended = false
        cache = nil
        super.tearDown()
    }

    func testGetAsync_whenOperationsCancelledWhileQueued_everyCallResumes() async {
        let cache = ImageCache._makeIsolatedForTesting()
        self.cache = cache
        cache.processingQueue.isSuspended = true

        let count = 50
        let resumedCount = LockIsolated<Int>(0)

        // Each child returns only when its continuation resumes. The fan-out
        // runs in its own task so a leaked continuation (the bug this test
        // pins) fails the bounded wait below instead of hanging the test.
        let fanOut = Task.detached {
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
        }

        // The queue is this test's alone, so the count reaching 50 means every
        // getAsync has enqueued its operation and none has started.
        await awaitConditionAsync(timeout: 45) { cache.processingQueue.operationCount >= count } // FLAKE-003-OK: hang guard below the execution-time allowance, not a timing assertion
        cache.processingQueue.cancelAllOperations()
        cache.processingQueue.isSuspended = false

        await awaitConditionAsync(timeout: 45) { count == resumedCount.value } // FLAKE-003-OK: hang guard below the execution-time allowance, not a timing assertion
        XCTAssertEqual(resumedCount.value, count,
                       "Every cancelled-while-queued getAsync must resume its continuation exactly once")
        if resumedCount.value == count {
            await fanOut.value
        }
    }
}

/// Regression test for the off-main isolation crash (PR #1338).
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
