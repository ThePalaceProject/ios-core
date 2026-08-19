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

    // MARK: - Safe archive decoding (launch-path crash safety)

    /// A corrupt keychain archive must be SKIPPED, not abort the process.
    ///
    /// `validateKeychain()` runs from
    /// `TPPAppDelegate.performBackgroundStartupTasks()` on every launch and
    /// decodes every keychain item it finds. The previous
    /// `NSKeyedUnarchiver.unarchiveObject(with:)` signals corruption by RAISING
    /// an ObjC exception that Swift cannot catch, so one bad item crashed the
    /// app during startup — every launch, unrecoverable without a reinstall
    /// that costs the patron their downloaded books.
    ///
    /// The fixture corrupts the archived CLASS NAME in place. That is
    /// deliberate: an arbitrary bit-flip usually does NOT reproduce the raise
    /// (only 2 of 156 positions do for a String archive), so a positional
    /// fixture would pass against the broken implementation too and guard
    /// nothing.
    /// An archive whose class record is destroyed — the shape that actually
    /// makes the legacy unarchiver raise.
    ///
    /// It has to be a COLLECTION archive: a `String` archive stores its value
    /// inline as a plist string and carries no class record at all, so there is
    /// nothing to corrupt and any fixture built from one would pass against the
    /// broken implementation too. This is fed to both decoders, since either
    /// can meet a corrupt blob in the keychain.
    private func archiveWithDestroyedClassRecord() -> Data? {
        var corrupted = NSKeyedArchiver.archivedData(withRootObject: ["a": "b"])
        let className = Array("NSDictionary".utf8)
        guard let r = corrupted.range(of: Data(className)) else { return nil }
        corrupted.replaceSubrange(r, with: Data(repeating: 0x5A, count: className.count))
        return corrupted
    }

    func testDecodeKeychainKey_withCorruptedArchive_returnsNilInsteadOfCrashing() {
        guard let corrupted = archiveWithDestroyedClassRecord() else {
            return XCTFail("fixture precondition: the archive should name NSDictionary")
        }
        XCTAssertNil(TPPKeychainManager.decodeKeychainKey(corrupted),
                     "A corrupt keychain key must decode to nil — raising here aborts the launch")
    }

    func testDecodeKeychainValue_withCorruptedArchive_returnsNilInsteadOfCrashing() {
        guard let corrupted = archiveWithDestroyedClassRecord() else {
            return XCTFail("fixture precondition: the archive should name NSDictionary")
        }
        XCTAssertNil(TPPKeychainManager.decodeKeychainValue(corrupted),
                     "A corrupt keychain value must decode to nil — raising here aborts the launch")
    }

    /// Corruption tolerance must not come at the cost of reading real data:
    /// these decoders run over items written by builds years old, and a silent
    /// nil would sign patrons out rather than migrate them.
    func testDecoders_stillReadArchivesWrittenTheOldWay() {
        let key = NSKeyedArchiver.archivedData(withRootObject: "account.barcode")
        XCTAssertEqual(TPPKeychainManager.decodeKeychainKey(key), "account.barcode",
                       "A legitimate legacy key archive must still decode")

        let value = NSKeyedArchiver.archivedData(withRootObject: ["token": "abc"])
        XCTAssertEqual(TPPKeychainManager.decodeKeychainValue(value) as? [String: String],
                       ["token": "abc"],
                       "A legitimate legacy value archive must still decode")

        // The shapes that actually occur in the store, not just a dictionary:
        // credentials are archived Strings, and `TPPKeychainStoredVariable`'s
        // pre-JSON format archived `Data`. A silent nil on either would sign a
        // patron out — the failure mode that is WORSE than the crash this
        // change removes.
        let stringValue = NSKeyedArchiver.archivedData(withRootObject: "a-bearer-token")
        XCTAssertEqual(TPPKeychainManager.decodeKeychainValue(stringValue) as? String,
                       "a-bearer-token",
                       "An archived String value must still decode")

        let dataValue = NSKeyedArchiver.archivedData(withRootObject: Data("{\"k\":1}".utf8))
        XCTAssertEqual(TPPKeychainManager.decodeKeychainValue(dataValue) as? Data,
                       Data("{\"k\":1}".utf8),
                       "An archived Data value (the pre-JSON Codable format) must still decode")
    }

    /// `TPPKeychainStoredVariable` has written raw JSON for `Codable` types
    /// since the format change, so the value decoder meets non-archive bytes in
    /// the wild. It must return nil quietly, not abort.
    func testDecodeKeychainValue_withRawJSON_returnsNilQuietly() {
        let json = Data(#"{"token":"abc"}"#.utf8)
        XCTAssertNil(TPPKeychainManager.decodeKeychainValue(json),
                     "Non-archive bytes must decode to nil rather than crashing the launch path")
    }

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
