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

    func testGetAsync_whenOperationsCancelledWhileQueued_everyCallResumes() {
        let cache = ImageCache.shared

        // Suspend so nothing starts running: the operations we enqueue below
        // are deterministically still *queued* when we cancel them.
        cache.processingQueue.isSuspended = true

        let count = 50
        let allResumed = expectation(description: "every getAsync call resumes")
        allResumed.expectedFulfillmentCount = count

        let enqueued = expectation(description: "all getAsync operations enqueued")
        enqueued.expectedFulfillmentCount = count

        // Disk-only/nonexistent keys force each call past the memory-cache
        // short-circuit and into a queued processing operation.
        for i in 0..<count {
            let key = "imagecache_leak_probe_\(i)_\(UUID().uuidString)"
            Task {
                enqueued.fulfill()
                _ = await cache.getAsync(for: key)
                allResumed.fulfill()
            }
        }

        // The `enqueued` fulfillments fire as each Task begins; once all have
        // fired, every operation has been added to the (suspended) queue.
        wait(for: [enqueued], timeout: 10.0)
        // Small settle so the synchronous `addOperation` inside each
        // `withCheckedContinuation` body has run before we cancel.
        let settle = expectation(description: "settle")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { settle.fulfill() }
        wait(for: [settle], timeout: 2.0)

        // Cancel every queued operation, then let the queue run. Pre-fix the
        // cancelled operations never resume → `allResumed` under-fulfills →
        // timeout. Post-fix the completion block resumes each one.
        cache.processingQueue.cancelAllOperations()
        cache.processingQueue.isSuspended = false

        wait(for: [allResumed], timeout: 15.0)
    }
}
