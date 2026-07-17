//
//  DownloadErrorRecoveryTests.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

@MainActor
final class DownloadErrorRecoveryPolicyTests: XCTestCase {

    // MARK: - Retry Policy Presets

    func testDefaultPolicy_hasReasonableDefaults() {
        let policy = DownloadErrorRecovery.RetryPolicy.default
        XCTAssertGreaterThan(policy.maxAttempts, 0)
        XCTAssertGreaterThan(policy.baseDelay, 0)
        XCTAssertGreaterThanOrEqual(policy.maxDelay, policy.baseDelay)
        XCTAssertGreaterThan(policy.overallTimeout, 0)
    }

    func testPolicyPresets_areOrderedByAggressiveness() {
        let aggressive = DownloadErrorRecovery.RetryPolicy.aggressive
        let defaultPolicy = DownloadErrorRecovery.RetryPolicy.default
        let conservative = DownloadErrorRecovery.RetryPolicy.conservative
        let borrow = DownloadErrorRecovery.RetryPolicy.borrowOperation

        XCTAssertGreaterThanOrEqual(aggressive.maxAttempts, defaultPolicy.maxAttempts,
                                    "aggressive preset should retry at least as often as default")
        XCTAssertLessThanOrEqual(conservative.maxAttempts, aggressive.maxAttempts,
                                 "conservative preset must not retry more than aggressive")
        XCTAssertGreaterThan(borrow.maxAttempts, 0,
                             "borrowOperation preset must retry at least once")
    }

    // MARK: - borrowOperation Retry Classification

    func testBorrowPolicy_retriesOnAllTransientErrors() {
        let policy = DownloadErrorRecovery.RetryPolicy.borrowOperation

        XCTAssertTrue(policy.shouldRetry(PalaceError.bookRegistry(.bookNotFound)),
                      "retry on 'no active loan' (bookNotFound is the OPDS signal for it)")
        XCTAssertTrue(policy.shouldRetry(PalaceError.network(.timeout)),
                      "retry on PalaceError timeout")
        XCTAssertTrue(policy.shouldRetry(PalaceError.network(.noConnection)),
                      "retry on no-connection")
        XCTAssertTrue(policy.shouldRetry(NSError(domain: NSURLErrorDomain,
                                                  code: NSURLErrorTimedOut,
                                                  userInfo: nil)),
                      "retry on raw NSURLError timeout (untyped error path)")
    }

    func testBorrowPolicy_doesNotRetryOnFatalErrors() {
        let policy = DownloadErrorRecovery.RetryPolicy.borrowOperation

        XCTAssertFalse(policy.shouldRetry(PalaceError.network(.unauthorized)),
                       "do not retry on unauthorized — credentials are stale, retrying just burns attempts")
        XCTAssertFalse(policy.shouldRetry(PalaceError.download(.invalidLicense)),
                       "do not retry on invalid license — DRM-level failure, retry won't help")
        XCTAssertFalse(policy.shouldRetry(NSError(domain: "HTTPErrorDomain",
                                                   code: 500,
                                                   userInfo: nil)),
                       "do not retry on generic HTTP error — handled upstream with user-visible alert")
    }

    func testBorrowPolicy_recoversAfterNoActiveLoan() async throws {
        let recovery = DownloadErrorRecovery()
        // Boxed: the executeWithRetry operation closure is @Sendable, so
        // mutating a captured var there is a Swift 6 error (LockIsolated).
        let attempts = LockIsolated(0)

        let result = try await recovery.executeWithRetry(
            policy: DownloadErrorRecovery.RetryPolicy(
                maxAttempts: 3,
                baseDelay: 0.01,
                maxDelay: 0.05,
                overallTimeout: 10,
                shouldRetry: DownloadErrorRecovery.RetryPolicy.borrowOperation.shouldRetry
            )
        ) {
            let n = attempts.withValue { $0 += 1; return $0 }
            if n < 2 {
                throw PalaceError.bookRegistry(.bookNotFound)
            }
            return "Borrowed"
        }

        XCTAssertEqual(result, "Borrowed")
        XCTAssertEqual(attempts.value, 2, "Should succeed on second attempt after no-active-loan")
    }

