import XCTest
@testable import PalaceLogging

/// Thread-safety guard for `Log`'s shared mutable state after the Swift 6
/// strict-concurrency conversion. The throttle map and the crashlytics bridge
/// are now guarded by `OSAllocatedUnfairLock` (replacing an ad-hoc
/// concurrent-queue + barrier and an "intentionally unsynchronised" static).
/// These tests hammer those locked paths from many concurrent contexts; they
/// must complete without a crash or data-race trap (run under TSan in CI to
/// catch a regression that drops the locking).
final class LogConcurrencyTests: XCTestCase {

    /// A trivial Sendable bridge that counts forwarded lines under its own lock,
    /// so the test can also race the `crashlyticsBridge` get/set path.
    private final class CountingBridge: CrashlyticsLogBridge, @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        var count: Int { lock.withLock { _count } }
        func log(_ message: String) { lock.withLock { _count += 1 } }
    }

    override func tearDown() {
        Log.crashlyticsBridge = nil
        super.tearDown()
    }

    /// Concurrent logging from many tasks must not crash. This drives
    /// `shouldThrottlePalaceLogging` → the `throttleState` lock under heavy
    /// contention (varied tags/messages so the throttle map mutates + prunes).
    func testConcurrentLogging_doesNotCrash() async {
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<256 {
                group.addTask {
                    Log.debug("tag-\(i % 16)", "message \(i)")
                    Log.info("tag-\(i % 8)", "info \(i)")
                    Log.warn("tag-\(i % 4)", "warn \(i)")
                }
            }
        }
        // Reaching here without a trap is the assertion (locked map survived
        // concurrent read-modify-write + the >50-entry prune path).
        XCTAssertTrue(true)
    }

    /// Concurrent get/set of `crashlyticsBridge` must not race. The property is
    /// now lock-guarded; readers and writers interleave from many tasks.
    func testConcurrentBridgeGetSet_isRaceSafe() async {
        let bridge = CountingBridge()
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<200 {
                group.addTask {
                    if i.isMultiple(of: 2) {
                        Log.crashlyticsBridge = bridge
                    } else {
                        _ = Log.crashlyticsBridge
                    }
                }
            }
        }
        // The lock guarantees a torn read/write never occurs; final value is one
        // of the two written states.
        let final = Log.crashlyticsBridge
        XCTAssertTrue(final === bridge || final == nil)
    }
}
