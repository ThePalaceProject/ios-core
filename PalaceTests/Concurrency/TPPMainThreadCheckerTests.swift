//
//  TPPMainThreadCheckerTests.swift
//  PalaceTests
//
//  Tests for TPPMainThreadRun sync and asyncIfNeeded methods
//

import XCTest
@testable import Palace

@MainActor
final class TPPMainThreadCheckerTests: XCTestCase {

    // MARK: - sync Tests

    func testSync_FromMainThread_ExecutesSynchronously() {
        // We're on the main thread in test context
        // Swift 6: TPPMainThreadRun.sync takes a @Sendable closure, so a captured
        // `var` can't be mutated inside it — box it.
        let executed = LockIsolated<Bool>(false)
        TPPMainThreadRun.sync {
            XCTAssertTrue(Thread.isMainThread)
            executed.value = true
        }
        XCTAssertTrue(executed.value, "Block should execute synchronously on main thread")
    }

    func testSync_FromBackgroundThread_DispatchesToMainThread() {
        let expectation = expectation(description: "Work completes on main thread")

        DispatchQueue.global().async {
            XCTAssertFalse(Thread.isMainThread, "Should start on background thread")
            TPPMainThreadRun.sync {
                XCTAssertTrue(Thread.isMainThread, "Block should run on main thread")
                expectation.fulfill()
            }
        }

        waitForExpectations(timeout: 2.0)
    }

    // MARK: - asyncIfNeeded Tests

    func testAsyncIfNeeded_FromMainThread_ExecutesSynchronously() {
        let executed = LockIsolated<Bool>(false)
        TPPMainThreadRun.asyncIfNeeded {
            executed.value = true
        }
        XCTAssertTrue(executed.value, "On main thread, asyncIfNeeded should execute immediately")
    }

    func testAsyncIfNeeded_FromBackgroundThread_DispatchesAsyncToMain() {
        let expectation = expectation(description: "Work dispatched to main thread")

        DispatchQueue.global().async {
            XCTAssertFalse(Thread.isMainThread)
            TPPMainThreadRun.asyncIfNeeded {
                XCTAssertTrue(Thread.isMainThread, "Block should run on main thread")
                expectation.fulfill()
            }
        }

        waitForExpectations(timeout: 2.0)
    }
}
