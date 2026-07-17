//
//  LCPKeychainMigrationTests.swift
//  PalaceTests
//
//  Verifies the one-time gating contract of the LCP SQLite→Keychain
//  migration: it runs once when unflagged, skips when already done, and
//  leaves the flag unset on failure so the next launch retries. The actual
//  Readium repository copy is injected so these tests never touch the real
//  Keychain.
//

#if LCP

import XCTest
@testable import Palace

@MainActor
final class LCPKeychainMigrationTests: XCTestCase {

    private let suiteName = "LCPKeychainMigrationTests.suite"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testRunIfNeeded_whenFlagUnset_runsMigrationAndSetsFlag() async {
        var ran = false

        await LCPKeychainMigration.runIfNeeded(defaults: defaults, migrate: { ran = true })

        XCTAssertTrue(ran, "Migration work must run when the flag is unset")
        XCTAssertTrue(defaults.bool(forKey: LCPKeychainMigration.didMigrateKey),
                      "Flag must be set after a successful migration")
    }

    func testRunIfNeeded_whenFlagAlreadySet_skipsMigration() async {
        defaults.set(true, forKey: LCPKeychainMigration.didMigrateKey)
        var ran = false

        await LCPKeychainMigration.runIfNeeded(defaults: defaults, migrate: { ran = true })

        XCTAssertFalse(ran, "Migration work must NOT run once the flag is set")
    }

    func testRunIfNeeded_whenMigrationThrows_leavesFlagUnsetAndRetriesNextTime() async {
        struct MigrationError: Error {}
        var attempts = 0

        await LCPKeychainMigration.runIfNeeded(defaults: defaults, migrate: {
            attempts += 1
            throw MigrationError()
        })

        XCTAssertEqual(attempts, 1, "Migration should have been attempted once")
        XCTAssertFalse(defaults.bool(forKey: LCPKeychainMigration.didMigrateKey),
                       "Flag must stay unset on failure so the next launch retries")

        // A subsequent launch must retry because the flag is still unset.
        await LCPKeychainMigration.runIfNeeded(defaults: defaults, migrate: {
            attempts += 1
            throw MigrationError()
        })

        XCTAssertEqual(attempts, 2, "An unflagged failed migration must retry on the next run")
    }
}

#endif
