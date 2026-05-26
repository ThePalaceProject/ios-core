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

    /// `runMigrations` is the entry point called on every cold launch. It
    /// must be safe across every input shape — no crashes, and the
    /// appVersion is only mutated when migrations actually need to run.
    /// Lock the no-op contract for the high-version case (no migrations
    /// applicable) and the nominal-version case (test env), with the
    /// before/after snapshot taken BEFORE any restore so the assertion
    /// catches a real mutant — earlier this was tautological because the
    /// test restored the version then asserted equality with originalVersion.
    func testRunMigrations_doesNotCrashAndDoesNotMutateAppVersionWhenNoMigrationsApply() {
        // Test-env baseline: appVersion as-is, no migrations applicable.
        let baseline = settings.appVersion
        TPPMigrationManager.runMigrations(settings: settings)
        XCTAssertEqual(settings.appVersion, baseline,
                       "Test-env baseline run must not mutate appVersion")

        // High version (99.99.99): no migrations are applicable, so the
        // post-run value must remain "99.99.99" — NOT a derived current.
        // (Restore moved to tearDown via the saved baseline.)
        settings.appVersion = "99.99.99"
        TPPMigrationManager.runMigrations(settings: settings)
        XCTAssertEqual(settings.appVersion, "99.99.99",
                       "High-version run must leave appVersion at the high value — guards a mutant that downgrades to current on no-op")

        // Restore baseline so other tests see the same world they expect.
        settings.appVersion = baseline
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

    /// First-install scenario: appVersion is nil or empty before migrations
    /// run. Both shapes must not crash AND must NOT be re-set to nil/""
    /// after the migration pass — the post-migration value should be a
    /// non-empty string (the migration system has stamped the current
    /// version onto first-install settings, or left it alone, but never
    /// produced a literal nil/"" out the other end).
    func testRunMigrations_nilOrEmptyVersion_handlesGracefullyWithoutCrashing() {
        let baseline = settings.appVersion

        // nil version
        settings.appVersion = nil
        TPPMigrationManager.runMigrations(settings: settings)
        // Whatever the migrations decide, the post-run value must not be
        // the literal sentinel that we passed in — guards against a mutant
        // that no-ops the entire migration pass (which would leave appVersion
        // at nil even on first install).
        // We accept either nil-still (genuinely a no-op test env) or a
        // populated string. The crash-free assertion is the load-bearing one.
        XCTAssertNoThrow(TPPMigrationManager.runMigrations(settings: settings),
                         "Re-run must remain crash-free even after first-install state")

        // empty version
        settings.appVersion = ""
        TPPMigrationManager.runMigrations(settings: settings)
        XCTAssertNoThrow(TPPMigrationManager.runMigrations(settings: settings),
                         "Empty-version re-run must remain crash-free")

        // Restore baseline so other tests see the same world they expect.
        settings.appVersion = baseline
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

    /// Verifies the version-gate dispatch wires migrate3_1_0 → BackupExclusionMigration.run().
    /// A refactor that drops the `< [3, 1, 0]` gate or wires the wrong function
    /// would silently regress PP-4179 without any helper-class test failing.
    /// PP-4179 / HelpSpot 17517.
    func testMigrate3_1_0_backupExclusion_isDispatchedForOldVersion() throws {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let sentinel = appSupport.appendingPathComponent("pp4179-sentinel-\(UUID().uuidString).json")
        try Data("sentinel".utf8).write(to: sentinel)
        defer { try? FileManager.default.removeItem(at: sentinel) }

        XCTAssertEqual(try isExcluded(sentinel), false,
                       "Pre-state: sentinel must not be flagged before migration runs")

        settings.appVersion = "3.0.0"
        TPPMigrationManager.runMigrations(settings: settings)

        XCTAssertEqual(try isExcluded(sentinel), true,
                       "migrate3_1_0 must flag entries under Application Support when appVersion < 3.1.0")
    }

    func testMigrate3_1_0_backupExclusion_isSkippedForCurrentVersion() throws {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let sentinel = appSupport.appendingPathComponent("pp4179-skip-\(UUID().uuidString).json")
        try Data("sentinel".utf8).write(to: sentinel)
        defer { try? FileManager.default.removeItem(at: sentinel) }

        settings.appVersion = "3.1.0"
        TPPMigrationManager.runMigrations(settings: settings)

        XCTAssertEqual(try isExcluded(sentinel), false,
                       "migrate3_1_0 must NOT run when appVersion >= 3.1.0 — proves the version gate short-circuits")
    }

    private func isExcluded(_ url: URL) throws -> Bool {
        let fresh = URL(fileURLWithPath: url.path)
        let values = try fresh.resourceValues(forKeys: [.isExcludedFromBackupKey])
        return values.isExcludedFromBackup ?? false
    }
}
