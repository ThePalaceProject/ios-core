//
//  TPPMainThreadCheckerTests.swift
//  PalaceTests
//
//  Tests for TPPMainThreadRun sync and asyncIfNeeded methods
//

import XCTest
@testable import Palace

final class TPPMainThreadCheckerTests: XCTestCase {

    // MARK: - sync Tests

    func testSync_FromMainThread_ExecutesSynchronously() {
        // We're on the main thread in test context
        var executed = false
        TPPMainThreadRun.sync {
            XCTAssertTrue(Thread.isMainThread)
            executed = true
        }
        XCTAssertTrue(executed, "Block should execute synchronously on main thread")
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
        var executed = false
        TPPMainThreadRun.asyncIfNeeded {
            executed = true
        }
        XCTAssertTrue(executed, "On main thread, asyncIfNeeded should execute immediately")
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
