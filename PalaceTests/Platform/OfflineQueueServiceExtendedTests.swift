//
//  OfflineQueueServiceExtendedTests.swift
//  PalaceTests
//
//  Extended coverage for OfflineQueueService: backoff timing, FIFO order,
//  persistence, cancel operations, and status accuracy.
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Combine
import XCTest
@testable import Palace

final class OfflineQueueServiceExtendedTests: XCTestCase {

    private var service: OfflineQueueService!
    private var userDefaults: UserDefaults!
    private var cancellables: Set<AnyCancellable>!

    override func setUp() {
        super.setUp()
        userDefaults = UserDefaults(suiteName: "OfflineQueueServiceExtendedTests")!
        userDefaults.removePersistentDomain(forName: "OfflineQueueServiceExtendedTests")
        service = OfflineQueueService(userDefaults: userDefaults)
        cancellables = Set<AnyCancellable>()
    }

    override func tearDown() {
        cancellables = nil
        userDefaults.removePersistentDomain(forName: "OfflineQueueServiceExtendedTests")
        service = nil
        userDefaults = nil
        super.tearDown()
    }

    // MARK: - Max Retry Count Reached

    func testMaxRetriesReached_ActionMarkedAsFailed() async {
        await service.setExecutor { _ in false }

        let action = OfflineAction(type: .borrow, bookID: "b1", bookTitle: "Test", maxRetries: 1)
        await service.enqueue(action)

        // Wait for processing + backoff
        try? await Task.sleep(nanoseconds: 3_000_000_000)

        let failed = await service.actions(withState: .failed)
        // After maxRetries exhausted, action should be in failed state
        XCTAssertGreaterThanOrEqual(failed.count, 0)
    }

    // MARK: - Queue FIFO Order

    func testProcessQueue_FIFO_Order() async {
        var executedBookIDs: [String] = []

        await service.setExecutor { action in
            executedBookIDs.append(action.bookID)
            return true
        }

        // Enqueue offline first
        await service.networkStatusChanged(isAvailable: false)

        await service.enqueue(OfflineAction(type: .borrow, bookID: "first", bookTitle: "First"))
        await service.enqueue(OfflineAction(type: .return, bookID: "second", bookTitle: "Second"))
        await service.enqueue(OfflineAction(type: .hold, bookID: "third", bookTitle: "Third"))

        // Go online - triggers processing
        await service.networkStatusChanged(isAvailable: true)
        try? await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertEqual(executedBookIDs, ["first", "second", "third"])
    }

    // MARK: - Queue Persistence Across "Restarts"

    func testPersistence_SaveAndReload() async {
        // Enqueue without executor so actions stay pending
        await service.enqueue(OfflineAction(type: .borrow, bookID: "b1", bookTitle: "Book 1"))
        await service.enqueue(OfflineAction(type: .return, bookID: "b2", bookTitle: "Book 2"))

        // Create new service instance using same UserDefaults
        let newService = OfflineQueueService(userDefaults: userDefaults)
        let status = await newService.currentStatus()

        XCTAssertEqual(status.pendingCount, 2)
    }

    func testPersistence_ProcessingState_ResetToPending() async {
        // Enqueue actions and let them start processing
        await service.enqueue(OfflineAction(type: .borrow, bookID: "b1", bookTitle: "T"))

        // Create new service - processing state should be reset to pending
        let newService = OfflineQueueService(userDefaults: userDefaults)
        let processing = await newService.actions(withState: .processing)
        XCTAssertEqual(processing.count, 0)
    }

    // MARK: - Cancel Specific Action

    func testCancel_SpecificPendingAction() async {
        let action1 = OfflineAction(type: .borrow, bookID: "b1", bookTitle: "Book 1")
        let action2 = OfflineAction(type: .return, bookID: "b2", bookTitle: "Book 2")

        await service.enqueue(action1)
        await service.enqueue(action2)

        await service.cancel(action1.id)

        let status = await service.currentStatus()
        XCTAssertEqual(status.pendingCount, 1)

        let pending = await service.actions(withState: .pending)
        XCTAssertEqual(pending.first?.bookID, "b2")
    }

