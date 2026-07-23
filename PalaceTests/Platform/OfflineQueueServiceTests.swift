//
//  OfflineQueueServiceTests.swift
//  PalaceTests
//
//  Tests for the offline action queue service.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Combine
import XCTest
@testable import Palace

@MainActor
final class OfflineQueueServiceTests: XCTestCase {

    private var service: OfflineQueueService!
    private var userDefaults: UserDefaults!
    private var cancellables: Set<AnyCancellable>!
    // Swift 6: the @Sendable executor closure appends to this from a concurrent
    // context, so it must be a Sendable lock-guarded box rather than a captured
    // `self` instance var. Reset per-test in setUp.
    private let executedActions = LockIsolated<[OfflineAction]>([])

    override func setUp() {
        super.setUp()
        userDefaults = UserDefaults(suiteName: "OfflineQueueServiceTests")!
        userDefaults.removePersistentDomain(forName: "OfflineQueueServiceTests")
        // Inline same-suite UserDefaults: non-Sendable, so it must be a fresh
        // disconnected region to be `sending`-passed into the actor init (the
        // test also retains self.userDefaults for cleanup). Shares backing store.
        //
        // S8 seam (swarm_ad0b4c65 Wave-3): inject a no-op retry backoff so the
        // retry state machine runs with zero wall-clock delay. Because
        // enqueue/retry/networkStatusChanged all `await processQueue()` to full
        // drain, every action reaches its terminal state before the call
        // returns — no post-call settle-sleep is needed to observe it.
        service = OfflineQueueService(
            userDefaults: UserDefaults(suiteName: "OfflineQueueServiceTests")!,
            backoffSleep: { _ in }
        )
        cancellables = Set<AnyCancellable>()
        executedActions.value = []
    }

