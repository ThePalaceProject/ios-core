//
//  RemoteFeatureFlagsTests.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class RemoteFeatureFlagsTests: XCTestCase {

    override func tearDown() {
        super.tearDown()
    }

    // MARK: - Shared Instance

    func testShared_isNotNil() {
        XCTAssertNotNil(RemoteFeatureFlags.shared)
        // Singleton identity: accessing shared twice must return the same object
        XCTAssertTrue(RemoteFeatureFlags.shared === RemoteFeatureFlags.shared,
                      "RemoteFeatureFlags.shared must always return the same instance")
    }

    func testShared_returnsSameInstance() {
        let a = RemoteFeatureFlags.shared
        let b = RemoteFeatureFlags.shared
        XCTAssertTrue(a === b)
        // Both references must agree on the same CarPlay cached value
        XCTAssertEqual(a.isCarPlayEnabledCached, b.isCarPlayEnabledCached,
                       "Both references to shared must return the same cached feature flag values")
    }

    // MARK: - Feature Flag Enum

    func testFeatureFlag_allCases_haveNonEmptyRawValues() {
        let flags: [RemoteFeatureFlags.FeatureFlag] = [
            .enhancedErrorLogging,
            .enhancedErrorLoggingDeviceSpecific,
            .downloadRetryEnabled,
            .circuitBreakerEnabled,
            .carPlayEnabled
        ]

        for flag in flags {
            XCTAssertFalse(flag.rawValue.isEmpty, "\(flag) should have a non-empty raw value")
        }
    }

    func testFeatureFlag_defaultValues_areDefined() {
        let flags: [RemoteFeatureFlags.FeatureFlag] = [
            .enhancedErrorLogging,
            .enhancedErrorLoggingDeviceSpecific,
            .downloadRetryEnabled,
            .circuitBreakerEnabled,
            .carPlayEnabled
        ]

        // All flags should have a default value and their raw values must be non-empty
        for flag in flags {
            let defaultValue = flag.defaultValue
            // Default values are Booleans — verify they're deterministic (calling twice same result)
            XCTAssertEqual(defaultValue, flag.defaultValue,
                           "\(flag).defaultValue must be deterministic across calls")
            XCTAssertFalse(flag.rawValue.isEmpty, "\(flag) must have a non-empty raw value")
        }
    }

    // MARK: - Feature Checks (Without Firebase)

    func testIsFeatureEnabled_withoutFirebase_returnsDefault() {
        // Without Firebase initialized, should return the default value
        let featureFlags = RemoteFeatureFlags.shared

        // In unit tests (no Firebase), isFeatureEnabled must equal the flag's defaultValue
        let enhancedLogging = featureFlags.isFeatureEnabled(.enhancedErrorLogging)
        let downloadRetry = featureFlags.isFeatureEnabled(.downloadRetryEnabled)

        XCTAssertEqual(enhancedLogging, RemoteFeatureFlags.FeatureFlag.enhancedErrorLogging.defaultValue,
                       "Without Firebase, isFeatureEnabled must equal the flag's defaultValue")
        XCTAssertEqual(downloadRetry, RemoteFeatureFlags.FeatureFlag.downloadRetryEnabled.defaultValue,
                       "Without Firebase, downloadRetry must equal the flag's defaultValue")
    }

    // MARK: - CarPlay

    func testIsCarPlayEnabledCached_returnsBool() {
        // Should not crash, return a real Bool, and be idempotent
        let enabled = RemoteFeatureFlags.shared.isCarPlayEnabledCached
        XCTAssertNotNil(enabled as Bool?, "isCarPlayEnabledCached must return a non-nil Bool")
        // Without Firebase in tests, the cached value must equal the feature flag default
        let defaultValue = RemoteFeatureFlags.FeatureFlag.carPlayEnabled.defaultValue
        XCTAssertEqual(enabled, defaultValue,
                       "In a test environment without Firebase, isCarPlayEnabledCached must equal the default value")
    }

    // MARK: - Device Info

    func testGetDeviceInfo_returnsNonEmptyDict() {
        let info = RemoteFeatureFlags.shared.getDeviceInfo()
        XCTAssertFalse(info.isEmpty, "Device info should not be empty")
        // All keys in the device info dict must be non-empty strings
        XCTAssertTrue(info.keys.allSatisfy { !$0.isEmpty },
                      "All device info keys must be non-empty strings")
    }

    func testGetDeviceInfo_containsVersionInfo() {
        let info = RemoteFeatureFlags.shared.getDeviceInfo()

        // Should contain some version-related info
        let hasVersion = info.keys.contains(where: { $0.lowercased().contains("version") || $0.lowercased().contains("model") || $0.lowercased().contains("device") })
        XCTAssertTrue(hasVersion, "Device info should contain version/model info")
        // Device info must be deterministic (calling twice must produce same keys)
        let info2 = RemoteFeatureFlags.shared.getDeviceInfo()
        XCTAssertEqual(Set(info.keys), Set(info2.keys),
                       "getDeviceInfo() must return the same set of keys across calls")
    }

    // The `reset_account_enabled` flag (PP-4282 / HelpSpot 17716) was retired
    // when the account reset became a permanent Developer Settings feature
    // (init_401f1be1) — the flag, its accessor, and override key were removed,
    // so the tests that pinned them were removed with it.

    // MARK: - Fetch

    func testFetchIfNeeded_doesNotCrash() async {
        // Without Firebase, should gracefully handle and leave flags in a consistent state
        let flagsBefore = RemoteFeatureFlags.shared.isFeatureEnabled(.enhancedErrorLogging)
        await RemoteFeatureFlags.shared.fetchIfNeeded()
        // Flags must remain accessible and return consistent values after fetch
        let flagsAfter = RemoteFeatureFlags.shared.isFeatureEnabled(.enhancedErrorLogging)
        // In unit tests (no Firebase), values must be identical before and after the no-op fetch
        XCTAssertEqual(flagsBefore, flagsAfter,
                       "fetchIfNeeded() must not change flag values in a test environment without Firebase")
    }
}
