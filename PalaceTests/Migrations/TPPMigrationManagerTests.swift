//
//  TPPMigrationManagerTests.swift
//  PalaceTests
//
//  Unit tests for TPPMigrationManager.version(_:isLessThan:) comparison logic.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalacePreferences
@testable import Palace

/// SRS: SET-001 — Migration version comparison drives upgrade paths
@MainActor
final class TPPMigrationManagerTests: XCTestCase {

    // MARK: - Equal versions

    func testVersion_equalVersions_returnsFalse() {
        XCTAssertFalse(TPPMigrationManager.version([1, 2, 3], isLessThan: [1, 2, 3]))
        // Symmetry: neither should be less than the other
        XCTAssertFalse(TPPMigrationManager.version([1, 2, 3], isLessThan: [1, 2, 3]),
                       "Identical versions must not be less than each other")
    }

    func testVersion_emptyArrays_returnsFalse() {
        XCTAssertFalse(TPPMigrationManager.version([], isLessThan: []))
        // Empty is not less than empty — symmetry
        XCTAssertFalse(TPPMigrationManager.version([], isLessThan: [0, 0, 0]),
                       "Empty version must not be less than all-zero version")
    }

    // MARK: - Clearly less-than

    func testVersion_majorLessThan_returnsTrue() {
        XCTAssertTrue(TPPMigrationManager.version([1, 0, 0], isLessThan: [2, 0, 0]))
        // Verify the inverse: 2.0.0 is not less than 1.0.0
        XCTAssertFalse(TPPMigrationManager.version([2, 0, 0], isLessThan: [1, 0, 0]),
                       "Greater major version must not be less than smaller major version")
    }

    func testVersion_minorLessThan_returnsTrue() {
        XCTAssertTrue(TPPMigrationManager.version([1, 2, 0], isLessThan: [1, 3, 0]))
        // Verify the inverse: 1.3.0 is not less than 1.2.0
        XCTAssertFalse(TPPMigrationManager.version([1, 3, 0], isLessThan: [1, 2, 0]),
                       "Greater minor version must not be less than smaller minor version")
    }

    func testVersion_patchLessThan_returnsTrue() {
        XCTAssertTrue(TPPMigrationManager.version([1, 2, 3], isLessThan: [1, 2, 4]))
        // Verify the inverse: 1.2.4 is not less than 1.2.3
        XCTAssertFalse(TPPMigrationManager.version([1, 2, 4], isLessThan: [1, 2, 3]),
                       "Greater patch version must not be less than smaller patch version")
    }

    // MARK: - Clearly greater-than

    func testVersion_majorGreaterThan_returnsFalse() {
        XCTAssertFalse(TPPMigrationManager.version([3, 0, 0], isLessThan: [2, 0, 0]))
        // The reverse must be true
        XCTAssertTrue(TPPMigrationManager.version([2, 0, 0], isLessThan: [3, 0, 0]),
                      "2.0.0 must be less than 3.0.0")
    }

    func testVersion_minorGreaterThan_returnsFalse() {
        XCTAssertFalse(TPPMigrationManager.version([1, 5, 0], isLessThan: [1, 3, 0]))
        // Verify the reverse is true
        XCTAssertTrue(TPPMigrationManager.version([1, 3, 0], isLessThan: [1, 5, 0]),
                      "1.3.0 must be less than 1.5.0")
    }

    // MARK: - Different-length versions

    func testVersion_shorterA_withNonZeroRemainder_returnsTrue() {
        // 1.2 < 1.2.1
        XCTAssertTrue(TPPMigrationManager.version([1, 2], isLessThan: [1, 2, 1]))
        // But 1.2 == 1.2.0, so must NOT be less than 1.2.0
        XCTAssertFalse(TPPMigrationManager.version([1, 2], isLessThan: [1, 2, 0]),
                       "1.2 must not be less than 1.2.0 — they are equivalent")
    }

