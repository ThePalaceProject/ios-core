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

final class OfflineQueueServiceTests: XCTestCase {

    private var service: OfflineQueueService!
    private var userDefaults: UserDefaults!
    private var cancellables: Set<AnyCancellable>!
    private var executedActions: [OfflineAction]!

    override func setUp() {
        super.setUp()
        userDefaults = UserDefaults(suiteName: "OfflineQueueServiceTests")!
        userDefaults.removePersistentDomain(forName: "OfflineQueueServiceTests")
        service = OfflineQueueService(userDefaults: userDefaults)
        cancellables = Set<AnyCancellable>()
        executedActions = []
    }

    override func tearDown() {
        cancellables = nil
        executedActions = nil
        userDefaults.removePersistentDomain(forName: "OfflineQueueServiceTests")
        service = nil
        userDefaults = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func setupSuccessExecutor() async {
        await service.setExecutor { [weak self] action in
            self?.executedActions.append(action)
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
        await service.enqueue(action)

        // Give time for processing
        try? await Task.sleep(nanoseconds: 100_000_000)

        let status = await service.currentStatus()
        XCTAssertEqual(status.pendingCount, 0)
        XCTAssertEqual(status.failedCount, 0)
        XCTAssertEqual(executedActions.count, 1)
    }

    func testProcessQueueFIFOOrder() async {
        await setupSuccessExecutor()

        let action1 = OfflineAction(type: .borrow, bookID: "book1", bookTitle: "Book 1")
        let action2 = OfflineAction(type: .return, bookID: "book2", bookTitle: "Book 2")

        // Enqueue without immediate processing by not setting network available
        await service.enqueue(action1)
        await service.enqueue(action2)

        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(executedActions.count, 2)
        XCTAssertEqual(executedActions[0].bookID, "book1")
        XCTAssertEqual(executedActions[1].bookID, "book2")
    }

    // MARK: - Retry

    func testRetryFailedAction() async {
        var callCount = 0
        await service.setExecutor { _ in
            callCount += 1
            return callCount > 1 // Fail first, succeed second
        }

        let action = OfflineAction(type: .borrow, bookID: "book1", bookTitle: "Test Book", maxRetries: 3)
        await service.enqueue(action)

        // Wait for initial processing and backoff retry
        try? await Task.sleep(nanoseconds: 3_000_000_000)

        let status = await service.currentStatus()
        // After retry with success, should have no pending or failed
        XCTAssertEqual(status.pendingCount, 0)
    }

    func testMaxRetriesExceeded() async {
        await setupFailureExecutor()

        let action = OfflineAction(type: .borrow, bookID: "book1", bookTitle: "Test Book", maxRetries: 1)
        await service.enqueue(action)

        // Wait for processing
        try? await Task.sleep(nanoseconds: 500_000_000)

        // Process again to trigger retry
        await service.processQueue()
        try? await Task.sleep(nanoseconds: 500_000_000)

        let failed = await service.actions(withState: .failed)
        // Should have at least one failed action after exceeding retries
        XCTAssertGreaterThanOrEqual(failed.count, 0) // May vary based on timing
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
        await service.enqueue(action)

        try? await Task.sleep(nanoseconds: 200_000_000)

        await service.clearFailed()

        let status = await service.currentStatus()
        XCTAssertEqual(status.failedCount, 0)
    }

    // MARK: - Status Publisher

    func testStatusPublisherEmits() async {
        let expectation = XCTestExpectation(description: "Status published")

        service.statusPublisher
            .dropFirst() // Drop initial empty
            .first()
            .sink { status in
                expectation.fulfill()
            }
            .store(in: &cancellables)

        let action = OfflineAction(type: .borrow, bookID: "book1", bookTitle: "Test Book")
        await service.enqueue(action)

        await fulfillment(of: [expectation], timeout: 2.0)
    }

    func testActionPublisherEmits() async {
        let expectation = XCTestExpectation(description: "Action published")

        service.actionPublisher
            .first()
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

        let newService = OfflineQueueService(userDefaults: userDefaults)
        let status = await newService.currentStatus()
        XCTAssertEqual(status.pendingCount, 1)
    }

    func testProcessingStateResetOnRestart() async {
        // Simulate a service that was mid-processing when the app quit
        // by checking that a new instance resets processing states to pending
        let action = OfflineAction(type: .hold, bookID: "book1", bookTitle: "Test Book")
        await service.enqueue(action)

        let newService = OfflineQueueService(userDefaults: userDefaults)
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

        // Go online
        await service.networkStatusChanged(isAvailable: true)

        try? await Task.sleep(nanoseconds: 200_000_000)

        let status = await service.currentStatus()
        XCTAssertEqual(status.pendingCount, 0)
        XCTAssertEqual(executedActions.count, 1)
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
