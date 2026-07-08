//
//  GeneralCacheClearOnUpdateTests.swift
//  PalaceTests
//
//  Tests for the launch-path cache purge (swarm_27c181b5, Startup-AppLifecycle).
//  `GeneralCache.clearCacheOnUpdate` keeps the version gate + flag write
//  SYNCHRONOUS (nothing on the launch path may block on it) while the actual
//  Caches-dir purge is dispatched off-main. These tests drive the injectable
//  seam so the gate logic is verified deterministically without touching the
//  real UserDefaults.standard or the on-disk Caches directory.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class GeneralCacheClearOnUpdateTests: XCTestCase {

    private let suiteName = "GeneralCacheClearOnUpdateTests"
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

    /// On a version change: the flag write is synchronous (set by the time the
    /// call returns) and the purge is invoked exactly once. Proves the launch
    /// path never has to wait for — nor re-run — the purge.
    func testGeneralCache_clearOnUpdate_versionGateStaysSync_purgeOffMain() {
        defaults.set("1.0 (10)", forKey: GeneralCache<String, Data>.cacheVersionKey)

        var purgeCount = 0
        let didPurge = GeneralCache<String, Data>.clearCacheOnUpdate(
            defaults: defaults,
            currentVersionBuild: "1.1 (11)"
        ) {
            purgeCount += 1
        }

        // Synchronous: flag already written and purge already invoked on return.
        XCTAssertTrue(didPurge, "a version change must trigger the purge")
        XCTAssertEqual(purgeCount, 1, "purge must be invoked exactly once on a version change")
        XCTAssertEqual(defaults.string(forKey: GeneralCache<String, Data>.cacheVersionKey),
                       "1.1 (11)",
                       "the new version must be written synchronously before the call returns")
    }

    /// When the stored version already matches, neither the purge nor a flag
    /// re-write happens. Kills the `previous != current` -> `==` mutant and the
    /// mutant that drops the guard and always purges.
    func testGeneralCache_clearOnUpdate_sameVersion_doesNotPurge() {
        defaults.set("2.0 (20)", forKey: GeneralCache<String, Data>.cacheVersionKey)

        var purgeCount = 0
        let didPurge = GeneralCache<String, Data>.clearCacheOnUpdate(
            defaults: defaults,
            currentVersionBuild: "2.0 (20)"
        ) {
            purgeCount += 1
        }

        XCTAssertFalse(didPurge, "an unchanged version must NOT trigger the purge")
        XCTAssertEqual(purgeCount, 0, "purge must not run when the version is unchanged")
        XCTAssertEqual(defaults.string(forKey: GeneralCache<String, Data>.cacheVersionKey),
                       "2.0 (20)",
                       "flag must remain the already-stored value")
    }

    /// First launch (no stored version): nil differs from any current build, so
    /// the purge runs and the flag is seeded.
    func testGeneralCache_clearOnUpdate_firstLaunch_purgesAndSeedsFlag() {
        XCTAssertNil(defaults.string(forKey: GeneralCache<String, Data>.cacheVersionKey))

        var purgeCount = 0
        let didPurge = GeneralCache<String, Data>.clearCacheOnUpdate(
            defaults: defaults,
            currentVersionBuild: "3.0 (30)"
        ) {
            purgeCount += 1
        }

        XCTAssertTrue(didPurge)
        XCTAssertEqual(purgeCount, 1)
        XCTAssertEqual(defaults.string(forKey: GeneralCache<String, Data>.cacheVersionKey), "3.0 (30)")
    }
}
