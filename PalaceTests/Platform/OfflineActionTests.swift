//
//  OfflineActionTests.swift
//  PalaceTests
//
//  Tests for OfflineAction creation, retry logic, backoff, and Codable.
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

@MainActor
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
        XCTAssertEqual(action.bookTitle, "Return Book")
        XCTAssertEqual(action.state, .pending, "Newly created return action must start in pending state")
        XCTAssertEqual(action.retryCount, 0, "Newly created action must start with zero retries")
    }

    func testHoldAction_Creation() {
        let action = OfflineAction(type: .hold, bookID: "b3", bookTitle: "Hold Book")
        XCTAssertEqual(action.type, .hold)
        XCTAssertEqual(action.bookID, "b3")
        XCTAssertEqual(action.bookTitle, "Hold Book")
        XCTAssertEqual(action.state, .pending, "Newly created hold action must start in pending state")
    }

    func testCancelHoldAction_Creation() {
        let action = OfflineAction(type: .cancelHold, bookID: "b4", bookTitle: "Cancel Book")
        XCTAssertEqual(action.type, .cancelHold)
        XCTAssertEqual(action.bookID, "b4")
        XCTAssertEqual(action.bookTitle, "Cancel Book")
        XCTAssertEqual(action.state, .pending, "Newly created cancelHold action must start in pending state")
    }

    func testCustomMaxRetries() {
        let action = OfflineAction(type: .borrow, bookID: "b1", bookTitle: "T", maxRetries: 10)
        XCTAssertEqual(action.maxRetries, 10)
        XCTAssertNotEqual(action.maxRetries, 3, "Custom maxRetries must differ from the default value of 3")
        XCTAssertTrue(action.maxRetries > 3, "maxRetries of 10 must be greater than the default of 3")
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
        // Incrementing to just under maxRetries must still allow retry
        action.retryCount = 2
        XCTAssertTrue(action.canRetry, "retryCount < maxRetries must keep canRetry true")
    }

    func testCanRetry_FailedWithRetriesExhausted_False() {
        var action = OfflineAction(type: .borrow, bookID: "b1", bookTitle: "T", maxRetries: 3)
        action.state = .failed
        action.retryCount = 3
        XCTAssertFalse(action.canRetry)
        // Verify the boundary: one less must allow retry
        action.retryCount = 2
        XCTAssertTrue(action.canRetry, "retryCount one below maxRetries must still allow retry")
    }

    func testCanRetry_FailedExceedingMaxRetries_False() {
        var action = OfflineAction(type: .borrow, bookID: "b1", bookTitle: "T", maxRetries: 3)
        action.state = .failed
        action.retryCount = 5
        XCTAssertFalse(action.canRetry)
        XCTAssertGreaterThan(action.retryCount, action.maxRetries, "retryCount exceeds maxRetries in this scenario")
    }

    func testCanRetry_PendingState_False() {
        var action = OfflineAction(type: .borrow, bookID: "b1", bookTitle: "T", maxRetries: 3)
        action.state = .pending
        action.retryCount = 0
        XCTAssertFalse(action.canRetry, "Pending actions don't need retry")
        // Even with retries remaining, pending must return false
        action.retryCount = 1
        XCTAssertFalse(action.canRetry, "Pending state must never allow retry regardless of retryCount")
    }

    func testCanRetry_ProcessingState_False() {
        var action = OfflineAction(type: .borrow, bookID: "b1", bookTitle: "T", maxRetries: 3)
        action.state = .processing
        action.retryCount = 0
        XCTAssertFalse(action.canRetry, "Processing actions don't need retry")
        // Even in-flight, must not be retried
        action.retryCount = 1
        XCTAssertFalse(action.canRetry, "Processing state must never allow retry regardless of retryCount")
    }

    func testCanRetry_CompletedState_False() {
        var action = OfflineAction(type: .borrow, bookID: "b1", bookTitle: "T", maxRetries: 3)
        action.state = .completed
        action.retryCount = 0
        XCTAssertFalse(action.canRetry, "Completed actions don't need retry")
        XCTAssertEqual(action.state, .completed, "State must remain completed")
    }

    func testCanRetry_ZeroMaxRetries_AlwaysFalse() {
        var action = OfflineAction(type: .borrow, bookID: "b1", bookTitle: "T", maxRetries: 0)
        action.state = .failed
        action.retryCount = 0
        XCTAssertFalse(action.canRetry)
        // Even if somehow retryCount goes negative, must remain false
        XCTAssertEqual(action.maxRetries, 0, "maxRetries must be 0 in this scenario")
    }

    // MARK: - Exponential Backoff

    func testNextRetryDelay_FirstRetry() {
        var action = OfflineAction(type: .borrow, bookID: "b1", bookTitle: "T")
        action.retryCount = 0
        XCTAssertEqual(action.nextRetryDelay, 1.0, accuracy: 0.001)
        XCTAssertGreaterThan(action.nextRetryDelay, 0, "First retry delay must be positive")
    }

    func testNextRetryDelay_SecondRetry() {
        var action = OfflineAction(type: .borrow, bookID: "b1", bookTitle: "T")
        action.retryCount = 1
        XCTAssertEqual(action.nextRetryDelay, 2.0, accuracy: 0.001)
        // Must double the first retry delay
        action.retryCount = 0
        XCTAssertEqual(action.nextRetryDelay * 2, 2.0, accuracy: 0.001,
                       "Second retry delay must be exactly double the first")
    }

    func testNextRetryDelay_ThirdRetry() {
        var action = OfflineAction(type: .borrow, bookID: "b1", bookTitle: "T")
        action.retryCount = 2
        XCTAssertEqual(action.nextRetryDelay, 4.0, accuracy: 0.001)
        // Must be double the second retry delay
        action.retryCount = 1
        XCTAssertEqual(action.nextRetryDelay * 2, 4.0, accuracy: 0.001,
                       "Third retry delay must be exactly double the second")
    }

    func testNextRetryDelay_FourthRetry() {
        var action = OfflineAction(type: .borrow, bookID: "b1", bookTitle: "T")
        action.retryCount = 3
        XCTAssertEqual(action.nextRetryDelay, 8.0, accuracy: 0.001)
        // Must be double the third retry delay
        action.retryCount = 2
        XCTAssertEqual(action.nextRetryDelay * 2, 8.0, accuracy: 0.001,
                       "Fourth retry delay must be exactly double the third")
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
        // Changing state must still keep equality since ID is unchanged
        copy.state = .failed
        XCTAssertEqual(action, copy, "Equality must be ID-based only, regardless of state changes")
        XCTAssertEqual(action.id, copy.id, "Both actions must share the same UUID")
    }

    func testEquality_DifferentID_NotEqual() {
        let a = OfflineAction(type: .borrow, bookID: "b1", bookTitle: "T")
        let b = OfflineAction(type: .borrow, bookID: "b1", bookTitle: "T")
        XCTAssertNotEqual(a, b, "Different UUIDs should not be equal")
        // All other fields being equal must not override UUID-based inequality
        XCTAssertNotEqual(a.id, b.id, "Each OfflineAction must receive a unique UUID at creation")
    }

    // MARK: - Display Description

    func testDisplayDescription_Borrow() {
        let action = OfflineAction(type: .borrow, bookID: "b1", bookTitle: "Great Gatsby")
        XCTAssertEqual(action.displayDescription, "Borrow \"Great Gatsby\"")
        XCTAssertTrue(action.displayDescription.contains("Great Gatsby"), "Book title must appear in description")
        XCTAssertFalse(action.displayDescription.isEmpty, "Display description must not be empty")
    }

    func testDisplayDescription_Return() {
        let action = OfflineAction(type: .return, bookID: "b1", bookTitle: "Great Gatsby")
        XCTAssertEqual(action.displayDescription, "Return \"Great Gatsby\"")
        XCTAssertNotEqual(action.displayDescription,
                          OfflineAction(type: .borrow, bookID: "b1", bookTitle: "Great Gatsby").displayDescription,
                          "Return and Borrow must produce different descriptions")
    }

    func testDisplayDescription_Hold() {
        let action = OfflineAction(type: .hold, bookID: "b1", bookTitle: "Great Gatsby")
        XCTAssertEqual(action.displayDescription, "Place hold on \"Great Gatsby\"")
        XCTAssertTrue(action.displayDescription.contains("Great Gatsby"), "Book title must appear in hold description")
    }

    func testDisplayDescription_CancelHold() {
        let action = OfflineAction(type: .cancelHold, bookID: "b1", bookTitle: "Great Gatsby")
        XCTAssertEqual(action.displayDescription, "Cancel hold on \"Great Gatsby\"")
        XCTAssertNotEqual(action.displayDescription,
                          OfflineAction(type: .hold, bookID: "b1", bookTitle: "Great Gatsby").displayDescription,
                          "CancelHold and Hold must produce different descriptions")
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
