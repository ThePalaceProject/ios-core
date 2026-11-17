//
//  ManagedLibraryFeatureFlagTests.swift
//  PalaceTests
//
//  PP-5070 — the flag gating MDM library pre-selection.
//
//  The failure this guards against is specific and has happened here before:
//  side loading shipped in 3.3.0 with a local-override key that nothing outside
//  the tests ever wrote, so the feature was unreachable and looked, from the
//  code, exactly like a feature that worked. These tests assert the override is
//  both readable AND writable through the same key the Testing screen uses.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class ManagedLibraryFeatureFlagTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var flags: RemoteFeatureFlags!

    override func setUp() {
        super.setUp()
        suiteName = "ManagedLibraryFeatureFlagTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        flags = RemoteFeatureFlags(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        flags = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - Default

    func testDefault_IsOff() {
        // Nothing written: the launch path must not change for anyone.
        XCTAssertFalse(flags.isManagedLibraryConfigurationEnabled)
    }

    // MARK: - The local override is reachable in both directions

    func testLocalOverride_TurnsTheFeatureOn() {
        defaults.set(true, forKey: RemoteFeatureFlags.managedLibraryConfigurationLocalOverrideKey)
        XCTAssertTrue(flags.isManagedLibraryConfigurationEnabled)
    }

    func testLocalOverride_TurnsTheFeatureBackOff() {
        // An override that can only ever enable is half a switch. QA needs to
        // put a device back to production behaviour without reinstalling.
        defaults.set(true, forKey: RemoteFeatureFlags.managedLibraryConfigurationLocalOverrideKey)
        XCTAssertTrue(flags.isManagedLibraryConfigurationEnabled)

        defaults.set(false, forKey: RemoteFeatureFlags.managedLibraryConfigurationLocalOverrideKey)
        XCTAssertFalse(flags.isManagedLibraryConfigurationEnabled)
    }

    func testClearingTheOverride_FallsBackRatherThanStickingOn() {
        defaults.set(true, forKey: RemoteFeatureFlags.managedLibraryConfigurationLocalOverrideKey)
        defaults.removeObject(forKey: RemoteFeatureFlags.managedLibraryConfigurationLocalOverrideKey)

        XCTAssertFalse(flags.isManagedLibraryConfigurationEnabled,
                       "removing the override must fall through to remote, not latch on")
    }

    func testOverrideKey_IsDistinctFromEveryOtherFlagsKey() {
        // A copy-pasted key would silently tie two features together.
        let keys = [
            RemoteFeatureFlags.managedLibraryConfigurationLocalOverrideKey,
            RemoteFeatureFlags.sideLoadingLocalOverrideKey,
            RemoteFeatureFlags.lcpAudiobookStreamingLocalOverrideKey
        ]
        XCTAssertEqual(Set(keys).count, keys.count, "duplicate override key: \(keys)")
    }

    func testTurningThisFlagOn_DoesNotTurnSideLoadingOn() {
        defaults.set(true, forKey: RemoteFeatureFlags.managedLibraryConfigurationLocalOverrideKey)
        XCTAssertFalse(flags.isSideLoadingEnabled, "flags must be independent")
    }

    // MARK: - The status line tells a tester the feature is off

    func testStatusLine_SaysSoWhenTheFeatureIsDisabled() {
        // Otherwise a tester sees a configuration that is present and correct,
        // watches the launch path ignore it, and goes hunting for a bug that is
        // a switch.
        let preconfigurator = ManagedLibraryPreconfigurator(
            defaults: defaults,
            registry: FlagRegistryStub(),
            dependencies: ManagedLibraryApplyDependencies(
                addedLibraryIds: { [] },
                setAddedLibraryIds: { _ in },
                setMainFeedURL: { _ in },
                selectLibrary: { _ in },
                loadAuthenticationDocument: { _ in },
                announceLibraryChanged: { }
            )
        )

        let off = ManagedLibraryDebugOverride.statusDescription(
            preconfigurator: preconfigurator, defaults: defaults, featureEnabled: false
        )
        XCTAssertTrue(off.localizedCaseInsensitiveContains("feature off"), "got: \(off)")

        let on = ManagedLibraryDebugOverride.statusDescription(
            preconfigurator: preconfigurator, defaults: defaults, featureEnabled: true
        )
        XCTAssertFalse(on.localizedCaseInsensitiveContains("feature off"), "got: \(on)")
    }
}

private final class FlagRegistryStub: ManagedLibraryRegistryReading {
    var registryHasLoaded = true
    func managedLibraryAccount(uuid: String) -> Account? { nil }
    func managedLibraryAccounts() -> [Account] { [] }
}
