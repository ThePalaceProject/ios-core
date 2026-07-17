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

@MainActor
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

    // NOTE on the DEBUG gate: `forceSkeletons` compiles in the *Palace* module,
    // whose Debug config defines DEBUG — so the Debug-built app these tests link
    // against DOES honor the override. The `PalaceTests` target itself does NOT
    // define DEBUG (its compilation conditions are `LCP FEATURE_OVERDRIVE`), so a
    // `#if DEBUG` written here would mis-evaluate and diverge from the app under
    // test. Gate on `DebugSettings.honorsForceSkeletonsOverride` — the Palace
    // module's own compile-time truth — so the expectation always matches reality.

    func testForceSkeletons_whenOverrideKeySet_isHonoredPerBuild() {
        defaults.set(true, forKey: "PalaceForceSkeletons")
        if DebugSettings.honorsForceSkeletonsOverride {
            XCTAssertTrue(DebugSettings.forceSkeletons(in: defaults),
                          "A build that honors the override must read PalaceForceSkeletons=true as true")
        } else {
            // Release builds gate the override off entirely — production render
            // paths must be byte-identical regardless of the key.
            XCTAssertFalse(DebugSettings.forceSkeletons(in: defaults),
                           "A release build must ignore the override and return false")
        }
    }

    /// Mutation guard: pins the exact override key. If the production read
    /// drifts to a similarly-named key, the decoy value makes this fail.
    func testForceSkeletons_readsExactKey_notADecoy() {
        defaults.set(false, forKey: "ForceSkeletons")       // decoy #1
        defaults.set(false, forKey: "PalaceForceSkeleton")  // decoy #2 (singular)
        defaults.set(true, forKey: "PalaceForceSkeletons")  // the real key
        if DebugSettings.honorsForceSkeletonsOverride {
            XCTAssertTrue(DebugSettings.forceSkeletons(in: defaults),
                          "Must read the exact key PalaceForceSkeletons, not a decoy")
        } else {
            XCTAssertFalse(DebugSettings.forceSkeletons(in: defaults))
        }
    }

    func testForceSkeletons_whenOverrideExplicitlyFalse_isFalse() {
        defaults.set(false, forKey: "PalaceForceSkeletons")
        XCTAssertFalse(DebugSettings.forceSkeletons(in: defaults))
    }
}
