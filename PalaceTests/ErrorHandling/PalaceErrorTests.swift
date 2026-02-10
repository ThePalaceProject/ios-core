//
//  PalaceErrorTests.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class PalaceErrorCategoryTests: XCTestCase {

  // MARK: - Error Descriptions

  func testNetworkError_allCases_haveDescriptions() {
    for error in [
      PalaceError.network(.noConnection),
      PalaceError.network(.timeout),
      PalaceError.network(.invalidURL),
      PalaceError.network(.invalidResponse),
      PalaceError.network(.unauthorized),
      PalaceError.network(.forbidden),
      PalaceError.network(.notFound),
      PalaceError.network(.serverError),
      PalaceError.network(.rateLimited),
      PalaceError.network(.cancelled),
      PalaceError.network(.unknown)
    ] {
      XCTAssertNotNil(error.errorDescription, "\(error) should have a description")
      XCTAssertFalse(error.errorDescription!.isEmpty)
    }
  }

  func testDownloadError_allCases_haveDescriptions() {
    for error in [
      PalaceError.download(.networkFailure),
      PalaceError.download(.insufficientSpace),
      PalaceError.download(.fileSystemError),
      PalaceError.download(.corruptedDownload),
      PalaceError.download(.cancelled),
      PalaceError.download(.maxRetriesExceeded),
      PalaceError.download(.invalidLicense),
      PalaceError.download(.downloadNotFound),
      PalaceError.download(.cannotFulfill)
    ] {
      XCTAssertNotNil(error.errorDescription, "\(error) should have a description")
      XCTAssertFalse(error.errorDescription!.isEmpty)
    }
  }

  func testAuthenticationError_allCases_haveDescriptions() {
    for error in [
      PalaceError.authentication(.invalidCredentials),
      PalaceError.authentication(.noCredentials),
      PalaceError.authentication(.tokenExpired),
      PalaceError.authentication(.tokenRefreshFailed),
      PalaceError.authentication(.accountNotFound),
      PalaceError.authentication(.networkError)
    ] {
      XCTAssertNotNil(error.errorDescription, "\(error) should have a description")
    }
  }

  // MARK: - Error Codes

  func testErrorCode_networkErrors_startAt1000() {
    let error = PalaceError.network(.noConnection)
    XCTAssertEqual(error.errorCode, 1000, "Network errors should start at 1000")
  }

  func testErrorCode_downloadErrors_startAt3000() {
    let error = PalaceError.download(.networkFailure)
    XCTAssertEqual(error.errorCode, 3000, "Download errors should start at 3000")
  }

  func testErrorCode_authErrors_startAt6000() {
    let error = PalaceError.authentication(.invalidCredentials)
    XCTAssertEqual(error.errorCode, 6000, "Auth errors should start at 6000")
  }

  func testErrorCode_drmErrors_startAt5000() {
    let error = PalaceError.drm(.authenticationFailed)
    XCTAssertEqual(error.errorCode, 5000, "DRM errors should start at 5000")
  }

  func testErrorCode_uniquePerCase() {
    let codes = [
      PalaceError.network(.noConnection).errorCode,
      PalaceError.network(.timeout).errorCode,
      PalaceError.network(.invalidURL).errorCode,
      PalaceError.download(.networkFailure).errorCode,
      PalaceError.download(.insufficientSpace).errorCode,
      PalaceError.authentication(.invalidCredentials).errorCode,
      PalaceError.authentication(.noCredentials).errorCode,
    ]
    XCTAssertEqual(Set(codes).count, codes.count, "Each error should have a unique code")
  }

  // MARK: - Recovery Suggestions

  func testRecoverySuggestion_networkErrors_provideGuidance() {
    let error = PalaceError.network(.noConnection)
    XCTAssertNotNil(error.recoverySuggestion, "Network errors should have recovery suggestions")
  }

  func testRecoverySuggestion_downloadInsufficientSpace() {
    let error = PalaceError.download(.insufficientSpace)
    XCTAssertNotNil(error.recoverySuggestion)
  }

  // MARK: - NSError Conversion

  func testFromNSError_urlErrorNotConnected_mapsToNoConnection() {
    let nsError = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet, userInfo: nil)
    let palaceError = PalaceError.from(nsError)

    if case .network(.noConnection) = palaceError {
      // Expected
    } else {
      XCTFail("Expected .network(.noConnection), got \(palaceError)")
    }
  }

  func testFromNSError_urlErrorTimedOut_mapsToTimeout() {
    let nsError = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: nil)
    let palaceError = PalaceError.from(nsError)

    if case .network(.timeout) = palaceError {
      // Expected
    } else {
      XCTFail("Expected .network(.timeout), got \(palaceError)")
    }
  }

  func testFromNSError_urlErrorCancelled_mapsToCancelled() {
    let nsError = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled, userInfo: nil)
    let palaceError = PalaceError.from(nsError)

    if case .network(.cancelled) = palaceError {
      // Expected
    } else {
      XCTFail("Expected .network(.cancelled), got \(palaceError)")
    }
  }

  func testFromNSError_unknownDomain_mapsToNetworkUnknown() {
    let nsError = NSError(domain: "SomeOtherDomain", code: 999, userInfo: nil)
    let palaceError = PalaceError.from(nsError)

    if case .network(.unknown) = palaceError {
      // Expected
    } else {
      XCTFail("Expected .network(.unknown), got \(palaceError)")
    }
  }

  // MARK: - LocalizedError Conformance

  func testLocalizedError_conformance() {
    let error: Error = PalaceError.network(.noConnection)
    XCTAssertNotNil(error.localizedDescription)
    XCTAssertFalse(error.localizedDescription.isEmpty)
  }

  // MARK: - Storage Errors

  func testStorageError_allCases_haveDescriptions() {
    for error in [
      PalaceError.storage(.insufficientSpace),
      PalaceError.storage(.fileNotFound),
      PalaceError.storage(.permissionDenied),
      PalaceError.storage(.corruptedData),
      PalaceError.storage(.writeError),
      PalaceError.storage(.readError)
    ] {
      XCTAssertNotNil(error.errorDescription)
    }
  }

  // MARK: - BookReader Errors

  func testBookReaderError_allCases_haveDescriptions() {
    for error in [
      PalaceError.bookReader(.bookNotAvailable),
      PalaceError.bookReader(.corruptedBook),
      PalaceError.bookReader(.unsupportedFormat),
      PalaceError.bookReader(.decryptionRequired),
      PalaceError.bookReader(.renderingError),
      PalaceError.bookReader(.bookmarkError)
    ] {
      XCTAssertNotNil(error.errorDescription)
    }
  }
}
