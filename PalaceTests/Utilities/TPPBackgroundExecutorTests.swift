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

    /// Simulated work duration
    var workDuration: TimeInterval = 0

    /// Set to true to simulate returning nil from setUpWorkItem
    var returnNilWorkItem = false

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

        if workDuration > 0 {
            Thread.sleep(forTimeInterval: workDuration)
        }
    }
}

// MARK: - Tests

final class TPPBackgroundExecutorTests: XCTestCase {

    func testExecutorCallsSetUpWorkItem() {
        let owner = MockBackgroundWorkOwner()
        let executor = TPPBackgroundExecutor(owner: owner, taskName: "TestTask")

        let expectation = self.expectation(description: "Work dispatched")

        // dispatchBackgroundWork runs on main, then dispatches to background
        executor.dispatchBackgroundWork()

        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
            expectation.fulfill()
        }

        waitForExpectations(timeout: 3.0)
        XCTAssertTrue(owner.setUpWorkItemCalled, "Executor should call setUpWorkItem on owner")
    }

    func testExecutorPerformsBackgroundWork() {
        let owner = MockBackgroundWorkOwner()
        let executor = TPPBackgroundExecutor(owner: owner, taskName: "TestWork")

        let expectation = self.expectation(description: "Background work completed")

        executor.dispatchBackgroundWork()

        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
            expectation.fulfill()
        }

        waitForExpectations(timeout: 3.0)
        XCTAssertTrue(owner.workPerformed, "Executor should call performBackgroundWork on owner")
        XCTAssertEqual(owner.performBackgroundWorkCallCount, 1)
    }

    func testExecutorHandlesNilWorkItem() {
        let owner = MockBackgroundWorkOwner()
        owner.returnNilWorkItem = true
        let executor = TPPBackgroundExecutor(owner: owner, taskName: "NilWork")

        // Should not crash when setUpWorkItem returns nil
        executor.dispatchBackgroundWork()

        let expectation = self.expectation(description: "Executor handled nil")
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
            expectation.fulfill()
        }

        waitForExpectations(timeout: 3.0)
        XCTAssertTrue(owner.setUpWorkItemCalled)
        XCTAssertFalse(owner.workPerformed, "Work should not be performed when work item is nil")
    }

    func testExecutorDoesNotRetainOwner() {
        var owner: MockBackgroundWorkOwner? = MockBackgroundWorkOwner()
        weak var weakOwner = owner
        let executor = TPPBackgroundExecutor(owner: owner!, taskName: "WeakRef")

        // Release strong reference
        owner = nil

        XCTAssertNil(weakOwner, "Executor should hold a weak reference to owner")

        // Should not crash when owner is deallocated
        executor.dispatchBackgroundWork()

        let expectation = self.expectation(description: "No crash")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }
        waitForExpectations(timeout: 2.0)
    }

    func testMultipleDispatches() {
        let owner = MockBackgroundWorkOwner()
        let executor = TPPBackgroundExecutor(owner: owner, taskName: "MultiDispatch")

        executor.dispatchBackgroundWork()
        executor.dispatchBackgroundWork()

        let expectation = self.expectation(description: "Multiple dispatches")
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
            expectation.fulfill()
        }

        waitForExpectations(timeout: 4.0)
        XCTAssertGreaterThanOrEqual(owner.performBackgroundWorkCallCount, 1,
                                     "Should perform work at least once from multiple dispatches")
    }
}
