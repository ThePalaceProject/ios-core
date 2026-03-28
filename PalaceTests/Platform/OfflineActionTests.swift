//
//  OfflineActionTests.swift
//  PalaceTests
//
//  Tests for OfflineAction creation, retry logic, backoff, and Codable.
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class OfflineActionTests: XCTestCase {

    // MARK: - Action Creation

    func testBorrowAction_Creation() {
        let action = OfflineAction(type: .borrow, bookID: "b1", bookTitle: "My Book")
        XCTAssertEqual(action.type, .borrow)
        XCTAssertEqual(action.bookID, "b1")
        XCTAssertEqual(action.bookTitle, "My Book")
        XCTAssertEqual(action.state, .pending)
        XCTAssertEqual(action.retryCount, 0)
        XCTAssertEqual(action.maxRetries, 3) // default
        XCTAssertNil(action.lastAttemptAt)
        XCTAssertNil(action.errorMessage)
    }

    func testReturnAction_Creation() {
        let action = OfflineAction(type: .return, bookID: "b2", bookTitle: "Return Book")
        XCTAssertEqual(action.type, .return)
        XCTAssertEqual(action.bookID, "b2")
    }

    func testHoldAction_Creation() {
        let action = OfflineAction(type: .hold, bookID: "b3", bookTitle: "Hold Book")
        XCTAssertEqual(action.type, .hold)
    }

    func testCancelHoldAction_Creation() {
        let action = OfflineAction(type: .cancelHold, bookID: "b4", bookTitle: "Cancel Book")
        XCTAssertEqual(action.type, .cancelHold)
    }

    func testCustomMaxRetries() {
        let action = OfflineAction(type: .borrow, bookID: "b1", bookTitle: "T", maxRetries: 10)
        XCTAssertEqual(action.maxRetries, 10)
    }

    // MARK: - Retry Count Increment

    func testRetryCount_IncrementWorks() {
        var action = OfflineAction(type: .borrow, bookID: "b1", bookTitle: "T")
        XCTAssertEqual(action.retryCount, 0)
        action.retryCount += 1
        XCTAssertEqual(action.retryCount, 1)
        action.retryCount += 1
        XCTAssertEqual(action.retryCount, 2)
    }

    // MARK: - shouldRetry (canRetry)

    func testCanRetry_FailedWithRetriesRemaining_True() {
        var action = OfflineAction(type: .borrow, bookID: "b1", bookTitle: "T", maxRetries: 3)
        action.state = .failed
        action.retryCount = 0
        XCTAssertTrue(action.canRetry)
    }

    func testCanRetry_FailedWithRetriesExhausted_False() {
        var action = OfflineAction(type: .borrow, bookID: "b1", bookTitle: "T", maxRetries: 3)
        action.state = .failed
        action.retryCount = 3
        XCTAssertFalse(action.canRetry)
    }

    func testCanRetry_FailedExceedingMaxRetries_False() {
        var action = OfflineAction(type: .borrow, bookID: "b1", bookTitle: "T", maxRetries: 3)
        action.state = .failed
        action.retryCount = 5
        XCTAssertFalse(action.canRetry)
    }

    func testCanRetry_PendingState_False() {
        var action = OfflineAction(type: .borrow, bookID: "b1", bookTitle: "T", maxRetries: 3)
        action.state = .pending
        action.retryCount = 0
        XCTAssertFalse(action.canRetry, "Pending actions don't need retry")
    }

    func testCanRetry_ProcessingState_False() {
        var action = OfflineAction(type: .borrow, bookID: "b1", bookTitle: "T", maxRetries: 3)
        action.state = .processing
        action.retryCount = 0
        XCTAssertFalse(action.canRetry, "Processing actions don't need retry")
    }

    func testCanRetry_CompletedState_False() {
        var action = OfflineAction(type: .borrow, bookID: "b1", bookTitle: "T", maxRetries: 3)
        action.state = .completed
        action.retryCount = 0
        XCTAssertFalse(action.canRetry, "Completed actions don't need retry")
    }

    func testCanRetry_ZeroMaxRetries_AlwaysFalse() {
        var action = OfflineAction(type: .borrow, bookID: "b1", bookTitle: "T", maxRetries: 0)
        action.state = .failed
        action.retryCount = 0
        XCTAssertFalse(action.canRetry)
    }

    // MARK: - Exponential Backoff

    func testNextRetryDelay_FirstRetry() {
        var action = OfflineAction(type: .borrow, bookID: "b1", bookTitle: "T")
        action.retryCount = 0
        XCTAssertEqual(action.nextRetryDelay, 1.0, accuracy: 0.001)
    }

    func testNextRetryDelay_SecondRetry() {
        var action = OfflineAction(type: .borrow, bookID: "b1", bookTitle: "T")
        action.retryCount = 1
        XCTAssertEqual(action.nextRetryDelay, 2.0, accuracy: 0.001)
    }

    func testNextRetryDelay_ThirdRetry() {
        var action = OfflineAction(type: .borrow, bookID: "b1", bookTitle: "T")
        action.retryCount = 2
        XCTAssertEqual(action.nextRetryDelay, 4.0, accuracy: 0.001)
    }

    func testNextRetryDelay_FourthRetry() {
        var action = OfflineAction(type: .borrow, bookID: "b1", bookTitle: "T")
        action.retryCount = 3
        XCTAssertEqual(action.nextRetryDelay, 8.0, accuracy: 0.001)
    }

    func testNextRetryDelay_GrowsExponentially() {
        var action = OfflineAction(type: .borrow, bookID: "b1", bookTitle: "T")

        var delays: [TimeInterval] = []
        for i in 0..<5 {
            action.retryCount = i
            delays.append(action.nextRetryDelay)
        }

        // Each delay should be double the previous
        for i in 1..<delays.count {
            XCTAssertEqual(delays[i], delays[i - 1] * 2, accuracy: 0.001)
        }
    }

    // MARK: - Codable Round-Trip

    func testCodableRoundTrip_PendingAction() throws {
        let original = OfflineAction(type: .borrow, bookID: "b1", bookTitle: "Test Book")

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(OfflineAction.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.type, original.type)
        XCTAssertEqual(decoded.bookID, original.bookID)
        XCTAssertEqual(decoded.bookTitle, original.bookTitle)
        XCTAssertEqual(decoded.state, .pending)
        XCTAssertEqual(decoded.retryCount, 0)
        XCTAssertEqual(decoded.maxRetries, 3)
    }

    func testCodableRoundTrip_FailedAction() throws {
        var original = OfflineAction(type: .return, bookID: "b2", bookTitle: "Failed Book", maxRetries: 5)
        original.state = .failed
        original.retryCount = 2
        original.lastAttemptAt = Date()
        original.errorMessage = "Network error"

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(OfflineAction.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.state, .failed)
        XCTAssertEqual(decoded.retryCount, 2)
        XCTAssertEqual(decoded.errorMessage, "Network error")
        XCTAssertNotNil(decoded.lastAttemptAt)
    }

    func testCodableRoundTrip_AllActionTypes() throws {
        let types: [OfflineActionType] = [.borrow, .return, .hold, .cancelHold]

        for actionType in types {
            let original = OfflineAction(type: actionType, bookID: "b1", bookTitle: "T")
            let data = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(OfflineAction.self, from: data)
            XCTAssertEqual(decoded.type, actionType)
        }
    }

    // MARK: - Equality

    func testEquality_SameID_Equal() {
        let action = OfflineAction(type: .borrow, bookID: "b1", bookTitle: "T")
        var copy = action
        copy.retryCount = 5 // Different retry count but same ID
        XCTAssertEqual(action, copy, "Equality is based on ID only")
    }

    func testEquality_DifferentID_NotEqual() {
        let a = OfflineAction(type: .borrow, bookID: "b1", bookTitle: "T")
        let b = OfflineAction(type: .borrow, bookID: "b1", bookTitle: "T")
        XCTAssertNotEqual(a, b, "Different UUIDs should not be equal")
    }

    // MARK: - Display Description

    func testDisplayDescription_Borrow() {
        let action = OfflineAction(type: .borrow, bookID: "b1", bookTitle: "Great Gatsby")
        XCTAssertEqual(action.displayDescription, "Borrow \"Great Gatsby\"")
    }

    func testDisplayDescription_Return() {
        let action = OfflineAction(type: .return, bookID: "b1", bookTitle: "Great Gatsby")
        XCTAssertEqual(action.displayDescription, "Return \"Great Gatsby\"")
    }

    func testDisplayDescription_Hold() {
        let action = OfflineAction(type: .hold, bookID: "b1", bookTitle: "Great Gatsby")
        XCTAssertEqual(action.displayDescription, "Place hold on \"Great Gatsby\"")
    }

    func testDisplayDescription_CancelHold() {
        let action = OfflineAction(type: .cancelHold, bookID: "b1", bookTitle: "Great Gatsby")
        XCTAssertEqual(action.displayDescription, "Cancel hold on \"Great Gatsby\"")
    }

    // MARK: - OfflineActionType

    func testActionType_CodableRoundTrip() throws {
        for actionType in [OfflineActionType.borrow, .return, .hold, .cancelHold] {
            let data = try JSONEncoder().encode(actionType)
            let decoded = try JSONDecoder().decode(OfflineActionType.self, from: data)
            XCTAssertEqual(decoded, actionType)
        }
    }

    // MARK: - OfflineActionState

    func testActionState_CodableRoundTrip() throws {
        for state in [OfflineActionState.pending, .processing, .failed, .completed] {
            let data = try JSONEncoder().encode(state)
            let decoded = try JSONDecoder().decode(OfflineActionState.self, from: data)
            XCTAssertEqual(decoded, state)
        }
    }
}
