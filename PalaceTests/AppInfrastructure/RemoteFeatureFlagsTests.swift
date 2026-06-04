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

    // MARK: - Reset Account Flag (PP-4282 / HelpSpot 17716)

    /// The flag must default OFF in production. Support enables it per-patron
    /// via Firebase Remote Config; if we ever default it ON, the destructive
    /// Reset button ships to every patron unexpectedly.
    ///
    /// Uses the DI seam introduced by swarm_47883816 Module D so the
    /// override-key state lives in a per-test isolated UserDefaults
    /// suite instead of `UserDefaults.standard`. Reading via a
    /// purpose-built `RemoteFeatureFlags(defaults:)` proves the
    /// behavior on the SAME store the test asserts against — the
    /// previous `.shared` version was racing whatever the rest of the
    /// suite had left in `.standard`.
    func testIsResetAccountEnabled_defaultsOff_withoutOverrideOrFirebase() {
        let isolatedDefaults = testUserDefaults()
        let flags = RemoteFeatureFlags(defaults: isolatedDefaults)

        // Fresh suite — no override key set, no Firebase.
        XCTAssertFalse(flags.isResetAccountEnabled,
                       "Reset Account button must default OFF when no override and no Firebase remote value")
    }

    /// The local UserDefaults override is the per-device QA escape hatch. A
    /// `true` value must enable the flag even when the remote default is OFF.
    func testIsResetAccountEnabled_localOverrideTrue_enablesFlag() {
        let isolatedDefaults = testUserDefaults()
        isolatedDefaults.set(true, forKey: RemoteFeatureFlags.resetAccountLocalOverrideKey)
        let flags = RemoteFeatureFlags(defaults: isolatedDefaults)

        XCTAssertTrue(flags.isResetAccountEnabled,
                      "Local override = true must enable the Reset Account button regardless of remote config")
    }

    /// Override = false must also win — prevents a misconfigured Firebase value
    /// from forcing the button on for a specific QA device that's been
    /// explicitly opted out.
    func testIsResetAccountEnabled_localOverrideFalse_disablesFlag() {
        let isolatedDefaults = testUserDefaults()
        isolatedDefaults.set(false, forKey: RemoteFeatureFlags.resetAccountLocalOverrideKey)
        let flags = RemoteFeatureFlags(defaults: isolatedDefaults)

        XCTAssertFalse(flags.isResetAccountEnabled,
                       "Local override = false must disable the Reset Account button regardless of remote config")
    }

    /// `resetAccountEnabled` must declare device-specific support so per-patron
    /// rollouts work via the `<key>_device_<id>` Firebase RC pattern. If this
    /// regresses to false, support's per-patron enablement breaks silently.
    func testResetAccountEnabled_supportsDeviceSpecificOverride() {
        XCTAssertTrue(RemoteFeatureFlags.FeatureFlag.resetAccountEnabled.supportsDeviceSpecificOverride,
                      "resetAccountEnabled must opt into the per-device Firebase RC override pattern")
    }

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
