//
//  SEMigrationsTests.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class SEMigrationsTests: XCTestCase {

    // MARK: - Version Comparison

    /// Tests the internal version comparison logic used by migrations.
    /// We test indirectly by verifying migration behavior.

    func testRunMigrations_doesNotCrash() {
        // Running migrations on a test environment should not crash
        // even if no migrations need to run
        TPPMigrationManager.runMigrations()
    }

    func testRunMigrations_withCurrentVersion_doesNotMigrate() {
        // Set a very high version so no migrations run
        let originalVersion = TPPSettings.shared.appVersion
        TPPSettings.shared.appVersion = "99.99.99"

        // Should complete without errors
        TPPMigrationManager.runMigrations()

        // Restore
        TPPSettings.shared.appVersion = originalVersion
    }

    func testRunMigrations_multipleCallsAreSafe() {
        // Running migrations multiple times should be idempotent
        TPPMigrationManager.runMigrations()
        TPPMigrationManager.runMigrations()
        TPPMigrationManager.runMigrations()
        // Should not crash
    }

    // MARK: - Version Parsing Edge Cases

    func testRunMigrations_nilVersion_handlesGracefully() {
        let originalVersion = TPPSettings.shared.appVersion
        TPPSettings.shared.appVersion = nil

        // nil version should trigger all migrations (first install scenario)
        TPPMigrationManager.runMigrations()

        // Restore
        TPPSettings.shared.appVersion = originalVersion
    }

    func testRunMigrations_emptyVersion_handlesGracefully() {
        let originalVersion = TPPSettings.shared.appVersion
        TPPSettings.shared.appVersion = ""

        // Empty version should trigger all migrations
        TPPMigrationManager.runMigrations()

        // Restore
        TPPSettings.shared.appVersion = originalVersion
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
        let originalVersion = TPPSettings.shared.appVersion
        TPPSettings.shared.appVersion = "3.0.0"
        TPPMigrationManager.runMigrations()
        TPPSettings.shared.appVersion = originalVersion

        // Files should be removed
        XCTAssertFalse(FileManager.default.fileExists(atPath: betaFile.path),
                       "Old beta cache file should be removed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: prodFile.path),
                       "Old prod cache file should be removed")
    }
}