    // MARK: - Successful Operations

    func testExecuteWithRetry_successfulOperation_returnsResult() async throws {
        let recovery = DownloadErrorRecovery()

        let result = try await recovery.executeWithRetry(
            policy: .default
        ) {
            return "Success"
        }

        XCTAssertEqual(result, "Success")
    }

    func testExecuteWithRetry_immediateSuccess_noRetries() async throws {
        let recovery = DownloadErrorRecovery()
        // Boxed: @Sendable operation closure (see note above).
        let callCount = LockIsolated(0)

        _ = try await recovery.executeWithRetry(
            policy: .default
        ) {
            callCount.withValue { $0 += 1 }
            return 42
        }

        XCTAssertEqual(callCount.value, 1, "Should only be called once on immediate success")
    }

    // MARK: - Retry Behavior

    func testExecuteWithRetry_retriesOnTransientError() async throws {
        let recovery = DownloadErrorRecovery()
        // Boxed: @Sendable operation closure (see note above).
        let attempts = LockIsolated(0)

        let result = try await recovery.executeWithRetry(
            policy: DownloadErrorRecovery.RetryPolicy(
                maxAttempts: 3,
                baseDelay: 0.01,
                maxDelay: 0.05,
                overallTimeout: 10,
                shouldRetry: { _ in true }
            )
        ) {
            let n = attempts.withValue { $0 += 1; return $0 }
            if n < 3 {
                throw NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost, userInfo: nil)
            }
            return "Recovered"
        }

        XCTAssertEqual(result, "Recovered")
        XCTAssertEqual(attempts.value, 3)
    }

    func testExecuteWithRetry_failsAfterMaxAttempts() async {
        let recovery = DownloadErrorRecovery()
        // Boxed: @Sendable operation closure (see note above).
        let attempts = LockIsolated(0)

        do {
            _ = try await recovery.executeWithRetry(
                policy: DownloadErrorRecovery.RetryPolicy(
                    maxAttempts: 2,
                    baseDelay: 0.01,
                    maxDelay: 0.05,
                    overallTimeout: 10,
                    shouldRetry: { _ in true }
                )
            ) { () -> String in
                attempts.withValue { $0 += 1 }
                throw NSError(domain: "TestDomain", code: 1, userInfo: nil)
            }
            XCTFail("Should have thrown after max attempts")
        } catch {
            XCTAssertEqual(attempts.value, 2, "Should have attempted exactly maxAttempts times")
        }
    }

    // MARK: - Non-Retryable Errors

    func testExecuteWithRetry_nonRetryableError_failsImmediately() async {
        let recovery = DownloadErrorRecovery()
        // Boxed: @Sendable operation closure (see note above).
        let attempts = LockIsolated(0)

        do {
            _ = try await recovery.executeWithRetry(
                policy: DownloadErrorRecovery.RetryPolicy(
                    maxAttempts: 5,
                    baseDelay: 0.01,
                    maxDelay: 0.05,
                    overallTimeout: 10,
                    shouldRetry: { _ in false }  // Never retry
                )
            ) { () -> String in
                attempts.withValue { $0 += 1 }
                throw NSError(domain: "Fatal", code: 1, userInfo: nil)
            }
            XCTFail("Should have thrown")
        } catch {
            XCTAssertEqual(attempts.value, 1, "Non-retryable errors should fail after first attempt")
        }
    }

    // MARK: - Return Types

    func testExecuteWithRetry_worksWithDifferentTypes() async throws {
        let recovery = DownloadErrorRecovery()

        let intResult = try await recovery.executeWithRetry { return 42 }
        XCTAssertEqual(intResult, 42)

        let boolResult = try await recovery.executeWithRetry { return true }
        XCTAssertEqual(boolResult, true)

        let arrayResult = try await recovery.executeWithRetry { return [1, 2, 3] }
        XCTAssertEqual(arrayResult, [1, 2, 3])
    }
}
