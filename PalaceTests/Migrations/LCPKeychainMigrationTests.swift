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

// Deliberately NOT @MainActor: `LCPKeychainMigration.runIfNeeded` is a
// nonisolated async API taking a (non-Sendable) UserDefaults and non-Sendable
// closures — driving it from a @MainActor test is a Swift 6 sending error,
// while from a nonisolated test everything stays in one isolation domain.
// Nothing here touches UI or main-actor state.
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
        let ran = LockIsolated<Bool>(false)
        let localDefaults = UserDefaults(suiteName: suiteName)!

        await LCPKeychainMigration.runIfNeeded(defaults: localDefaults, migrate: { @Sendable in ran.value = true })

        XCTAssertTrue(ran.value, "Migration work must run when the flag is unset")
        XCTAssertTrue(defaults.bool(forKey: LCPKeychainMigration.didMigrateKey),
                      "Flag must be set after a successful migration")
    }

    func testRunIfNeeded_whenFlagAlreadySet_skipsMigration() async {
        defaults.set(true, forKey: LCPKeychainMigration.didMigrateKey)
        let ran = LockIsolated<Bool>(false)
        let localDefaults = UserDefaults(suiteName: suiteName)!

        await LCPKeychainMigration.runIfNeeded(defaults: localDefaults, migrate: { @Sendable in ran.value = true })

        XCTAssertFalse(ran.value, "Migration work must NOT run once the flag is set")
    }

    func testRunIfNeeded_whenMigrationThrows_leavesFlagUnsetAndRetriesNextTime() async {
        struct MigrationError: Error {}
        let attempts = LockIsolated<Int>(0)
        let localDefaults = UserDefaults(suiteName: suiteName)!

        await LCPKeychainMigration.runIfNeeded(defaults: localDefaults, migrate: { @Sendable in
            attempts.value += 1
            throw MigrationError()
        })

        XCTAssertEqual(attempts.value, 1, "Migration should have been attempted once")
        XCTAssertFalse(defaults.bool(forKey: LCPKeychainMigration.didMigrateKey),
                       "Flag must stay unset on failure so the next launch retries")

        // A subsequent launch must retry because the flag is still unset.
        await LCPKeychainMigration.runIfNeeded(defaults: localDefaults, migrate: { @Sendable in
            attempts.value += 1
            throw MigrationError()
        })

        XCTAssertEqual(attempts.value, 2, "An unflagged failed migration must retry on the next run")
    }
}

#endif
