//
//  DownloadOnlyOnWiFiTests.swift
//  PalaceTests
//
//  Tests for PP-758: Download only on Wi-Fi setting.
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class DownloadOnlyOnWiFiTests: XCTestCase {

    private let settingsKey = TPPSettings.downloadOnlyOnWiFiKey
    private var settings: TPPSettings!

    override func setUp() {
        super.setUp()
        settings = TPPSettings()
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: settingsKey)
        settings = nil
        super.tearDown()
    }

    // MARK: - AC2: Default State

    func testDefaultValue_isFalse() {
        UserDefaults.standard.removeObject(forKey: settingsKey)
        XCTAssertFalse(
            settings.downloadOnlyOnWiFi,
            "Download only on Wi-Fi should default to OFF"
        )
    }

    // MARK: - Setting Persistence

    func testSetting_canBeToggledOn() {
        settings.downloadOnlyOnWiFi = true
        XCTAssertTrue(settings.downloadOnlyOnWiFi)
        // Setting must persist to UserDefaults immediately
        XCTAssertTrue(UserDefaults.standard.bool(forKey: settingsKey),
                      "downloadOnlyOnWiFi=true must be reflected in UserDefaults")
    }

    func testSetting_canBeToggledOff() {
        settings.downloadOnlyOnWiFi = true
        settings.downloadOnlyOnWiFi = false
        XCTAssertFalse(settings.downloadOnlyOnWiFi)
        // Must also be false in UserDefaults
        XCTAssertFalse(UserDefaults.standard.bool(forKey: settingsKey),
                       "downloadOnlyOnWiFi=false must be reflected in UserDefaults")
    }

    func testSetting_persistsAcrossReads() {
        settings.downloadOnlyOnWiFi = true
        let value = UserDefaults.standard.bool(forKey: settingsKey)
        XCTAssertTrue(value, "Setting should be persisted in UserDefaults")
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
