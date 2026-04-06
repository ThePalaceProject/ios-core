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

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: settingsKey)
        super.tearDown()
    }

    // MARK: - AC2: Default State

    func testDefaultValue_isFalse() {
        UserDefaults.standard.removeObject(forKey: settingsKey)
        XCTAssertFalse(
            TPPSettings.shared.downloadOnlyOnWiFi,
            "Download only on Wi-Fi should default to OFF"
        )
    }

    // MARK: - Setting Persistence

    func testSetting_canBeToggledOn() {
        TPPSettings.shared.downloadOnlyOnWiFi = true
        XCTAssertTrue(TPPSettings.shared.downloadOnlyOnWiFi)
    }

    func testSetting_canBeToggledOff() {
        TPPSettings.shared.downloadOnlyOnWiFi = true
        TPPSettings.shared.downloadOnlyOnWiFi = false
        XCTAssertFalse(TPPSettings.shared.downloadOnlyOnWiFi)
    }

    func testSetting_persistsAcrossReads() {
        TPPSettings.shared.downloadOnlyOnWiFi = true
        let value = UserDefaults.standard.bool(forKey: settingsKey)
        XCTAssertTrue(value, "Setting should be persisted in UserDefaults")
    }

    // MARK: - Protocol Conformance

    func testSettingsProviding_includesDownloadOnlyOnWiFi() {
        let settings: TPPSettingsProviding = TPPSettings.shared
        let original = settings.downloadOnlyOnWiFi
        settings.downloadOnlyOnWiFi = !original
        XCTAssertNotEqual(settings.downloadOnlyOnWiFi, original)
        settings.downloadOnlyOnWiFi = original
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
        // Just verify the property exists and returns without crashing.
        // We can't assert a specific value because CI may be on any interface.
        _ = Reachability.shared.isOnWiFi
    }

    func testReachability_isOnWiFi_consistentWithDetailedStatus() {
        let detailed = Reachability.shared.getDetailedConnectivityStatus()
        let isWiFi = Reachability.shared.isOnWiFi

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
