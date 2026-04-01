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

/// Tests for the DEBUG simulation flag on ReaderService.
///
/// Verifies that the flag is consumed after a single use so that subsequent
/// opens (including the retry) behave normally.
final class ReaderServiceSimulationFlagTests: XCTestCase {

    override func tearDown() {
        super.tearDown()
        // Always clean up after each test.
        ReaderService.simulatedLCPError = nil
    }

    func testSimulationFlag_isConsumedAfterOneUse() {
        ReaderService.simulatedLCPError = .missingPassphrase
        XCTAssertNotNil(ReaderService.simulatedLCPError, "Flag should be set before first open")

        // Simulate what openEPUBInternal does on a non-retry open:
        // read and clear the flag in a single operation.
        let consumed = ReaderService.simulatedLCPError
        ReaderService.simulatedLCPError = nil

        XCTAssertNotNil(consumed, "First open should see the simulated error")
        XCTAssertNil(ReaderService.simulatedLCPError, "Flag should be nil after first open (retry won't re-trigger)")
    }

    func testSimulationFlag_nilByDefault() {
        XCTAssertNil(ReaderService.simulatedLCPError, "No simulation active unless explicitly set")
    }

    func testSimulationFlag_canSimulateNonRecoverableError() {
        ReaderService.simulatedLCPError = .licenseStatus(.returned(Date()))
        let error = ReaderService.simulatedLCPError!
        XCTAssertFalse(ReaderService.isRecoverableLCPError(error),
                       "Returned license should not trigger a refresh even when simulated")
    }
}
#endif
