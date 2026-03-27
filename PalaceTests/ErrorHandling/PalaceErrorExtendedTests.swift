//
//  PalaceErrorExtendedTests.swift
//  PalaceTests
//
//  Extended tests for PalaceError covering:
//  - Missing error category descriptions (BookRegistry, Parsing, Audiobook, DRM)
//  - Error code ranges for all categories
//  - Recovery suggestions for all categories
//  - NSError conversion edge cases (HTTP status codes, Palace domain)
//  - palaceErrorFromCode reconstruction
//
//  Copyright 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class PalaceErrorExtendedTests: XCTestCase {

    // MARK: - BookRegistry Error Descriptions

    func testBookRegistryError_allCases_haveDescriptions() {
        let cases: [PalaceError] = [
            .bookRegistry(.bookNotFound),
            .bookRegistry(.registryCorrupted),
            .bookRegistry(.syncFailed),
            .bookRegistry(.saveFailed),
            .bookRegistry(.loadFailed),
            .bookRegistry(.invalidState),
            .bookRegistry(.concurrencyViolation),
            .bookRegistry(.alreadyBorrowed)
        ]
        for error in cases {
            XCTAssertNotNil(error.errorDescription, "\(error) should have a description")
            XCTAssertFalse(error.errorDescription!.isEmpty, "\(error) description should not be empty")
        }
    }

    func testBookRegistryError_allCases_haveRecoverySuggestions() {
        let cases: [BookRegistryError] = [
            .bookNotFound, .registryCorrupted, .syncFailed,
            .saveFailed, .loadFailed, .invalidState,
            .concurrencyViolation, .alreadyBorrowed
        ]
        for error in cases {
            XCTAssertNotNil(error.recoverySuggestion, "\(error) should have a recovery suggestion")
        }
    }

    // MARK: - Parsing Error Descriptions

    func testParsingError_allCases_haveDescriptions() {
        let cases: [PalaceError] = [
            .parsing(.invalidJSON),
            .parsing(.invalidXML),
            .parsing(.missingRequiredField),
            .parsing(.invalidFormat),
            .parsing(.encodingError),
            .parsing(.opdsFeedInvalid),
            .parsing(.contentNotSupported)
        ]
        for error in cases {
            XCTAssertNotNil(error.errorDescription, "\(error) should have a description")
            XCTAssertFalse(error.errorDescription!.isEmpty)
        }
    }

    func testParsingError_contentNotSupported_hasSpecificRecovery() {
        let error = ParsingError.contentNotSupported
        XCTAssertNotNil(error.recoverySuggestion)
        XCTAssertTrue(error.recoverySuggestion!.contains("newer version"),
                      "contentNotSupported should mention app version")
    }

    func testParsingError_otherCases_haveGenericRecovery() {
        let error = ParsingError.invalidJSON
        XCTAssertNotNil(error.recoverySuggestion)
        XCTAssertTrue(error.recoverySuggestion!.contains("unexpected format"))
    }

    // MARK: - Audiobook Error Descriptions

    func testAudiobookError_allCases_haveDescriptions() {
        let cases: [PalaceError] = [
            .audiobook(.corruptedManifest),
            .audiobook(.missingAudioFiles),
            .audiobook(.streamingError),
            .audiobook(.decodingError),
            .audiobook(.playbackError),
            .audiobook(.bookmarkError)
        ]
        for error in cases {
            XCTAssertNotNil(error.errorDescription, "\(error) should have a description")
            XCTAssertFalse(error.errorDescription!.isEmpty)
        }
    }

    func testAudiobookError_allCases_haveRecoverySuggestions() {
        let cases: [AudiobookError] = [
            .corruptedManifest, .missingAudioFiles, .streamingError,
            .decodingError, .playbackError, .bookmarkError
        ]
        for error in cases {
            XCTAssertNotNil(error.recoverySuggestion, "\(error) should have a recovery suggestion")
        }
    }

    // MARK: - DRM Error Descriptions

    func testDRMError_allCases_haveDescriptions() {
        let cases: [PalaceError] = [
            .drm(.authenticationFailed),
            .drm(.tooManyActivations),
            .drm(.licenseExpired),
            .drm(.decryptionFailed),
            .drm(.noActivation),
            .drm(.adobeError),
            .drm(.lcpError)
        ]
        for error in cases {
            XCTAssertNotNil(error.errorDescription, "\(error) should have a description")
            XCTAssertFalse(error.errorDescription!.isEmpty)
        }
    }

    func testDRMError_allCases_haveRecoverySuggestions() {
        let cases: [DRMError] = [
            .authenticationFailed, .tooManyActivations, .licenseExpired,
            .decryptionFailed, .noActivation, .adobeError, .lcpError
        ]
        for error in cases {
            XCTAssertNotNil(error.recoverySuggestion, "\(error) should have a recovery suggestion")
        }
    }

    // MARK: - Error Code Range Tests

    func testErrorCode_bookRegistryErrors_startAt2000() {
        let error = PalaceError.bookRegistry(.bookNotFound)
        XCTAssertEqual(error.errorCode, 2000)
    }

    func testErrorCode_parsingErrors_startAt4000() {
        let error = PalaceError.parsing(.invalidJSON)
        XCTAssertEqual(error.errorCode, 4000)
    }

    func testErrorCode_storageErrors_startAt7000() {
        let error = PalaceError.storage(.insufficientSpace)
        XCTAssertEqual(error.errorCode, 7000)
    }

    func testErrorCode_bookReaderErrors_startAt8000() {
        let error = PalaceError.bookReader(.bookNotAvailable)
        XCTAssertEqual(error.errorCode, 8000)
    }

    func testErrorCode_audiobookErrors_startAt9000() {
        let error = PalaceError.audiobook(.corruptedManifest)
        XCTAssertEqual(error.errorCode, 9000)
    }

    func testErrorCode_offsetByRawValue() {
        // NetworkError.timeout has rawValue 1, so code should be 1001
        let error = PalaceError.network(.timeout)
        XCTAssertEqual(error.errorCode, 1001)

        // DownloadError.insufficientSpace has rawValue 1, so code should be 3001
        let dlError = PalaceError.download(.insufficientSpace)
        XCTAssertEqual(dlError.errorCode, 3001)
    }

    // MARK: - NSError Conversion: HTTP Status Codes

    func testFromNSError_urlErrorBadURL_mapsToInvalidURL() {
        let nsError = NSError(domain: NSURLErrorDomain, code: NSURLErrorBadURL, userInfo: nil)
        let palaceError = PalaceError.from(nsError)
        if case .network(.invalidURL) = palaceError {
            // Expected
        } else {
            XCTFail("Expected .network(.invalidURL), got \(palaceError)")
        }
    }

    func testFromNSError_urlErrorCannotFindHost_mapsToServerError() {
        let nsError = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost, userInfo: nil)
        let palaceError = PalaceError.from(nsError)
        if case .network(.serverError) = palaceError {
            // Expected
        } else {
            XCTFail("Expected .network(.serverError), got \(palaceError)")
        }
    }

    func testFromNSError_urlErrorCannotConnectToHost_mapsToServerError() {
        let nsError = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost, userInfo: nil)
        let palaceError = PalaceError.from(nsError)
        if case .network(.serverError) = palaceError {
            // Expected
        } else {
            XCTFail("Expected .network(.serverError), got \(palaceError)")
        }
    }

    func testFromNSError_urlErrorUnsupportedURL_mapsToInvalidURL() {
        let nsError = NSError(domain: NSURLErrorDomain, code: NSURLErrorUnsupportedURL, userInfo: nil)
        let palaceError = PalaceError.from(nsError)
        if case .network(.invalidURL) = palaceError {
            // Expected
        } else {
            XCTFail("Expected .network(.invalidURL), got \(palaceError)")
        }
    }

    // MARK: - NSError Conversion: Palace Domain

    func testFromNSError_palaceDomain_code0_mapsToNetworkUnknown() {
        let nsError = NSError(domain: "Palace.PalaceError", code: 0, userInfo: nil)
        let palaceError = PalaceError.from(nsError)
        if case .network(.unknown) = palaceError {
            // Expected
        } else {
            XCTFail("Expected .network(.unknown), got \(palaceError)")
        }
    }

    func testFromNSError_palaceDomain_code3_mapsToParsingOpdsFeedInvalid() {
        let nsError = NSError(domain: "Palace.PalaceError", code: 3, userInfo: nil)
        let palaceError = PalaceError.from(nsError)
        if case .parsing(.opdsFeedInvalid) = palaceError {
            // Expected
        } else {
            XCTFail("Expected .parsing(.opdsFeedInvalid), got \(palaceError)")
        }
    }

    func testFromNSError_palaceDomain_code5_mapsToAuthInvalidCredentials() {
        let nsError = NSError(domain: "Palace.PalaceError", code: 5, userInfo: nil)
        let palaceError = PalaceError.from(nsError)
        if case .authentication(.invalidCredentials) = palaceError {
            // Expected
        } else {
            XCTFail("Expected .authentication(.invalidCredentials), got \(palaceError)")
        }
    }

    func testFromNSError_palaceDomain_code8_mapsToAudiobookPlaybackError() {
        let nsError = NSError(domain: "Palace.PalaceError", code: 8, userInfo: nil)
        let palaceError = PalaceError.from(nsError)
        if case .audiobook(.playbackError) = palaceError {
            // Expected
        } else {
            XCTFail("Expected .audiobook(.playbackError), got \(palaceError)")
        }
    }

    func testFromNSError_palaceDomain_unknownCode_mapsToNetworkUnknown() {
        let nsError = NSError(domain: "Palace.PalaceError", code: 999, userInfo: nil)
        let palaceError = PalaceError.from(nsError)
        if case .network(.unknown) = palaceError {
            // Expected
        } else {
            XCTFail("Expected .network(.unknown) for unknown code, got \(palaceError)")
        }
    }

    // MARK: - PalaceError Identity Conversion

    func testFromError_palaceErrorPassedDirectly_returnsItself() {
        let original = PalaceError.download(.insufficientSpace)
        let converted = PalaceError.from(original)
        if case .download(.insufficientSpace) = converted {
            // Expected
        } else {
            XCTFail("Expected .download(.insufficientSpace), got \(converted)")
        }
    }

    // MARK: - NetworkError Recovery Suggestion Edge Cases

    func testNetworkError_cancelled_hasNilRecoverySuggestion() {
        let error = NetworkError.cancelled
        XCTAssertNil(error.recoverySuggestion,
                     "Cancelled errors should not have a recovery suggestion")
    }

    func testDownloadError_cancelled_hasNilRecoverySuggestion() {
        let error = DownloadError.cancelled
        XCTAssertNil(error.recoverySuggestion,
                     "Cancelled downloads should not have a recovery suggestion")
    }

    // MARK: - LocalizedError Conformance via PalaceError Wrapper

    func testPalaceError_recoverySuggestion_delegatesToInnerError() {
        let error = PalaceError.storage(.permissionDenied)
        let innerSuggestion = StorageError.permissionDenied.recoverySuggestion
        XCTAssertEqual(error.recoverySuggestion, innerSuggestion,
                       "PalaceError should delegate recoverySuggestion to inner error")
    }

    func testPalaceError_errorDescription_delegatesToInnerError() {
        let error = PalaceError.authentication(.tokenExpired)
        let innerDescription = AuthenticationError.tokenExpired.errorDescription
        XCTAssertEqual(error.errorDescription, innerDescription,
                       "PalaceError should delegate errorDescription to inner error")
    }
}
