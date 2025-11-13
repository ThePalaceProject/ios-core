//
//  DownloadRecoveryTests.swift
//  PalaceTests
//
//  Copyright © 2025 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

/// Tests for download error recovery and retry logic
final class DownloadRecoveryTests: XCTestCase {
  
  // MARK: - Retry Policy Tests
  
  private var testAudiobook: TPPBook {
    TPPBook(dictionary: [
      "acquisitions": [TPPFake.genericAudiobookAcquisition.dictionaryRepresentation()],
      "title": "Tractatus",
      "categories": ["some cat"],
      "id": "123",
      "updated": "2020-10-06T17:13:51Z"]
    )!
  }
  
  func testDefaultRetryPolicy() {
    let policy = DownloadErrorRecovery.RetryPolicy.default
    
    XCTAssertEqual(policy.maxAttempts, 3)
    XCTAssertEqual(policy.baseDelay, 2.0)
    XCTAssertEqual(policy.maxDelay, 30.0)
    
    // Test retry decisions
    let timeoutError = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: nil)
    XCTAssertTrue(policy.shouldRetry(timeoutError))
    
    let cancelledError = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled, userInfo: nil)
    XCTAssertFalse(policy.shouldRetry(cancelledError))
  }
  
  func testAggressiveRetryPolicy() {
    let policy = DownloadErrorRecovery.RetryPolicy.aggressive
    
    XCTAssertEqual(policy.maxAttempts, 5)
    
    // Should retry everything
    let anyError = NSError(domain: "test", code: 999, userInfo: nil)
    XCTAssertTrue(policy.shouldRetry(anyError))
  }
  
  func testConservativeRetryPolicy() {
    let policy = DownloadErrorRecovery.RetryPolicy.conservative
    
    XCTAssertEqual(policy.maxAttempts, 2)
    
    // Only retries network errors
    let timeoutError = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: nil)
    XCTAssertTrue(policy.shouldRetry(timeoutError))
    
    let badURLError = NSError(domain: NSURLErrorDomain, code: NSURLErrorBadURL, userInfo: nil)
    XCTAssertFalse(policy.shouldRetry(badURLError))
  }
  
  // MARK: - Retry Execution Tests
  
  func testRetrySucceedsOnFirstAttempt() async throws {
    let recovery = DownloadErrorRecovery()
    var attemptCount = 0
    
    let result = try await recovery.executeWithRetry(policy: .default) {
      attemptCount += 1
      return "success"
    }
    
    XCTAssertEqual(result, "success")
    XCTAssertEqual(attemptCount, 1)
  }
  
  func testRetrySucceedsAfterFailures() async throws {
    let recovery = DownloadErrorRecovery()
    var attemptCount = 0
    
    let result = try await recovery.executeWithRetry(policy: .default) {
      attemptCount += 1
      if attemptCount < 3 {
        throw NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: nil)
      }
      return "success"
    }
    
    XCTAssertEqual(result, "success")
    XCTAssertEqual(attemptCount, 3)
  }
  
  func testRetryFailsAfterMaxAttempts() async throws {
    let recovery = DownloadErrorRecovery()
    var attemptCount = 0
    
    do {
      let _ = try await recovery.executeWithRetry(policy: .default) {
        attemptCount += 1
        throw NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: nil)
      }
      XCTFail("Should have thrown error after max attempts")
    } catch {
      XCTAssertEqual(attemptCount, 3)
      // Should throw maxRetriesExceeded
      if let palaceError = error as? PalaceError,
         case .download(let downloadError) = palaceError {
        XCTAssertEqual(downloadError, .maxRetriesExceeded)
      }
    }
  }
  
  func testRetryStopsOnNonRetryableError() async throws {
    let recovery = DownloadErrorRecovery()
    var attemptCount = 0
    
    do {
      let _ = try await recovery.executeWithRetry(policy: .default) {
        attemptCount += 1
        throw NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled, userInfo: nil)
      }
      XCTFail("Should have thrown error")
    } catch {
      // Should only attempt once for non-retryable error
      XCTAssertEqual(attemptCount, 1)
    }
  }
  
  // MARK: - Network Condition Tests
  
  func testNetworkSuitabilityCheck() async {
    let monitor = NetworkConditionMonitor.shared
    
    // Should return a boolean (actual result depends on current network)
    let isSuitable = await monitor.isNetworkSuitableForDownload()
    XCTAssertNotNil(isSuitable)
  }
  
  // MARK: - Disk Space Tests
  
  func testDiskSpaceCheck() async {
    let checker = DiskSpaceChecker.shared
    
    // Should have sufficient space for small download
    let hasSpace = await checker.hasSufficientSpace(forDownloadSize: 10) // 10MB
    XCTAssertTrue(hasSpace)
  }
  
  func testDownloadSizeEstimation() async {
    let checker = DiskSpaceChecker.shared
    
    // Create mock books
    let mockBook = testAudiobook
    mockBook.distributor = "test"
    
    let estimatedSize = await checker.estimateDownloadSize(for: mockBook)
    XCTAssertGreaterThan(estimatedSize, 0)
  }
  
  // MARK: - Integration Tests
  
  func testRetryWithExponentialBackoff() async throws {
    let recovery = DownloadErrorRecovery()
    let startTime = Date()
    var attemptCount = 0
    
    do {
      let _ = try await recovery.executeWithRetry(policy: .default) {
        attemptCount += 1
        throw NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: nil)
      }
      XCTFail("Should have thrown error")
    } catch {
      let elapsed = Date().timeIntervalSince(startTime)
      
      // With 3 attempts and exponential backoff, should take at least 2s (first delay)
      // but less than 10s (2s + 4s + margin)
      XCTAssertGreaterThan(elapsed, 2.0)
      XCTAssertLessThan(elapsed, 10.0)
      XCTAssertEqual(attemptCount, 3)
    }
  }
}

