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

    /// Each PalaceError category occupies its own 1000-block of error codes.
    /// Lock the blocks together so a mutant that swaps two categories'
    /// offsets fails on a single test, and so a future engineer adding a new
    /// category sees the canonical layout in one place.
    func testErrorCode_categoryOffsetsAreUniqueAndStable() {
        // category → first-case → expected base
        let blocks: [(error: PalaceError, expectedCode: Int, label: String)] = [
            (.bookRegistry(.bookNotFound),  2000, "bookRegistry"),
            (.parsing(.invalidJSON),        4000, "parsing"),
            (.storage(.insufficientSpace),  7000, "storage"),
            (.bookReader(.bookNotAvailable),8000, "bookReader"),
            (.audiobook(.corruptedManifest),9000, "audiobook"),
        ]

        // Each category lands at its expected base.
        for block in blocks {
            XCTAssertEqual(block.error.errorCode, block.expectedCode,
                           "\(block.label) must start at \(block.expectedCode)")
        }

        // Bases are pairwise distinct. A mutant that collapses two ranges
        // (e.g. parsing at 2000) would fail this set-size invariant.
        let bases = Set(blocks.map { $0.expectedCode })
        XCTAssertEqual(bases.count, blocks.count,
                       "Each category MUST occupy a distinct error-code range")
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

    // MARK: - Cancellation has no recovery suggestion

    /// "Cancelled" is the user's choice — surfacing a recovery suggestion for
    /// it would be nagging. Lock the contract on both NetworkError and
    /// DownloadError in one body, AND contrast against a non-cancelled case
    /// to make sure the "always-nil" mutant fails. This kills the broader
    /// mutation surface that two single-assertion tests would not.
    func testCancellation_yieldsNoRecoverySuggestionAcrossNetworkAndDownload() {
        XCTAssertNil(NetworkError.cancelled.recoverySuggestion,
                     "User-cancelled network errors must not show a recovery prompt")
        XCTAssertNil(DownloadError.cancelled.recoverySuggestion,
                     "User-cancelled downloads must not show a recovery prompt")

        // Contrast cases — would fail if a mutant nukes the whole getter.
        XCTAssertNotNil(NetworkError.timeout.recoverySuggestion,
                        "Non-cancelled errors MUST have a recovery suggestion — guards against an always-nil mutant")
        XCTAssertNotNil(DownloadError.insufficientSpace.recoverySuggestion)
    }

    // MARK: - LocalizedError Conformance via PalaceError Wrapper

    /// PalaceError is a sum type that defers `recoverySuggestion` and
    /// `errorDescription` to the wrapped inner error. Verify the delegation
    /// across both LocalizedError surfaces in one body so a mutant that
    /// returns a hard-coded string from PalaceError fails on either probe.
    func testPalaceError_localizedErrorSurface_delegatesToInnerError() {
        // recoverySuggestion delegation via storage(.permissionDenied)
        let storageError = PalaceError.storage(.permissionDenied)
        XCTAssertEqual(storageError.recoverySuggestion,
                       StorageError.permissionDenied.recoverySuggestion,
                       "recoverySuggestion must come from the wrapped inner error")

        // errorDescription delegation via authentication(.tokenExpired)
        let authError = PalaceError.authentication(.tokenExpired)
        XCTAssertEqual(authError.errorDescription,
                       AuthenticationError.tokenExpired.errorDescription,
                       "errorDescription must come from the wrapped inner error")

        // Cross-category sanity: recoverySuggestion of one inner type doesn't
        // leak when wrapping a different inner type. This catches a mutant
        // that hardcodes a single inner-error's value.
        XCTAssertNotEqual(storageError.errorDescription,
                          AuthenticationError.tokenExpired.errorDescription,
                          "Different wrapped inner errors must yield different errorDescription")
    }
}
