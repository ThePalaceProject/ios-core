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
        // Network error codes must be below the download range (3000)
        XCTAssertLessThan(error.errorCode, 3000, "Network codes must be below download range")
        // Must also have a non-nil description
        XCTAssertNotNil(error.errorDescription, "Network error must have a human-readable description")
    }

    func testErrorCode_downloadErrors_startAt3000() {
        let error = PalaceError.download(.networkFailure)
        XCTAssertEqual(error.errorCode, 3000, "Download errors should start at 3000")
        // Download codes must be above network range and below auth range
        XCTAssertGreaterThanOrEqual(error.errorCode, 3000)
        XCTAssertNotNil(error.errorDescription, "Download error must have a description")
    }

    func testErrorCode_authErrors_startAt6000() {
        let error = PalaceError.authentication(.invalidCredentials)
        XCTAssertEqual(error.errorCode, 6000, "Auth errors should start at 6000")
        // Auth codes must be above DRM range (5000)
        XCTAssertGreaterThan(error.errorCode, 5000, "Auth codes must exceed DRM range")
        XCTAssertNotNil(error.errorDescription, "Auth error must have a description")
    }

    func testErrorCode_drmErrors_startAt5000() {
        let error = PalaceError.drm(.authenticationFailed)
        XCTAssertEqual(error.errorCode, 5000, "DRM errors should start at 5000")
        // DRM codes must be between download (3000) and auth (6000)
        XCTAssertGreaterThan(error.errorCode, 3000, "DRM codes must exceed download range")
        XCTAssertLessThan(error.errorCode, 6000, "DRM codes must be below auth range")
    }

    func testErrorCode_uniquePerCase() {
        let codes = [
            PalaceError.network(.noConnection).errorCode,
            PalaceError.network(.timeout).errorCode,
            PalaceError.network(.invalidURL).errorCode,
            PalaceError.download(.networkFailure).errorCode,
            PalaceError.download(.insufficientSpace).errorCode,
            PalaceError.authentication(.invalidCredentials).errorCode,
            PalaceError.authentication(.noCredentials).errorCode
        ]
        XCTAssertEqual(Set(codes).count, codes.count, "Each error should have a unique code")
    }

    // MARK: - Recovery Suggestions

    func testRecoverySuggestion_networkErrors_provideGuidance() {
        let error = PalaceError.network(.noConnection)
        XCTAssertNotNil(error.recoverySuggestion, "Network errors should have recovery suggestions")
        XCTAssertFalse(error.recoverySuggestion!.isEmpty,
                       "Recovery suggestion must not be empty")
        // Also verify a second network error has a suggestion (not just noConnection)
        let timeoutError = PalaceError.network(.timeout)
        XCTAssertNotNil(timeoutError.recoverySuggestion,
                        "Timeout errors should also have recovery suggestions")
    }

    func testRecoverySuggestion_downloadInsufficientSpace() {
        let error = PalaceError.download(.insufficientSpace)
        XCTAssertNotNil(error.recoverySuggestion)
        XCTAssertFalse(error.recoverySuggestion!.isEmpty,
                       "Insufficient space recovery suggestion must not be empty")
        // The suggestion should direct the user toward freeing storage
        let suggestion = error.recoverySuggestion!.lowercased()
        XCTAssertTrue(suggestion.contains("space") || suggestion.contains("storage") ||
                      suggestion.contains("free") || suggestion.contains("delete"),
                      "Insufficient space suggestion should mention storage: '\(suggestion)'")
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
        // LocalizedDescription must not be the raw enum name (i.e. proper localization)
        XCTAssertFalse(error.localizedDescription.contains("PalaceError"),
                       "LocalizedDescription must not expose internal type names")
        // Should be different from a different error
        let otherError: Error = PalaceError.network(.timeout)
        XCTAssertNotEqual(error.localizedDescription, otherError.localizedDescription,
                          "Different errors must have different localizedDescriptions")
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