    func testVersion_shorterA_withZeroRemainder_returnsFalse() {
        // 1.2 is NOT less than 1.2.0
        XCTAssertFalse(TPPMigrationManager.version([1, 2], isLessThan: [1, 2, 0]))
        // But 1.2 IS less than 1.2.1
        XCTAssertTrue(TPPMigrationManager.version([1, 2], isLessThan: [1, 2, 1]),
                      "1.2 must be less than 1.2.1 when the remainder is non-zero")
    }

    func testVersion_longerA_returnsFalse() {
        // 1.2.1 is NOT less than 1.2
        XCTAssertFalse(TPPMigrationManager.version([1, 2, 1], isLessThan: [1, 2]))
        // Verify the reverse: 1.2 < 1.2.1
        XCTAssertTrue(TPPMigrationManager.version([1, 2], isLessThan: [1, 2, 1]),
                      "Shorter version must be less than longer version with non-zero remainder")
    }

    // MARK: - Empty a (fresh install)

    func testVersion_emptyA_nonEmptyB_returnsTrue() {
        XCTAssertTrue(TPPMigrationManager.version([], isLessThan: [1, 0, 0]))
        // Multiple non-zero versions after empty must also return true
        XCTAssertTrue(TPPMigrationManager.version([], isLessThan: [2, 5, 3]),
                      "Empty version must be less than any version with a non-zero component")
    }

    func testVersion_emptyA_zeroB_returnsFalse() {
        // [] is NOT less than [0] because remaining b has no non-zero component
        XCTAssertFalse(TPPMigrationManager.version([], isLessThan: [0]))
        // But [] IS less than [1]
        XCTAssertTrue(TPPMigrationManager.version([], isLessThan: [1]),
                      "Empty version must be less than [1]")
    }

    func testVersion_emptyA_zeroZeroB_returnsFalse() {
        XCTAssertFalse(TPPMigrationManager.version([], isLessThan: [0, 0, 0]))
        // Confirm empty is treated as 0.0.0 equivalent
        XCTAssertFalse(TPPMigrationManager.version([0, 0, 0], isLessThan: []),
                       "0.0.0 must also not be less than empty (symmetric behavior)")
    }

    // MARK: - Single-component versions

    func testVersion_singleComponent_lessThan() {
        XCTAssertTrue(TPPMigrationManager.version([1], isLessThan: [2]))
        // The inverse must also hold
        XCTAssertFalse(TPPMigrationManager.version([2], isLessThan: [1]),
                       "[2] must not be less than [1]")
    }

    func testVersion_singleComponent_equal() {
        XCTAssertFalse(TPPMigrationManager.version([5], isLessThan: [5]))
        // Adjacent values must still compare correctly
        XCTAssertTrue(TPPMigrationManager.version([4], isLessThan: [5]),
                      "[4] must be less than [5]")
    }

    // MARK: - LCP keychain migration wiring (PP-5091)

