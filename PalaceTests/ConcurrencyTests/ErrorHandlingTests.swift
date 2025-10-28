//
//  ErrorHandlingTests.swift
//  PalaceTests
//
//  Created for Swift Concurrency Modernization
//  Copyright © 2025 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

/// Tests for PalaceError and error conversion
final class ErrorHandlingTests: XCTestCase {
  
  // MARK: - Error Conversion Tests
  
  func testNSURLErrorConversion() {
    let urlError = NSError(
      domain: NSURLErrorDomain,
      code: NSURLErrorNotConnectedToInternet,
      userInfo: nil
    )
    
    let palaceError = PalaceError.from(urlError)
    
    if case .network(let networkError) = palaceError {
      XCTAssertEqual(networkError, .noConnection)
    } else {
      XCTFail("Should convert to network error")
    }
  }
  
  func testTimeoutErrorConversion() {
    let timeoutError = NSError(
      domain: NSURLErrorDomain,
      code: NSURLErrorTimedOut,
      userInfo: nil
    )
    
    let palaceError = PalaceError.from(timeoutError)
    
    if case .network(let networkError) = palaceError {
      XCTAssertEqual(networkError, .timeout)
    } else {
      XCTFail("Should convert to timeout error")
    }
  }
  
  func testCancelledErrorConversion() {
    let cancelledError = NSError(
      domain: NSURLErrorDomain,
      code: NSURLErrorCancelled,
      userInfo: nil
    )
    
    let palaceError = PalaceError.from(cancelledError)
    
    if case .network(let networkError) = palaceError {
      XCTAssertEqual(networkError, .cancelled)
    } else {
      XCTFail("Should convert to cancelled error")
    }
  }
  
  // MARK: - Error Description Tests
  
  func testNetworkErrorDescriptions() {
    let errors: [NetworkError] = [
      .noConnection,
      .timeout,
      .unauthorized,
      .serverError
    ]
    
    for error in errors {
      XCTAssertNotNil(error.errorDescription)
      XCTAssertNotNil(error.recoverySuggestion)
      XCTAssertFalse(error.errorDescription!.isEmpty)
    }
  }
  
  func testDownloadErrorDescriptions() {
    let errors: [DownloadError] = [
      .networkFailure,
      .insufficientSpace,
      .corruptedDownload,
      .maxRetriesExceeded
    ]
    
    for error in errors {
      XCTAssertNotNil(error.errorDescription)
      XCTAssertNotNil(error.recoverySuggestion)
    }
  }
  
  // MARK: - Error Code Tests
  
  func testErrorCodeRanges() {
    let networkError = PalaceError.network(.timeout)
    XCTAssertGreaterThanOrEqual(networkError.errorCode, 1000)
    XCTAssertLessThan(networkError.errorCode, 2000)
    
    let registryError = PalaceError.bookRegistry(.syncFailed)
    XCTAssertGreaterThanOrEqual(registryError.errorCode, 2000)
    XCTAssertLessThan(registryError.errorCode, 3000)
    
    let downloadError = PalaceError.download(.insufficientSpace)
    XCTAssertGreaterThanOrEqual(downloadError.errorCode, 3000)
    XCTAssertLessThan(downloadError.errorCode, 4000)
  }
  
  // MARK: - Result Extension Tests
  
  func testResultErrorLogging() {
    let successResult: Result<String, PalaceError> = .success("test")
    let loggedSuccess = successResult.logError(context: "Test context")
    
    if case .success(let value) = loggedSuccess {
      XCTAssertEqual(value, "test")
    } else {
      XCTFail("Success result should remain success")
    }
    
    let failureResult: Result<String, PalaceError> = .failure(.network(.timeout))
    let loggedFailure = failureResult.logError(context: "Test context")
    
    if case .failure = loggedFailure {
      // Expected
    } else {
      XCTFail("Failure result should remain failure")
    }
  }
  
  // MARK: - Error Retry Logic Tests
  
  func testRetryableErrors() {
    let retryableError = NSError(
      domain: NSURLErrorDomain,
      code: NSURLErrorTimedOut,
      userInfo: nil
    )
    XCTAssertTrue(retryableError.isRetryable)
    
    let nonRetryableError = NSError(
      domain: NSURLErrorDomain,
      code: NSURLErrorCancelled,
      userInfo: nil
    )
    XCTAssertFalse(nonRetryableError.isRetryable)
  }
  
  func testUserInitiatedErrors() {
    let cancelledError = NSError(
      domain: NSURLErrorDomain,
      code: NSURLErrorCancelled,
      userInfo: nil
    )
    XCTAssertTrue(cancelledError.isUserInitiated)
    
    let timeoutError = NSError(
      domain: NSURLErrorDomain,
      code: NSURLErrorTimedOut,
      userInfo: nil
    )
    XCTAssertFalse(timeoutError.isUserInitiated)
  }
}