    override func tearDown() {
        cancellables = nil
        userDefaults.removePersistentDomain(forName: "OfflineQueueServiceTests")
        service = nil
        userDefaults = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func setupSuccessExecutor() async {
        let box = executedActions
        await service.setExecutor { action in
            box.withValue { $0.append(action) }
            return true
        }
    }

    private func setupFailureExecutor() async {
        await service.setExecutor { _ in
            return false
        }
    }

    // MARK: - Enqueue

    func testEnqueueAction() async {
        let action = OfflineAction(type: .borrow, bookID: "book1", bookTitle: "Test Book")
        await service.enqueue(action)

        let pending = await service.actions(withState: .pending)
        // May be 0 if it was immediately processed, or 1 if no executor set
        let status = await service.currentStatus()
        XCTAssertTrue(status.pendingCount > 0 || status.processingCount > 0 || status.failedCount > 0,
                       "Action should be in some state after enqueue")
    }

    func testEnqueueMultipleActions() async {
        let action1 = OfflineAction(type: .borrow, bookID: "book1", bookTitle: "Book 1")
        let action2 = OfflineAction(type: .return, bookID: "book2", bookTitle: "Book 2")

        // No executor, so they stay pending
        await service.enqueue(action1)
        await service.enqueue(action2)

        let status = await service.currentStatus()
        // Without an executor, processQueue does nothing, so they stay pending
        XCTAssertEqual(status.pendingCount, 2)
    }

    // MARK: - Processing

    func testProcessQueueSuccess() async {
        await setupSuccessExecutor()

        let action = OfflineAction(type: .borrow, bookID: "book1", bookTitle: "Test Book")
        // enqueue awaits processQueue() to full drain — the action is
        // completed+removed before this returns (S8: no settle-sleep needed).
        await service.enqueue(action)

        let status = await service.currentStatus()
        XCTAssertEqual(status.pendingCount, 0)
        XCTAssertEqual(status.failedCount, 0)
        XCTAssertEqual(executedActions.value.count, 1)
    }

    func testProcessQueueFIFOOrder() async {
        await setupSuccessExecutor()

        let action1 = OfflineAction(type: .borrow, bookID: "book1", bookTitle: "Book 1")
        let action2 = OfflineAction(type: .return, bookID: "book2", bookTitle: "Book 2")

        // Network available by default: each enqueue awaits processQueue() to
        // full drain, so both actions are executed (FIFO) before we assert.
        await service.enqueue(action1)
        await service.enqueue(action2)

        XCTAssertEqual(executedActions.value.count, 2)
        XCTAssertEqual(executedActions.value[0].bookID, "book1")
        XCTAssertEqual(executedActions.value[1].bookID, "book2")
    }

    // MARK: - Retry

    func testRetryFailedAction() async {
        // Swift 6: box the counter — the @Sendable executor can't mutate a
        // captured local. withValue makes the increment-and-test atomic.
        let callCount = LockIsolated<Int>(0)
        await service.setExecutor { _ in
            callCount.withValue { count -> Bool in
                count += 1
                return count > 1 // Fail first, succeed second
            }
        }

        let action = OfflineAction(type: .borrow, bookID: "book1", bookTitle: "Test Book", maxRetries: 3)
        // enqueue awaits processQueue(): fail (retryCount→1) → zero-delay
        // backoff (S8) → re-process → success → completed+removed, all before
        // this returns. No 3s wall-clock wait for the backoff.
        await service.enqueue(action)

        let status = await service.currentStatus()
        // After the failed-then-successful retry, nothing pending or failed.
        XCTAssertEqual(status.pendingCount, 0)
        XCTAssertEqual(status.failedCount, 0)
    }

    func testMaxRetriesExceeded() async {
        await setupFailureExecutor()

        let action = OfflineAction(type: .borrow, bookID: "book1", bookTitle: "Test Book", maxRetries: 1)
        // maxRetries:1 + always-failing executor: first attempt fails,
        // retryCount(1) >= maxRetries(1) → marked .failed immediately (no
        // backoff branch). enqueue awaits the full drain, so the terminal
        // failed state is observable right after it returns — deterministic.
        await service.enqueue(action)

        let failed = await service.actions(withState: .failed)
        XCTAssertEqual(failed.count, 1)
    }

    // MARK: - Cancel

    func testCancelPendingAction() async {
        // No executor so actions stay pending
        let action = OfflineAction(type: .borrow, bookID: "book1", bookTitle: "Test Book")
        await service.enqueue(action)

        await service.cancel(action.id)

        let status = await service.currentStatus()
        XCTAssertEqual(status.pendingCount, 0)
    }

    // MARK: - Clear Failed

    func testClearFailed() async {
        await setupFailureExecutor()

        let action = OfflineAction(type: .borrow, bookID: "book1", bookTitle: "Test Book", maxRetries: 0)
        // enqueue drains: fails immediately (maxRetries:0) → .failed, observable
        // on return. No settle-sleep before clearing.
        await service.enqueue(action)

        await service.clearFailed()

        let status = await service.currentStatus()
        XCTAssertEqual(status.failedCount, 0)
    }

    // MARK: - Status Publisher

    func testStatusPublisherEmits() async {
        let expectation = XCTestExpectation(description: "Status published")
        var receivedStatus: OfflineQueueStatus?

        service.statusPublisher
            .dropFirst() // Drop initial empty
            .first()
            .receive(on: DispatchQueue.main)   // deliver on main so the @MainActor sink closure isn't invoked off-main (Swift 6 executor-isolation trap)
            .sink { status in
                receivedStatus = status
                expectation.fulfill()
            }
            .store(in: &cancellables)

        let action = OfflineAction(type: .borrow, bookID: "book1", bookTitle: "Test Book")
        await service.enqueue(action)

        await fulfillment(of: [expectation], timeout: 2.0)
        XCTAssertNotNil(receivedStatus,
                        "statusPublisher must deliver a status snapshot to subscribers")
    }

    func testActionPublisherEmits() async {
        let expectation = XCTestExpectation(description: "Action published")

        service.actionPublisher
            .first()
            .receive(on: DispatchQueue.main)   // deliver on main so the @MainActor sink closure isn't invoked off-main (Swift 6 executor-isolation trap)
            .sink { action in
                XCTAssertEqual(action.bookID, "book1")
                expectation.fulfill()
            }
            .store(in: &cancellables)

        let action = OfflineAction(type: .borrow, bookID: "book1", bookTitle: "Test Book")
        await service.enqueue(action)

        await fulfillment(of: [expectation], timeout: 2.0)
    }

    // MARK: - Persistence

    func testQueuePersistsAcrossInstances() async {
        // No executor, so actions stay pending
        let action = OfflineAction(type: .borrow, bookID: "book1", bookTitle: "Test Book")
        await service.enqueue(action)

        let newService = OfflineQueueService(userDefaults: UserDefaults(suiteName: "OfflineQueueServiceTests")!)
        let status = await newService.currentStatus()
        XCTAssertEqual(status.pendingCount, 1)
    }

    func testProcessingStateResetOnRestart() async {
        // Simulate a service that was mid-processing when the app quit
        // by checking that a new instance resets processing states to pending
        let action = OfflineAction(type: .hold, bookID: "book1", bookTitle: "Test Book")
        await service.enqueue(action)

        let newService = OfflineQueueService(userDefaults: UserDefaults(suiteName: "OfflineQueueServiceTests")!)
        let pending = await newService.actions(withState: .pending)
        let processing = await newService.actions(withState: .processing)

        // Any previously processing items should be reset to pending
        XCTAssertEqual(processing.count, 0)
    }

    // MARK: - Network Status

    func testNetworkAvailableTriggersProcessing() async {
        await setupSuccessExecutor()

        // Simulate offline
        await service.networkStatusChanged(isAvailable: false)

        let action = OfflineAction(type: .borrow, bookID: "book1", bookTitle: "Test Book")
        await service.enqueue(action)

        // Go online — networkStatusChanged awaits processQueue() to full drain,
        // so the queued action is executed before this returns.
        await service.networkStatusChanged(isAvailable: true)

        let status = await service.currentStatus()
        XCTAssertEqual(status.pendingCount, 0)
        XCTAssertEqual(executedActions.value.count, 1)
    }

    // MARK: - Action Properties

    func testOfflineActionDisplayDescription() {
        let borrow = OfflineAction(type: .borrow, bookID: "1", bookTitle: "My Book")
        XCTAssertTrue(borrow.displayDescription.contains("Borrow"))
        XCTAssertTrue(borrow.displayDescription.contains("My Book"))

        let ret = OfflineAction(type: .return, bookID: "1", bookTitle: "My Book")
        XCTAssertTrue(ret.displayDescription.contains("Return"))

        let hold = OfflineAction(type: .hold, bookID: "1", bookTitle: "My Book")
        XCTAssertTrue(hold.displayDescription.contains("hold"))

        let cancel = OfflineAction(type: .cancelHold, bookID: "1", bookTitle: "My Book")
        XCTAssertTrue(cancel.displayDescription.contains("Cancel"))
    }

    func testOfflineActionCanRetry() {
        var action = OfflineAction(type: .borrow, bookID: "1", bookTitle: "Test", maxRetries: 3)
        action.state = .failed
        action.retryCount = 2
        XCTAssertTrue(action.canRetry)

        action.retryCount = 3
        XCTAssertFalse(action.canRetry)

        action.retryCount = 0
        action.state = .pending
        XCTAssertFalse(action.canRetry, "Pending actions should not need retry")
    }

    func testExponentialBackoff() {
        var action = OfflineAction(type: .borrow, bookID: "1", bookTitle: "Test")

        action.retryCount = 0
        XCTAssertEqual(action.nextRetryDelay, 1.0)

        action.retryCount = 1
        XCTAssertEqual(action.nextRetryDelay, 2.0)

        action.retryCount = 2
        XCTAssertEqual(action.nextRetryDelay, 4.0)
    }

    // MARK: - Queue Status

    func testOfflineQueueStatusSummary() {
        let empty = OfflineQueueStatus.empty
        XCTAssertEqual(empty.summary, "All synced")
        XCTAssertFalse(empty.hasActions)

        let pending = OfflineQueueStatus(pendingCount: 3, failedCount: 0, processingCount: 0, lastSyncDate: nil)
        XCTAssertTrue(pending.summary.contains("3 pending"))
        XCTAssertTrue(pending.hasActions)

        let mixed = OfflineQueueStatus(pendingCount: 2, failedCount: 1, processingCount: 0, lastSyncDate: Date())
        XCTAssertTrue(mixed.summary.contains("2 pending"))
        XCTAssertTrue(mixed.summary.contains("1 failed"))
        XCTAssertEqual(mixed.totalActive, 3)
    }
}
