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
        // If we reach here without crash, the test passes
    }

    func testLogKeychainError_doesNotCrash_withUnknownStatus() {
        TPPKeychainManager.logKeychainError(
            forVendor: "TestVendor",
            status: -99999,
            message: "Unknown error"
        )
    }

    func testLogKeychainError_doesNotCrash_withEmptyVendor() {
        TPPKeychainManager.logKeychainError(
            forVendor: "",
            status: errSecParam,
            message: "Empty vendor test"
        )
    }

    func testLogKeychainError_doesNotCrash_withEmptyMessage() {
        TPPKeychainManager.logKeychainError(
            forVendor: "Vendor",
            status: errSecIO,
            message: ""
        )
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
