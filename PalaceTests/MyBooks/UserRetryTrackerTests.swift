//
//  UserRetryTrackerTests.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class UserRetryTrackerTests: XCTestCase {

    var tracker: UserRetryTracker!

    override func setUp() {
        super.setUp()
        tracker = UserRetryTracker.shared
        // Clear any stale state from previous tests
        tracker.clearRetries(operationId: "test-op")
        tracker.clearRetries(operationId: "test-op-1")
        tracker.clearRetries(operationId: "test-op-2")
    }

    override func tearDown() {
        tracker.clearRetries(operationId: "test-op")
        tracker.clearRetries(operationId: "test-op-1")
        tracker.clearRetries(operationId: "test-op-2")
        super.tearDown()
    }

    // MARK: - canRetry

    func testCanRetry_newOperation_returnsTrue() {
        XCTAssertTrue(tracker.canRetry(operationId: "test-op"))
        // A different operation ID must independently return true
        XCTAssertTrue(tracker.canRetry(operationId: "other-op"), "Independent op must also allow retry")
    }

    func testCanRetry_afterOneRetry_returnsTrue() {
        let remaining = tracker.recordRetry(operationId: "test-op")
        XCTAssertTrue(tracker.canRetry(operationId: "test-op"))
        XCTAssertEqual(remaining, 4, "After 1 retry, 4 attempts must remain")
    }

    func testCanRetry_afterFourRetries_returnsTrue() {
        var remaining = 0
        for _ in 0..<4 {
            remaining = tracker.recordRetry(operationId: "test-op")
        }
        XCTAssertTrue(tracker.canRetry(operationId: "test-op"))
        XCTAssertEqual(remaining, 1, "After 4 retries, exactly 1 attempt must remain")
    }

    func testCanRetry_afterFiveRetries_returnsFalse() {
        for _ in 0..<5 {
            tracker.recordRetry(operationId: "test-op")
        }
        XCTAssertFalse(tracker.canRetry(operationId: "test-op"))
        XCTAssertEqual(tracker.recordRetry(operationId: "test-op"), 0,
                       "Recording beyond max must return 0 remaining")
    }

    // MARK: - recordRetry

    func testRecordRetry_returnsRemainingCount() {
        XCTAssertEqual(tracker.recordRetry(operationId: "test-op"), 4)
        XCTAssertEqual(tracker.recordRetry(operationId: "test-op"), 3)
        XCTAssertEqual(tracker.recordRetry(operationId: "test-op"), 2)
        XCTAssertEqual(tracker.recordRetry(operationId: "test-op"), 1)
        XCTAssertEqual(tracker.recordRetry(operationId: "test-op"), 0)
    }

    func testRecordRetry_afterMax_returnsZero() {
        for _ in 0..<5 {
            tracker.recordRetry(operationId: "test-op")
        }
        // Sixth attempt still returns 0
        XCTAssertEqual(tracker.recordRetry(operationId: "test-op"), 0)
        // Seventh attempt must also return 0 (not go negative)
        XCTAssertEqual(tracker.recordRetry(operationId: "test-op"), 0,
                       "Repeated calls beyond max must clamp to 0, not go negative")
    }

    // MARK: - clearRetries

    func testClearRetries_resetsCount() {
        for _ in 0..<5 {
            tracker.recordRetry(operationId: "test-op")
        }
        XCTAssertFalse(tracker.canRetry(operationId: "test-op"))

        tracker.clearRetries(operationId: "test-op")
        XCTAssertTrue(tracker.canRetry(operationId: "test-op"))
    }

    func testClearRetries_onlyAffectsSpecifiedOperation() {
        for _ in 0..<5 {
            tracker.recordRetry(operationId: "test-op-1")
        }
        tracker.recordRetry(operationId: "test-op-2")

        tracker.clearRetries(operationId: "test-op-1")

        XCTAssertTrue(tracker.canRetry(operationId: "test-op-1"))
        // test-op-2 should still have its count
        XCTAssertTrue(tracker.canRetry(operationId: "test-op-2"))
    }

    // MARK: - Independent Operations

    func testSeparateOperations_trackIndependently() {
        for _ in 0..<5 {
            tracker.recordRetry(operationId: "test-op-1")
        }
        XCTAssertFalse(tracker.canRetry(operationId: "test-op-1"))
        XCTAssertTrue(tracker.canRetry(operationId: "test-op-2"))
    }

    // MARK: - Thread Safety

    func testConcurrentAccess_doesNotCrash() {
        let expectation = expectation(description: "Concurrent access completes")
        expectation.expectedFulfillmentCount = 10

        for i in 0..<10 {
            DispatchQueue.global().async {
                let opId = "concurrent-\(i % 3)"
                self.tracker.recordRetry(operationId: opId)
                _ = self.tracker.canRetry(operationId: opId)
                self.tracker.clearRetries(operationId: opId)
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 5.0)

        // After concurrent ops, tracker must remain functional — canRetry must not crash
        let postConcurrencyResult = tracker.canRetry(operationId: "new-op-after-concurrency")
        XCTAssertTrue(postConcurrencyResult, "Fresh operation must still be retryable after concurrent access")

        // Cleanup
        for i in 0..<3 {
            tracker.clearRetries(operationId: "concurrent-\(i)")
        }
    }
}
