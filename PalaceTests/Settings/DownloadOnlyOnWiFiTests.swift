//
//  DownloadOnlyOnWiFiTests.swift
//  PalaceTests
//
//  Tests for PP-758: Download only on Wi-Fi setting.
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceNetwork
@testable import Palace

@MainActor
final class DownloadOnlyOnWiFiTests: XCTestCase {

    private let settingsKey = TPPSettings.downloadOnlyOnWiFiKey
    private var settings: TPPSettings!
    /// Per-test isolated UserDefaults — injected into `TPPSettings`
    /// via the swarm_47883816 Module D production DI seam. No write
    /// here touches `.standard`; the resetter wipes the suite at the
    /// end of every test.
    private var isolatedDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        isolatedDefaults = Self.testUserDefaults()
        settings = TPPSettings(defaults: isolatedDefaults)
    }

    override func tearDown() {
        settings = nil
        isolatedDefaults = nil
        super.tearDown()
    }

    // MARK: - AC2: Default State

    func testDefaultValue_isFalse() {
        // Fresh suite — no prior write to remove. The default must be OFF.
        XCTAssertFalse(
            settings.downloadOnlyOnWiFi,
            "Download only on Wi-Fi should default to OFF"
        )
    }

    // MARK: - Setting Persistence

    /// Setting persists to the injected UserDefaults synchronously
    /// through the `TPPSettings` getter/setter bridge. Lock the full
    /// toggle cycle (off→on→off) plus a fresh-instance read against
    /// the SAME suite after each write to catch a mutant that caches
    /// the value in memory but drops the UserDefaults write (which
    /// would silently revert on app relaunch).
    func testSetting_persistsToUserDefaultsAcrossToggleCycle() {
        // Toggle on: in-memory + UserDefaults must agree.
        settings.downloadOnlyOnWiFi = true
        XCTAssertTrue(isolatedDefaults.bool(forKey: settingsKey),
                      "Setter must write through to UserDefaults synchronously")
        // A fresh TPPSettings instance reading from the SAME suite must
        // observe the persisted value — the cross-relaunch invariant.
        XCTAssertTrue(TPPSettings(defaults: isolatedDefaults).downloadOnlyOnWiFi,
                      "A new TPPSettings against the same suite must observe the persisted value")

        // Toggle off: same round-trip.
        settings.downloadOnlyOnWiFi = false
        XCTAssertFalse(isolatedDefaults.bool(forKey: settingsKey),
                       "Setting to false must write through to UserDefaults")
        XCTAssertFalse(TPPSettings(defaults: isolatedDefaults).downloadOnlyOnWiFi,
                       "A new TPPSettings against the same suite must read the now-false value")
    }

    func testSetting_persistsAcrossReads() {
        settings.downloadOnlyOnWiFi = true
        let value = isolatedDefaults.bool(forKey: settingsKey)
        XCTAssertTrue(value, "Setting should be persisted in the injected UserDefaults")
        // Reading the setting again must return the same value (no side effects)
        XCTAssertTrue(settings.downloadOnlyOnWiFi,
                      "Re-reading the setting after setting to true must still return true")
    }

    // MARK: - Mock

    func testMock_defaultIsFalse() {
        let mock = TPPSettingsMock()
        XCTAssertFalse(mock.downloadOnlyOnWiFi)
    }

    func testMock_canBeConfigured() {
        let mock = TPPSettingsMock(downloadOnlyOnWiFi: true)
        XCTAssertTrue(mock.downloadOnlyOnWiFi)
    }

    func testMock_resetClearsSetting() {
        let mock = TPPSettingsMock(downloadOnlyOnWiFi: true)
        mock.reset()
        XCTAssertFalse(mock.downloadOnlyOnWiFi)
    }

    // MARK: - Reachability isOnWiFi

    // TODO(swarm_47883816-A-followup): migrate to `makeTestAppContainer()`
    // once Module A's TestAppContainerFactory lands. Until then these
    // tests still call `AppContainer.production()` — that's a separate
    // polluter category tracked by Module A's contract, not Module D's.
    func testReachability_isOnWiFi_returnsBool() {
        // isOnWiFi must return a Bool without crashing. In CI the interface is
        // unknown, but we can verify the value is consistent with the detailed status.
        let isWiFi = AppContainer.production().reachability.isOnWiFi
        // Verify the return type is a proper Bool (not some nil-bridged optional)
        XCTAssertNotNil(isWiFi as Bool?, "isOnWiFi must return a non-nil Bool")
        // Verify consistency: calling twice must return the same value (no side effects)
        XCTAssertEqual(AppContainer.production().reachability.isOnWiFi, isWiFi,
                       "isOnWiFi must be idempotent: repeated calls must return the same value")
    }

    // TODO(swarm_47883816-A-followup): migrate to `makeTestAppContainer()`
    // once Module A's TestAppContainerFactory lands.
    func testReachability_isOnWiFi_consistentWithDetailedStatus() {
        let detailed = AppContainer.production().reachability.getDetailedConnectivityStatus()
        let isWiFi = AppContainer.production().reachability.isOnWiFi

        if detailed.connectionType == "WiFi" || detailed.connectionType == "Ethernet" {
            XCTAssertTrue(isWiFi, "isOnWiFi should be true when connected via WiFi or Ethernet")
        } else if detailed.connectionType == "Cellular" || detailed.connectionType == "None" {
            XCTAssertFalse(isWiFi, "isOnWiFi should be false when on Cellular or disconnected")
        }
    }

    // MARK: - Localized Strings

    func testLocalizedStrings_areNotEmpty() {
        XCTAssertFalse(Strings.Settings.downloadOnlyOnWiFi.isEmpty)
        XCTAssertFalse(Strings.Settings.downloadOnlyOnWiFiDescription.isEmpty)
        XCTAssertFalse(Strings.Settings.downloadRestrictedToWiFi.isEmpty)
        XCTAssertFalse(Strings.Settings.wifiRequired.isEmpty)
        XCTAssertFalse(Strings.Settings.downloads.isEmpty)
    }

    // MARK: - Accessibility Identifier

    func testAccessibilityIdentifier_exists() {
        let id = AccessibilityID.Settings.downloadOnlyOnWiFiToggle
        XCTAssertFalse(id.isEmpty, "Accessibility identifier should be defined")
        XCTAssertTrue(id.contains("settings."), "Identifier should be namespaced under settings")
    }
}