    /// Nothing proved that launch actually reaches the LCP SQLite→Keychain
    /// migration. `LCPKeychainMigrationTests` covers `runIfNeeded` in isolation,
    /// which is worthless if `migrate` stops calling it — the migration would
    /// simply never run, every LCP license would fall back to re-validating from
    /// its stored `.lcpl`, and nothing anywhere would go red.
    ///
    /// This drives the real `migrate` with the two singleton-touching steps stubbed
    /// out, and asserts against the *migration flag* rather than against the
    /// injected closure: the flag is written by `LCPKeychainMigration.runIfNeeded`
    /// itself, so a green here means the call chain is intact end to end, not that
    /// `migrate` called something the test handed it.
    func testMigrate_runsTheLCPKeychainMigration() async {
        let suiteName = "TPPMigrationManagerTests.lcpWiring"
        guard let lcpDefaults = UserDefaults(suiteName: suiteName),
              let settingsDefaults = UserDefaults(suiteName: suiteName + ".settings") else {
            return XCTFail("Could not create isolated UserDefaults suites")
        }
        defer {
            lcpDefaults.removePersistentDomain(forName: suiteName)
            settingsDefaults.removePersistentDomain(forName: suiteName + ".settings")
        }
        lcpDefaults.removePersistentDomain(forName: suiteName)
        settingsDefaults.removePersistentDomain(forName: suiteName + ".settings")

        let copyRan = LockIsolated<Bool>(false)
        let otherStepsRan = LockIsolated<[String]>([])

        var substitutions = MigrationSubstitutions()
        substitutions.runMigrations = { _ in otherStepsRan.withValue { $0.append("runMigrations") } }
        substitutions.performPostUpdateTasks = { otherStepsRan.withValue { $0.append("postUpdateTasks") } }
        substitutions.lcpMigration = (defaults: lcpDefaults, work: { @Sendable in copyRan.value = true })

        let settings = TPPSettings(defaults: settingsDefaults)
        let task = TPPMigrationManager.migrate(settings: settings, substituting: substitutions)

        await task?.value

        XCTAssertEqual(otherStepsRan.value, ["runMigrations", "postUpdateTasks"],
                       "migrate must still run the ordinary migrations before the LCP one")
        XCTAssertNil(settings.appVersion,
                     "Substituting the migrations must NOT stamp appVersion — that stamp says the migrations ran, and they did not")
        // Both assertions are guarded together, not just the one that names an
        // LCP-only symbol. In a noDRM build `runLCPKeychainMigration` is empty, so
        // the substituted closure never runs and `copyRan` stays false — guarding
        // only the flag assertion would have left this one failing at runtime in
        // exactly the configuration the guard exists for. There is no noDRM test
        // target today, so both compile and run.
        #if LCP
        XCTAssertTrue(copyRan.value,
                      "migrate must reach the LCP keychain copy")
        XCTAssertTrue(lcpDefaults.bool(forKey: LCPKeychainMigration.didMigrateKey),
                      "The flag is written by LCPKeychainMigration.runIfNeeded — its absence means migrate never reached it, whatever else ran")
        #endif
    }

    /// The launch path deliberately does NOT await the returned task, so the task
    /// has to exist for anyone to be able to. Before PP-5091 the migration was a
    /// bare `Task { … }` with no handle, which is why the race in
    /// `docs/architecture/lcp-device-id-migration-validation.md` had no seam to
    /// close and no way to be observed.
    func testMigrate_returnsAHandleOnTheLCPMigrationRatherThanDiscardingIt() async {
        let suiteName = "TPPMigrationManagerTests.lcpHandle"
        guard let lcpDefaults = UserDefaults(suiteName: suiteName),
              let settingsDefaults = UserDefaults(suiteName: suiteName + ".settings") else {
            return XCTFail("Could not create isolated UserDefaults suites")
        }
        defer {
            lcpDefaults.removePersistentDomain(forName: suiteName)
            settingsDefaults.removePersistentDomain(forName: suiteName + ".settings")
        }
        lcpDefaults.removePersistentDomain(forName: suiteName)

        let finished = LockIsolated<Bool>(false)

        var substitutions = MigrationSubstitutions()
        substitutions.runMigrations = { _ in }
        substitutions.performPostUpdateTasks = { }
        substitutions.lcpMigration = (defaults: lcpDefaults, work: { @Sendable in
            try? await Task.sleep(nanoseconds: 1_000_000)
            finished.value = true
        })

        let task = TPPMigrationManager.migrate(
            settings: TPPSettings(defaults: settingsDefaults),
            substituting: substitutions
        )

        // No assertion that the work is *still* in flight here: `migrate` returns
        // before the Task's first suspension, but the test cannot force that
        // ordering, and an assertion whose interleaving the test cannot force is
        // not evidence.
        XCTAssertNotNil(task, "migrate must hand back the migration task")
        await task?.value
        XCTAssertTrue(finished.value,
                      "Awaiting the returned task must mean the migration has finished")
    }
}
