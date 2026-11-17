//
//  BookOpenTrackerCleanupMigrationTests.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalacePreferences
@testable import Palace

/// Drives the launch entry point `TPPMigrationManager.migrate` against an
/// isolated defaults suite, with only the singleton-touching post-update and
/// LCP steps stood down, so the real versioned migrations run.
@MainActor
final class BookOpenTrackerCleanupMigrationTests: XCTestCase {

    private let suiteName = "BookOpenTrackerCleanupMigrationTests"
    private let legacyKey = "TPPBookLastOpenedAt"
    private let unrelatedKey = "BookOpenTrackerCleanupMigrationTests.unrelated"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        UserDefaults().removePersistentDomain(forName: suiteName)
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    /// An install upgrading from before 3.4.0 has the last-opened map the removed
    /// tracker wrote; launch must delete it and nothing else.
    func testMigrate_FromVersionBefore3_4_0_RemovesLastOpenedMapAndKeepsOtherKeys() async {
        seedLegacyState(appVersion: "3.3.1")

        await runLaunchMigrations()

        XCTAssertNil(defaults.object(forKey: legacyKey),
                     "Upgrading from 3.3.x must remove the book last-opened map")
        XCTAssertEqual(defaults.string(forKey: unrelatedKey), "keep",
                       "The cleanup must remove only the last-opened map")
    }

    /// The step is version-gated like every other migration: an install already
    /// stamped 3.4.0 has run the 3.4.0 migrations and does not re-run them.
    func testMigrate_FromVersion3_4_0_DoesNotRerunTheCleanup() async {
        seedLegacyState(appVersion: "3.4.0")

        await runLaunchMigrations()

        XCTAssertNotNil(defaults.dictionary(forKey: legacyKey),
                        "The 3.4.0 cleanup must not run for an install already at 3.4.0")
    }

    // MARK: - Helpers

    private func seedLegacyState(appVersion: String) {
        TPPSettings(defaults: defaults).appVersion = appVersion
        defaults.set(["book-1": Date(timeIntervalSince1970: 1_700_000_000)], forKey: legacyKey)
        defaults.set("keep", forKey: unrelatedKey)
    }

    private func runLaunchMigrations() async {
        var substitutions = MigrationSubstitutions()
        substitutions.performPostUpdateTasks = { }
        substitutions.lcpMigration = (defaults: defaults, work: { @Sendable in })

        let task = TPPMigrationManager.migrate(
            settings: TPPSettings(defaults: defaults),
            defaults: defaults,
            substituting: substitutions
        )
        await task?.value
    }
}
