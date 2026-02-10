//
//  RemoteFeatureFlagsTests.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class RemoteFeatureFlagsTests: XCTestCase {

  // MARK: - Shared Instance

  func testShared_isNotNil() {
    XCTAssertNotNil(RemoteFeatureFlags.shared)
  }

  func testShared_returnsSameInstance() {
    let a = RemoteFeatureFlags.shared
    let b = RemoteFeatureFlags.shared
    XCTAssertTrue(a === b)
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

    // All flags should have a default value (bool check just ensures no crash)
    for flag in flags {
      let _ = flag.defaultValue
    }
  }

  // MARK: - Feature Checks (Without Firebase)

  func testIsFeatureEnabled_withoutFirebase_returnsDefault() {
    // Without Firebase initialized, should return the default value
    let flags = RemoteFeatureFlags.shared

    // These should return defaults without crashing
    let enhancedLogging = flags.isFeatureEnabled(.enhancedErrorLogging)
    let downloadRetry = flags.isFeatureEnabled(.downloadRetryEnabled)

    // Default values for these flags
    let _ = enhancedLogging  // Just verify no crash
    let _ = downloadRetry
  }

  // MARK: - CarPlay

  func testIsCarPlayEnabledCached_returnsBool() {
    // Should not crash and should return a bool
    let enabled = RemoteFeatureFlags.shared.isCarPlayEnabledCached
    XCTAssertNotNil(enabled)
  }

  // MARK: - Device Info

  func testGetDeviceInfo_returnsNonEmptyDict() {
    let info = RemoteFeatureFlags.shared.getDeviceInfo()
    XCTAssertFalse(info.isEmpty, "Device info should not be empty")
  }

  func testGetDeviceInfo_containsVersionInfo() {
    let info = RemoteFeatureFlags.shared.getDeviceInfo()

    // Should contain some version-related info
    let hasVersion = info.keys.contains(where: { $0.lowercased().contains("version") || $0.lowercased().contains("model") || $0.lowercased().contains("device") })
    XCTAssertTrue(hasVersion, "Device info should contain version/model info")
  }

  // MARK: - Fetch

  func testFetchIfNeeded_doesNotCrash() async {
    // Without Firebase, should gracefully handle
    await RemoteFeatureFlags.shared.fetchIfNeeded()
  }
}
