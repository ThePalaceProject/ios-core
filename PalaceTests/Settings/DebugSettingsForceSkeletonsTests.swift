//
//  DebugSettingsForceSkeletonsTests.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//
//  Covers the `DebugSettings.forceSkeletons` QA/dev override (PP-4797). The
//  flag forces every first-load skeleton gate ON so the transient loading
//  placeholders can be inspected on the sim. Tests exercise the injectable
//  seam so they never touch `UserDefaults.standard`.
//

import XCTest
@testable import Palace

final class DebugSettingsForceSkeletonsTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "DebugSettingsForceSkeletonsTests.\(name)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testForceSkeletons_whenOverrideKeyUnset_isFalse() {
        XCTAssertFalse(DebugSettings.forceSkeletons(in: defaults))
    }

    func testForceSkeletons_whenOverrideKeySet_isTrueInDebug() {
        defaults.set(true, forKey: "PalaceForceSkeletons")
        #if DEBUG
        XCTAssertTrue(DebugSettings.forceSkeletons(in: defaults))
        #else
        // Release builds gate the override off entirely — production render
        // paths must be byte-identical regardless of the key.
        XCTAssertFalse(DebugSettings.forceSkeletons(in: defaults))
        #endif
    }

    /// Mutation guard: pins the exact override key. If the production read
    /// drifts to a similarly-named key, the decoy value makes this fail.
    func testForceSkeletons_readsExactKey_notADecoy() {
        defaults.set(false, forKey: "ForceSkeletons")       // decoy #1
        defaults.set(false, forKey: "PalaceForceSkeleton")  // decoy #2 (singular)
        defaults.set(true, forKey: "PalaceForceSkeletons")  // the real key
        #if DEBUG
        XCTAssertTrue(DebugSettings.forceSkeletons(in: defaults))
        #else
        XCTAssertFalse(DebugSettings.forceSkeletons(in: defaults))
        #endif
    }

    func testForceSkeletons_whenOverrideExplicitlyFalse_isFalse() {
        defaults.set(false, forKey: "PalaceForceSkeletons")
        XCTAssertFalse(DebugSettings.forceSkeletons(in: defaults))
    }
}
