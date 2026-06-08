//
//  DeveloperSettingsTierTests.swift
//  PalaceTests
//
//  Pins the Developer/Support tier visibility logic
//  (`TPPDeveloperSettingsTableViewController.shouldShowEngineeringTools`).
//
//  Regression guard for the 2026-06-08 simdrive finding: the original
//  receipt-NAME-only check ("lastPathComponent != \"receipt\"") wrongly HID the
//  engineering tier on DEBUG/simulator builds, because those report an
//  `appStoreReceiptURL` whose lastPathComponent IS "receipt" but whose file
//  does not exist. Hiding must require the receipt to ALSO be present on disk
//  (a real App Store install). Build + unit tests passed while this was broken;
//  only driving the sim surfaced it — so this test makes the path provable.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class DeveloperSettingsTierTests: XCTestCase {

    private func decide(_ receiptURL: URL?, exists: Bool) -> Bool {
        TPPDeveloperSettingsTableViewController.shouldShowEngineeringTools(
            receiptURL: receiptURL,
            fileExists: { _ in exists }
        )
    }

    /// Real App Store install: receipt named "receipt" AND present on disk →
    /// engineering tools HIDDEN (production users see only the Support tier).
    func testAppStoreProductionReceipt_hidesEngineeringTools() {
        let url = URL(fileURLWithPath: "/var/app/StoreKit/receipt")
        XCTAssertFalse(decide(url, exists: true),
                       "A production App Store receipt that exists on disk must hide engineering tools")
    }

    /// DEBUG / simulator build: URL lastPathComponent is "receipt" but the file
    /// does NOT exist → engineering tools SHOWN. This is the exact case the
    /// name-only check got wrong.
    func testDebugReceiptNamedReceiptButMissingOnDisk_showsEngineeringTools() {
        let url = URL(fileURLWithPath: "/var/app/StoreKit/receipt")
        XCTAssertTrue(decide(url, exists: false),
                      "A 'receipt'-named URL whose file is absent (DEBUG/sim) must SHOW engineering tools — the regression simdrive caught")
    }

    /// TestFlight: sandboxReceipt → engineering tools SHOWN (QA needs them).
    func testTestFlightSandboxReceipt_showsEngineeringTools() {
        let url = URL(fileURLWithPath: "/var/app/StoreKit/sandboxReceipt")
        XCTAssertTrue(decide(url, exists: true),
                      "TestFlight (sandboxReceipt) must show engineering tools regardless of file presence")
    }

    /// No receipt URL at all (dev) → engineering tools SHOWN.
    func testNoReceiptURL_showsEngineeringTools() {
        XCTAssertTrue(decide(nil, exists: false),
                      "Absent receipt URL means a dev build — show engineering tools")
    }
}
