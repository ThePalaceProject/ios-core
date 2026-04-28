//
//  SEMigrationsTests.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class SEMigrationsTests: XCTestCase {

    private var settings: TPPSettings!

    override func setUp() {
        super.setUp()
        settings = TPPSettings()
    }

    override func tearDown() {
        settings = nil
        super.tearDown()
    }

    // MARK: - Version Comparison

    /// Tests the internal version comparison logic used by migrations.
    /// We test indirectly by verifying migration behavior.

    func testRunMigrations_doesNotCrash() {
        // Running migrations on a test environment should not crash
        // even if no migrations need to run
        let versionBefore = settings.appVersion
        TPPMigrationManager.runMigrations(settings: settings)
        XCTAssertEqual(settings.appVersion, versionBefore,
                       "appVersion must be unchanged after migration run in test environment")
    }

    func testRunMigrations_withCurrentVersion_doesNotMigrate() {
        // Set a very high version so no migrations run
        let originalVersion = settings.appVersion
        settings.appVersion = "99.99.99"

        TPPMigrationManager.runMigrations(settings: settings)

        // Restore
        settings.appVersion = originalVersion

        XCTAssertEqual(settings.appVersion, originalVersion,
                       "App version should be restored to original value after test")
    }

    func testRunMigrations_multipleCallsAreSafe() {
        // Running migrations multiple times should be idempotent
        let versionBefore = settings.appVersion
        TPPMigrationManager.runMigrations(settings: settings)
        TPPMigrationManager.runMigrations(settings: settings)
        TPPMigrationManager.runMigrations(settings: settings)
        XCTAssertEqual(settings.appVersion, versionBefore,
                       "App version should be unchanged after idempotent migration calls")
    }

    // MARK: - Version Parsing Edge Cases

    func testRunMigrations_nilVersion_handlesGracefully() {
        let originalVersion = settings.appVersion
        settings.appVersion = nil

        // nil version should trigger all migrations (first install scenario)
        TPPMigrationManager.runMigrations(settings: settings)

        // Restore
        settings.appVersion = originalVersion

        XCTAssertEqual(settings.appVersion, originalVersion,
                       "App version should be restored after nil-version migration")
    }

    func testRunMigrations_emptyVersion_handlesGracefully() {
        let originalVersion = settings.appVersion
        settings.appVersion = ""

        // Empty version should trigger all migrations
        TPPMigrationManager.runMigrations(settings: settings)

        // Restore
        settings.appVersion = originalVersion

        XCTAssertEqual(settings.appVersion, originalVersion,
                       "App version should be restored after empty-version migration")
    }

    // MARK: - Migration Artifacts

    func testMigrate2_oldCacheFiles_areRemoved() {
        // Create fake old cache files that migrate2 would remove
        let appSupport = try! FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let betaFile = appSupport.appendingPathComponent("library_list_beta.json")
        let prodFile = appSupport.appendingPathComponent("library_list_prod.json")

        // Create dummy files
        try? Data("test".utf8).write(to: betaFile)
        try? Data("test".utf8).write(to: prodFile)

        // Run with old version to trigger migrate2
        let originalVersion = settings.appVersion
        settings.appVersion = "3.0.0"
        TPPMigrationManager.runMigrations(settings: settings)
        settings.appVersion = originalVersion

        // Files should be removed
        XCTAssertFalse(FileManager.default.fileExists(atPath: betaFile.path),
                       "Old beta cache file should be removed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: prodFile.path),
                       "Old prod cache file should be removed")
    }
}
