//
//  ReaderServiceLCPTests.swift
//  PalaceTests
//
//  Tests for LCP license refresh recovery logic in ReaderService.
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
#if LCP
import ReadiumLCP
#endif
@testable import Palace

#if LCP
/// Tests for the LCP error classification used to decide when to attempt a
/// silent license refresh before surfacing "Content Protection Error" to the user.
///
/// Recoverable errors (missingPassphrase, network, crlFetching, licenseIntegrity)
/// are those that may be fixed by re-fetching a fresh license from the CM.
/// Definitive status errors (expired, returned, revoked, cancelled) must NOT
/// trigger a refresh — the loan is genuinely over and the user should be told clearly.
final class ReaderServiceLCPErrorClassificationTests: XCTestCase {

    // MARK: - Recoverable errors

    func testMissingPassphrase_isRecoverable() {
        XCTAssertTrue(ReaderService.isRecoverableLCPError(.missingPassphrase))
    }

    func testNetworkError_isRecoverable() {
        XCTAssertTrue(ReaderService.isRecoverableLCPError(.network(nil)))
    }

    func testNetworkError_withUnderlyingError_isRecoverable() {
        let underlying = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        XCTAssertTrue(ReaderService.isRecoverableLCPError(.network(underlying)))
    }

    func testCRLFetching_isRecoverable() {
        XCTAssertTrue(ReaderService.isRecoverableLCPError(.crlFetching))
    }

    func testLicenseIntegrity_isRecoverable() {
        XCTAssertTrue(ReaderService.isRecoverableLCPError(.licenseIntegrity(.licenseSignatureInvalid)))
    }

    // MARK: - Non-recoverable (definitive status) errors

    func testExpiredLicense_isNotRecoverable() {
        let now = Date()
        XCTAssertFalse(ReaderService.isRecoverableLCPError(
            .licenseStatus(.expired(start: now.addingTimeInterval(-86400), end: now.addingTimeInterval(-3600)))
        ))
    }

    func testReturnedLicense_isNotRecoverable() {
        XCTAssertFalse(ReaderService.isRecoverableLCPError(
            .licenseStatus(.returned(Date()))
        ))
    }

    func testRevokedLicense_isNotRecoverable() {
        XCTAssertFalse(ReaderService.isRecoverableLCPError(
            .licenseStatus(.revoked(Date(), devicesCount: 2))
        ))
    }

    func testCancelledLicense_isNotRecoverable() {
        XCTAssertFalse(ReaderService.isRecoverableLCPError(
            .licenseStatus(.cancelled(Date()))
        ))
    }

    // MARK: - Other non-recoverable errors

    func testLicenseIsBusy_isNotRecoverable() {
        XCTAssertFalse(ReaderService.isRecoverableLCPError(.licenseIsBusy))
    }

    func testLicenseProfileNotSupported_isNotRecoverable() {
        XCTAssertFalse(ReaderService.isRecoverableLCPError(.licenseProfileNotSupported))
    }

    func testParsingError_isNotRecoverable() {
        XCTAssertFalse(ReaderService.isRecoverableLCPError(.parsing(.malformedJSON)))
    }

    func testUnknownError_isNotRecoverable() {
        XCTAssertFalse(ReaderService.isRecoverableLCPError(.unknown(nil)))
    }
}
#endif