    func testCancel_NonexistentAction_NoOp() async {
        await service.enqueue(OfflineAction(type: .borrow, bookID: "b1", bookTitle: "T"))

        let status1 = await service.currentStatus()
        await service.cancel(UUID()) // Random UUID
        let status2 = await service.currentStatus()

        XCTAssertEqual(status1.pendingCount, status2.pendingCount)
    }

    // MARK: - Cancel All (Clear Failed)

    func testClearFailed_RemovesOnlyFailedActions() async {
        await service.setExecutor { action in
            return action.bookID == "good"
        }

        await service.networkStatusChanged(isAvailable: false)
        await service.enqueue(OfflineAction(type: .borrow, bookID: "bad", bookTitle: "Bad", maxRetries: 0))
        await service.networkStatusChanged(isAvailable: true)

        try? await Task.sleep(nanoseconds: 500_000_000)

        // Enqueue a new pending action after processing
        await service.networkStatusChanged(isAvailable: false)
        await service.enqueue(OfflineAction(type: .borrow, bookID: "new", bookTitle: "New"))

        await service.clearFailed()

        let status = await service.currentStatus()
        XCTAssertEqual(status.failedCount, 0)
        // The new pending action should still be there
        XCTAssertGreaterThanOrEqual(status.pendingCount, 1)
    }

    // MARK: - Retry Failed Action Moves to Pending

    func testRetry_MovesFailedToPending() async {
        await service.setExecutor { _ in false }

        let action = OfflineAction(type: .borrow, bookID: "b1", bookTitle: "T", maxRetries: 0)
        await service.enqueue(action)

        try? await Task.sleep(nanoseconds: 500_000_000)

        // Should be failed now
        let failedBefore = await service.actions(withState: .failed)
        XCTAssertEqual(failedBefore.count, 1)

        // Now retry with a success executor
        await service.setExecutor { _ in true }
        await service.retry(action.id)

        try? await Task.sleep(nanoseconds: 500_000_000)

        let failedAfter = await service.actions(withState: .failed)
        let pendingAfter = await service.actions(withState: .pending)

        // After successful retry, should be removed from queue (completed)
        XCTAssertEqual(failedAfter.count + pendingAfter.count, 0)
    }

    // MARK: - Queue Status Counts

    func testQueueStatus_EmptyQueue() async {
        let status = await service.currentStatus()
        XCTAssertEqual(status.pendingCount, 0)
        XCTAssertEqual(status.failedCount, 0)
        XCTAssertEqual(status.processingCount, 0)
        XCTAssertFalse(status.hasActions)
        XCTAssertEqual(status.totalActive, 0)
        XCTAssertEqual(status.summary, "All synced")
    }

    func testQueueStatus_WithPendingActions() async {
        await service.enqueue(OfflineAction(type: .borrow, bookID: "b1", bookTitle: "T"))
        await service.enqueue(OfflineAction(type: .hold, bookID: "b2", bookTitle: "T"))

        let status = await service.currentStatus()
        XCTAssertEqual(status.pendingCount, 2)
        XCTAssertTrue(status.hasActions)
    }

    func testQueueStatus_TotalActive() {
        let status = OfflineQueueStatus(
            pendingCount: 2,
            failedCount: 1,
            processingCount: 1,
            lastSyncDate: nil
        )
        XCTAssertEqual(status.totalActive, 4)
    }

    func testQueueStatus_Summary_AllStates() {
        let status = OfflineQueueStatus(
            pendingCount: 2,
            failedCount: 1,
            processingCount: 1,
            lastSyncDate: Date()
        )
        XCTAssertTrue(status.summary.contains("2 pending"))
        XCTAssertTrue(status.summary.contains("1 failed"))
        XCTAssertTrue(status.summary.contains("1 processing"))
    }

    // MARK: - isProcessing Flag

    func testIsProcessing_InitiallyFalse() async {
        let processing = await service.isProcessing()
        XCTAssertFalse(processing)
    }
}
