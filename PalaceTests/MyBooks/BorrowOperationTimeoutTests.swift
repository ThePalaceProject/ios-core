//
//  BorrowOperationTimeoutTests.swift
//  PalaceTests
//
//  Regression tests for F-014 — the "borrow stuck with Cancel-only UI"
//  bug. The wrapper `BorrowOperation.withTimeout(seconds:operation:)`
//  bounds the slow-server case by racing the operation against a deadline;
//  on expiry we throw `PalaceError.network(.timeout)` so the existing
//  showBorrowError path surfaces a user-actionable alert instead of
//  leaving isBorrowProcessing=true indefinitely.
//

import XCTest
@testable import Palace

@MainActor
final class BorrowOperationTimeoutTests: XCTestCase {

    /// A fast operation must return its value, NOT the timeout error. If the
    /// timeout-task ever wins a race against a sub-second operation, every
    /// real borrow would fail spuriously.
    func testWithTimeout_FastOperation_ReturnsValue() async throws {
        let result = try await BorrowOperation.withTimeout(seconds: 1.0) {
            return "borrowed-book-fake"
        }
        XCTAssertEqual(result, "borrowed-book-fake",
            "Operation that completes well within the deadline must return its value. " +
            "Mutating the wrapper to prefer the timeout branch would break every fast borrow.")
    }

    /// A slow operation must throw PalaceError.network(.timeout). Without
    /// this, the half-sheet hangs on isBorrowProcessing=true indefinitely
    /// (the BUG_FINDINGS_2026_05_12 "Cancel-only UI" symptom).
    func testWithTimeout_SlowOperation_ThrowsTimeoutError() async {
        do {
            _ = try await BorrowOperation.withTimeout(seconds: 0.1) {
                try await Task.sleep(nanoseconds: 5_000_000_000) // 5s
                return "should-never-reach-here"
            }
            XCTFail("withTimeout must throw after the deadline elapses, but the slow operation returned a value")
        } catch let error as PalaceError {
            guard case .network(let networkError) = error else {
                XCTFail("Expected PalaceError.network(.timeout), got: \(error)")
                return
            }
            XCTAssertEqual(networkError, .timeout,
                "Specifically must throw .timeout — not .cancelled, not .unknown — so showBorrowError surfaces the correct alert copy and Retry affordance.")
        } catch {
            XCTFail("Expected PalaceError, got: \(type(of: error)): \(error)")
        }
    }

    /// A throwing operation that fails before the deadline must propagate
    /// its original error, not be masked by the timeout case. Otherwise
    /// genuine HTTP 401/403/404 borrow errors would silently morph into
    /// "request timed out" and confuse users.
    func testWithTimeout_OperationThrowsBeforeDeadline_PropagatesOriginalError() async {
        struct UpstreamError: Error, Equatable {}
        do {
            _ = try await BorrowOperation.withTimeout(seconds: 5.0) {
                throw UpstreamError()
            }
            XCTFail("Expected the upstream error to propagate")
        } catch is UpstreamError {
            // expected — the original error from the operation must reach the caller
        } catch {
            XCTFail("Expected UpstreamError to propagate, got: \(type(of: error)): \(error)")
        }
    }
}
