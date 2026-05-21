//
//  TPPBackgroundExecutorTests.swift
//  PalaceTests
//
//  Tests for TPPBackgroundExecutor: work dispatch, owner lifecycle, and
//  the NYPLBackgroundWorkOwner protocol contract.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

// MARK: - Mock Work Owner

private class MockBackgroundWorkOwner: NSObject, NYPLBackgroundWorkOwner {
    var workPerformed = false
    var setUpWorkItemCalled = false
    var performBackgroundWorkCallCount = 0

    /// Set to true to simulate returning nil from setUpWorkItem
    var returnNilWorkItem = false

    /// Optional expectation fulfilled inside performBackgroundWork. Lets tests
    /// wait on the actual work running rather than racing a fixed sleep
    /// against the background-QoS queue (which CI throttles aggressively).
    var workExpectation: XCTestExpectation?

    func setUpWorkItem(wrapping backgroundWork: @escaping () -> Void) -> (() -> Void)? {
        setUpWorkItemCalled = true

        if returnNilWorkItem {
            return nil
        }

        return {
            backgroundWork()
        }
    }

    func performBackgroundWork() {
        performBackgroundWorkCallCount += 1
        workPerformed = true

        workExpectation?.fulfill()
    }
}

// MARK: - Tests

final class TPPBackgroundExecutorTests: XCTestCase {

    func testExecutorCallsSetUpWorkItem() {
        let owner = MockBackgroundWorkOwner()
        let executor = TPPBackgroundExecutor(owner: owner, taskName: "TestTask")

        // dispatchBackgroundWork runs on main, then dispatches to background.
        // Wait on the real signal — setUpWorkItem being called — rather than
        // a fixed 1s wall-clock delay.
        executor.dispatchBackgroundWork()
        awaitCondition(timeout: 5.0) { owner.setUpWorkItemCalled }

        XCTAssertTrue(owner.setUpWorkItemCalled, "Executor should call setUpWorkItem on owner")
    }

    func testExecutorHandlesNilWorkItem() {
        let owner = MockBackgroundWorkOwner()
        owner.returnNilWorkItem = true
        let executor = TPPBackgroundExecutor(owner: owner, taskName: "NilWork")

        // Should not crash when setUpWorkItem returns nil. Wait on the real
        // signal — setUpWorkItem being called — rather than a fixed 1s delay.
        executor.dispatchBackgroundWork()
        awaitCondition(timeout: 5.0) { owner.setUpWorkItemCalled }

        XCTAssertTrue(owner.setUpWorkItemCalled)
        XCTAssertFalse(owner.workPerformed, "Work should not be performed when work item is nil")
    }

    func testExecutorDoesNotRetainOwner() {
        // Construct the executor inside a do-block so the local `owner` is
        // released as soon as we exit. Capture `weakOwner` from the same scope
        // so the executor's weak reference is what holds the owner alive (or
        // not — which is the assertion).
        let executor: TPPBackgroundExecutor
        weak var weakOwner: MockBackgroundWorkOwner?
        do {
            let owner = MockBackgroundWorkOwner()
            weakOwner = owner
            executor = TPPBackgroundExecutor(owner: owner, taskName: "WeakRef")
            // owner goes out of scope at the end of this do-block
        }

        XCTAssertNil(weakOwner, "Executor should hold a weak reference to owner")

        // Should not crash when owner is deallocated. dispatchBackgroundWork
        // schedules the startBackground closure on .main; drain the main queue
        // so the (no-owner) path fires before we exit the test. Reaching the
        // next line without an exception IS the assertion.
        executor.dispatchBackgroundWork()
        drainMainQueue()
    }

}
