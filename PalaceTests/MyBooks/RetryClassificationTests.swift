//
//  RetryClassificationTests.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

/// Tests for DownloadErrorRecovery.isRetryableForUser() — PP-3707
/// Verifies that errors are correctly classified as retryable or non-retryable
/// for user-facing "Retry" button presentation.
final class RetryClassificationTests: XCTestCase {

    // MARK: - Network Errors (Retryable)

    func testNetworkErrors_retryable() {
        let retryableErrors: [PalaceError] = [
            .network(.serverError),
            .network(.timeout),
            .network(.noConnection),
            .network(.rateLimited),
            .network(.invalidResponse),
            .network(.unknown),
        ]

        for error in retryableErrors {
            XCTAssertTrue(
                DownloadErrorRecovery.isRetryableForUser(error),
                "\(error) should be retryable"
            )
        }
    }

    func testNetworkErrors_notRetryable() {
        let nonRetryableErrors: [PalaceError] = [
            .network(.unauthorized),
            .network(.forbidden),
            .network(.notFound),
            .network(.invalidURL),
            .network(.cancelled),
        ]

        for error in nonRetryableErrors {
            XCTAssertFalse(
                DownloadErrorRecovery.isRetryableForUser(error),
                "\(error) should NOT be retryable"
            )
        }
    }

    // MARK: - Parsing Errors (Retryable — transient server issues)

    func testParsingErrors_retryable() {
        let retryableErrors: [PalaceError] = [
            .parsing(.opdsFeedInvalid),
            .parsing(.invalidJSON),
            .parsing(.invalidXML),
            .parsing(.missingRequiredField),
            .parsing(.invalidFormat),
            .parsing(.encodingError),
        ]

        for error in retryableErrors {
            XCTAssertTrue(
                DownloadErrorRecovery.isRetryableForUser(error),
                "\(error) should be retryable"
            )
        }
    }

    func testParsingErrors_notRetryable() {
        let nonRetryableErrors: [PalaceError] = [
            .parsing(.contentNotSupported),
        ]

        for error in nonRetryableErrors {
            XCTAssertFalse(
                DownloadErrorRecovery.isRetryableForUser(error),
                "\(error) should NOT be retryable"
            )
        }
    }

    // MARK: - Download Errors

    func testDownloadErrors_retryable() {
        let retryableErrors: [PalaceError] = [
            .download(.networkFailure),
            .download(.maxRetriesExceeded),
        ]

        for error in retryableErrors {
            XCTAssertTrue(
                DownloadErrorRecovery.isRetryableForUser(error),
                "\(error) should be retryable"
            )
        }
    }

    func testDownloadErrors_notRetryable() {
        let nonRetryableErrors: [PalaceError] = [
            .download(.insufficientSpace),
            .download(.fileSystemError),
            .download(.corruptedDownload),
            .download(.cancelled),
            .download(.invalidLicense),
            .download(.downloadNotFound),
            .download(.cannotFulfill),
        ]

        for error in nonRetryableErrors {
            XCTAssertFalse(
                DownloadErrorRecovery.isRetryableForUser(error),
                "\(error) should NOT be retryable"
            )
        }
    }

    // MARK: - Authentication Errors

    func testAuthErrors_retryable() {
        XCTAssertTrue(
            DownloadErrorRecovery.isRetryableForUser(PalaceError.authentication(.networkError)),
            "Auth network error should be retryable"
        )
    }

    func testAuthErrors_notRetryable() {
        let nonRetryableErrors: [PalaceError] = [
            .authentication(.invalidCredentials),
            .authentication(.noCredentials),
            .authentication(.tokenExpired),
            .authentication(.tokenRefreshFailed),
            .authentication(.accountNotFound),
        ]

        for error in nonRetryableErrors {
            XCTAssertFalse(
                DownloadErrorRecovery.isRetryableForUser(error),
                "\(error) should NOT be retryable"
            )
        }
    }

    // MARK: - DRM Errors (Not Retryable)

    func testDRMErrors_notRetryable() {
        let nonRetryableErrors: [PalaceError] = [
            .drm(.authenticationFailed),
            .drm(.tooManyActivations),
            .drm(.licenseExpired),
            .drm(.decryptionFailed),
            .drm(.noActivation),
        ]

        for error in nonRetryableErrors {
            XCTAssertFalse(
                DownloadErrorRecovery.isRetryableForUser(error),
                "\(error) should NOT be retryable"
            )
        }
    }

    // MARK: - Storage Errors (Not Retryable)

    func testStorageErrors_notRetryable() {
        let nonRetryableErrors: [PalaceError] = [
            .storage(.insufficientSpace),
            .storage(.fileNotFound),
            .storage(.permissionDenied),
            .storage(.corruptedData),
        ]

        for error in nonRetryableErrors {
            XCTAssertFalse(
                DownloadErrorRecovery.isRetryableForUser(error),
                "\(error) should NOT be retryable"
            )
        }
    }

    // MARK: - Book Registry Errors

    func testBookRegistryErrors_retryable() {
        XCTAssertTrue(
            DownloadErrorRecovery.isRetryableForUser(PalaceError.bookRegistry(.syncFailed)),
            "Sync failure should be retryable"
        )
    }

    func testBookRegistryErrors_notRetryable() {
        let nonRetryableErrors: [PalaceError] = [
            .bookRegistry(.invalidState),
            .bookRegistry(.alreadyBorrowed),
            .bookRegistry(.bookNotFound),
        ]

        for error in nonRetryableErrors {
            XCTAssertFalse(
                DownloadErrorRecovery.isRetryableForUser(error),
                "\(error) should NOT be retryable"
            )
        }
    }

    // MARK: - Audiobook Errors

    func testAudiobookErrors_retryable() {
        XCTAssertTrue(
            DownloadErrorRecovery.isRetryableForUser(PalaceError.audiobook(.streamingError)),
            "Streaming error should be retryable"
        )
    }

    func testAudiobookErrors_notRetryable() {
        let nonRetryableErrors: [PalaceError] = [
            .audiobook(.corruptedManifest),
            .audiobook(.missingAudioFiles),
            .audiobook(.decodingError),
        ]

        for error in nonRetryableErrors {
            XCTAssertFalse(
                DownloadErrorRecovery.isRetryableForUser(error),
                "\(error) should NOT be retryable"
            )
        }
    }

    // MARK: - NSError (URL Error Domain)

    func testNSURLError_retryable() {
        let retryableErrors = [
            NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut),
            NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet),
            NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost),
            NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost),
        ]

        for error in retryableErrors {
            XCTAssertTrue(
                DownloadErrorRecovery.isRetryableForUser(error),
                "NSURLError code \(error.code) should be retryable"
            )
        }
    }

    func testNSURLError_notRetryable() {
        let nonRetryableErrors = [
            NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled),
            NSError(domain: NSURLErrorDomain, code: NSURLErrorBadURL),
            NSError(domain: NSURLErrorDomain, code: NSURLErrorUnsupportedURL),
            NSError(domain: NSURLErrorDomain, code: NSURLErrorUserAuthenticationRequired),
        ]

        for error in nonRetryableErrors {
            XCTAssertFalse(
                DownloadErrorRecovery.isRetryableForUser(error),
                "NSURLError code \(error.code) should NOT be retryable"
            )
        }
    }

    // MARK: - Unknown Errors

    func testUnknownError_notRetryable() {
        let unknownError = NSError(domain: "com.unknown", code: 42)
        XCTAssertFalse(
            DownloadErrorRecovery.isRetryableForUser(unknownError),
            "Unknown domain errors should NOT be retryable"
        )
    }
}
