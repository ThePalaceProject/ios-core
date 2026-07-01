//
//  RemoteFeatureFlagsSideLoadingTests.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

/// Behavior specs for the `sideLoadingEnabled` feature-flag resolution
/// (swarm_495a88d9, Module B — PP-2679 / PP-2677).
///
/// These tests pin the RESOLUTION PRECEDENCE, not the default value:
///   1. UserDefaults local override (either direction) wins.
///   2. No override → Firebase Remote Config (default `false`) — side loading is
///      a test-only feature, OFF by default, enabled via the dev-menu toggle.
///
/// Every test constructs a fresh `RemoteFeatureFlags(defaults:)` with a
/// per-suite `UserDefaults` so override-key state never leaks — `.shared` is
/// never touched.
final class RemoteFeatureFlagsSideLoadingTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "RemoteFeatureFlagsSideLoadingTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - Local override precedence (both directions)

    /// Override set to `true` → accessor returns `true`. If the accessor
    /// ignored the override and read only the DEBUG/Firebase fallback, this
    /// would still pass in DEBUG — which is why the `false` case below is the
    /// load-bearing assertion. This one pins the on-direction of the override.
    func testIsSideLoadingEnabled_whenLocalOverrideTrue_returnsTrue() {
        let sut = RemoteFeatureFlags(defaults: defaults)
        defaults.set(true, forKey: RemoteFeatureFlags.sideLoadingLocalOverrideKey)

        XCTAssertTrue(sut.isSideLoadingEnabled,
                      "A local override of true must resolve isSideLoadingEnabled to true")
    }

    /// Override set to `false` → accessor returns `false` EVEN IN DEBUG, where
    /// the fallback would otherwise return `true`. This is the precedence
    /// proof: it fails if the override check is dropped or the precedence is
    /// inverted (fallback consulted before the override).
    func testIsSideLoadingEnabled_whenLocalOverrideFalse_returnsFalse_overridingDebugDefault() {
        let sut = RemoteFeatureFlags(defaults: defaults)
        defaults.set(false, forKey: RemoteFeatureFlags.sideLoadingLocalOverrideKey)

        XCTAssertFalse(sut.isSideLoadingEnabled,
                       "A local override of false must win over the DEBUG-on / Firebase fallback")
    }

    /// Full round-trip through the single production seam: true → false → true.
    /// Proves the accessor re-reads the override on every call (no cached
    /// first-read) and that both write directions are honored via the same key.
    func testIsSideLoadingEnabled_overrideRoundTrip_true_false_true() {
        let sut = RemoteFeatureFlags(defaults: defaults)

        defaults.set(true, forKey: RemoteFeatureFlags.sideLoadingLocalOverrideKey)
        XCTAssertTrue(sut.isSideLoadingEnabled, "override=true → true")

        defaults.set(false, forKey: RemoteFeatureFlags.sideLoadingLocalOverrideKey)
        XCTAssertFalse(sut.isSideLoadingEnabled, "override flipped to false → false")

        defaults.set(true, forKey: RemoteFeatureFlags.sideLoadingLocalOverrideKey)
        XCTAssertTrue(sut.isSideLoadingEnabled, "override flipped back to true → true")
    }

    // MARK: - No override → defers to Remote Config

    /// With NO local override present, `isSideLoadingEnabled` must defer to
    /// Firebase Remote Config (`isFeatureEnabled(.sideLoadingEnabled)`) rather
    /// than a build-time `#if DEBUG` default. Side loading is a test-only feature
    /// that is OFF by default and enabled via the dev-menu toggle, so the
    /// no-override path is exactly the Remote Config value.
    ///
    /// This pins that the accessor's fallback is the Remote Config seam (so
    /// remote gating actually works) and that no override silently forces it on.
    /// The override-drop / precedence-inversion mutants are killed by the
    /// override-direction tests above (override=true must return true even though
    /// the Remote Config default is false).
    func testIsSideLoadingEnabled_noOverride_defersToRemoteConfig() {
        let sut = RemoteFeatureFlags(defaults: defaults)
        XCTAssertNil(defaults.object(forKey: RemoteFeatureFlags.sideLoadingLocalOverrideKey),
                     "Precondition: fresh suite must have no side-loading override")

        XCTAssertEqual(sut.isSideLoadingEnabled, sut.isFeatureEnabled(.sideLoadingEnabled),
                       "With no local override, isSideLoadingEnabled must defer to Remote Config (isFeatureEnabled)")
    }

    // MARK: - Flag / RemoteConfig wiring

    /// The FeatureFlag case must map to a FirebaseManager RemoteConfigKey so the
    /// release-path (`isFeatureEnabled`) actually consults Remote Config instead
    /// of silently falling through to `defaultValue`. A nil managerKey would
    /// break remote gating — this pins the mapping exists.
    func testSideLoadingFeatureFlag_mapsToRemoteConfigKey() {
        XCTAssertEqual(RemoteFeatureFlags.FeatureFlag.sideLoadingEnabled.managerKey,
                       .sideLoadingEnabled,
                       "sideLoadingEnabled FeatureFlag must map to the sideLoadingEnabled RemoteConfigKey")
    }
}
