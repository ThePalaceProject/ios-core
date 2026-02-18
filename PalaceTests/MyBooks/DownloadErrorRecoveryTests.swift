//
//  DownloadErrorRecoveryTests.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class DownloadErrorRecoveryPolicyTests: XCTestCase {

    // MARK: - Retry Policy Presets

    func testDefaultPolicy_hasReasonableDefaults() {
        let policy = DownloadErrorRecovery.RetryPolicy.default
        XCTAssertGreaterThan(policy.maxAttempts, 0)
        XCTAssertGreaterThan(policy.baseDelay, 0)
        XCTAssertGreaterThanOrEqual(policy.maxDelay, policy.baseDelay)
        XCTAssertGreaterThan(policy.overallTimeout, 0)
    }

    func testAggressivePolicy_hasMoreAttempts() {
        let aggressive = DownloadErrorRecovery.RetryPolicy.aggressive
        let defaultPolicy = DownloadErrorRecovery.RetryPolicy.default
        XCTAssertGreaterThanOrEqual(aggressive.maxAttempts, defaultPolicy.maxAttempts)
    }

    func testConservativePolicy_hasFewerAttempts() {
        let conservative = DownloadErrorRecovery.RetryPolicy.conservative
        let aggressive = DownloadErrorRecovery.RetryPolicy.aggressive
        XCTAssertLessThanOrEqual(conservative.maxAttempts, aggressive.maxAttempts)
    }

    func testBorrowOperationPolicy_exists() {
        let borrowPolicy = DownloadErrorRecovery.RetryPolicy.borrowOperation
        XCTAssertGreaterThan(borrowPolicy.maxAttempts, 0)
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
        var callCount = 0

        _ = try await recovery.executeWithRetry(
            policy: .default
        ) {
            callCount += 1
            return 42
        }

        XCTAssertEqual(callCount, 1, "Should only be called once on immediate success")
    }

    // MARK: - Retry Behavior

    func testExecuteWithRetry_retriesOnTransientError() async throws {
        let recovery = DownloadErrorRecovery()
        var attempts = 0

        let result = try await recovery.executeWithRetry(
            policy: DownloadErrorRecovery.RetryPolicy(
                maxAttempts: 3,
                baseDelay: 0.01,
                maxDelay: 0.05,
                overallTimeout: 10,
                shouldRetry: { _ in true }
            )
        ) {
            attempts += 1
            if attempts < 3 {
                throw NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost, userInfo: nil)
            }
            return "Recovered"
        }

        XCTAssertEqual(result, "Recovered")
        XCTAssertEqual(attempts, 3)
    }

    func testExecuteWithRetry_failsAfterMaxAttempts() async {
        let recovery = DownloadErrorRecovery()
        var attempts = 0

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
                attempts += 1
                throw NSError(domain: "TestDomain", code: 1, userInfo: nil)
            }
            XCTFail("Should have thrown after max attempts")
        } catch {
            XCTAssertEqual(attempts, 2, "Should have attempted exactly maxAttempts times")
        }
    }

    // MARK: - Non-Retryable Errors

    func testExecuteWithRetry_nonRetryableError_failsImmediately() async {
        let recovery = DownloadErrorRecovery()
        var attempts = 0

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
                attempts += 1
                throw NSError(domain: "Fatal", code: 1, userInfo: nil)
            }
            XCTFail("Should have thrown")
        } catch {
            XCTAssertEqual(attempts, 1, "Non-retryable errors should fail after first attempt")
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
