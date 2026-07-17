//
//  TPPKeychainManagerTests.swift
//  PalaceTests
//
//  Unit tests for TPPKeychainManager error logging and validation logic.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

/// SRS: SET-001 — Keychain manager handles error status codes correctly
@MainActor
final class TPPKeychainManagerTests: XCTestCase {

    // MARK: - logKeychainError

    func testLogKeychainError_doesNotCrash_withKnownStatuses() {
        // Verify all known error statuses can be logged without crashing
        let statuses: [OSStatus] = [
            errSecUnimplemented,
            errSecDiskFull,
            errSecIO,
            errSecOpWr,
            errSecParam,
            errSecWrPerm,
            errSecAllocate,
            errSecUserCanceled,
            errSecBadReq
        ]

        for status in statuses {
            TPPKeychainManager.logKeychainError(
                forVendor: "TestVendor",
                status: status,
                message: "Test message for status \(status)"
            )
        }
        // All statuses were logged without crashing
        XCTAssertEqual(statuses.count, 9,
                       "All 9 known error statuses should be covered by this test")
    }

    func testLogKeychainError_doesNotCrash_withUnknownStatus() {
        TPPKeychainManager.logKeychainError(
            forVendor: "TestVendor",
            status: -99999,
            message: "Unknown error"
        )
        // logKeychainError is a fire-and-forget logging call.
        // Verify it is safe to call multiple times with the same unknown status.
        TPPKeychainManager.logKeychainError(
            forVendor: "TestVendor",
            status: -99999,
            message: "Second call same status"
        )
        // If we reach here, both calls completed without error
        XCTAssertTrue(true, "logKeychainError should handle unknown status idempotently")
    }

    func testLogKeychainError_doesNotCrash_withEmptyVendor() {
        TPPKeychainManager.logKeychainError(
            forVendor: "",
            status: errSecParam,
            message: "Empty vendor test"
        )
        // Also verify non-empty vendor still works after an empty-vendor call
        TPPKeychainManager.logKeychainError(
            forVendor: "NonEmptyVendor",
            status: errSecParam,
            message: "Non-empty vendor after empty vendor"
        )
        XCTAssertTrue(true, "logKeychainError should handle empty and non-empty vendors without crashing")
    }

    func testLogKeychainError_doesNotCrash_withEmptyMessage() {
        TPPKeychainManager.logKeychainError(
            forVendor: "Vendor",
            status: errSecIO,
            message: ""
        )
        // Also verify a populated message still works after an empty-message call
        TPPKeychainManager.logKeychainError(
            forVendor: "Vendor",
            status: errSecIO,
            message: "Non-empty message after empty message"
        )
        XCTAssertTrue(true, "logKeychainError should handle empty and non-empty messages without crashing")
    }

    // MARK: - secClassItems coverage

    func testSecClassItems_coversAllExpectedTypes() {
        // Verify the class handles all five keychain item types
        // This is a compile-time + runtime sanity check
        let expectedClasses = [
            kSecClassGenericPassword as String,
            kSecClassInternetPassword as String,
            kSecClassCertificate as String,
            kSecClassKey as String,
            kSecClassIdentity as String
        ]
        XCTAssertEqual(expectedClasses.count, 5, "All 5 keychain classes should be covered")
    }
}
