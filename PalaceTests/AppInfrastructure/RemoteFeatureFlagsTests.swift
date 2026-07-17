//
//  RemoteFeatureFlagsTests.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

@MainActor
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

    // MARK: - FirebaseManager.withTimeout (bounds the remote-config fetch hang)

    /// `withTimeout` must bound an operation that would otherwise hang
    /// indefinitely — this is what stops `fetchIfNeeded()` from hanging the
    /// caller (dead network in production / unconfigured Firebase in tests).
    /// A regression that removed the timeout race would let this run for the
    /// full inner 10s "hang" (or forever), so the elapsed-time assertion fails.
    func testWithTimeout_boundsAHangingOperation() async {
        let start = Date()
        do {
            _ = try await FirebaseManager.withTimeout(seconds: 0.2) { () async throws -> Bool in
                // Simulate a fetch that never completes within the bound.
                try await Task.sleep(nanoseconds: 10_000_000_000) // 10s
                return true
            }
            XCTFail("withTimeout must throw when the operation exceeds the bound")
        } catch is FirebaseManager.RemoteConfigFetchTimeout {
            let elapsed = Date().timeIntervalSince(start)
            XCTAssertLessThan(elapsed, 2.0,
                              "withTimeout(0.2s) must bound a hanging operation well under the inner 10s, got \(elapsed)s")
        } catch {
            XCTFail("Expected RemoteConfigFetchTimeout, got \(type(of: error)): \(error)")
        }
    }

    /// A fast operation must return its value, NOT be falsely timed out —
    /// kills a mutant that always throws / always loses the race.
    func testWithTimeout_returnsResultOfFastOperation() async throws {
        let value = try await FirebaseManager.withTimeout(seconds: 5.0) { () async throws -> Int in
            42
        }
        XCTAssertEqual(value, 42, "withTimeout must return the operation's result when it completes within the bound")
    }

    // MARK: - In-App Playback Navigation (Firebase-gated, default OFF)
    //
    // The in-app playback-nav feature is OFF by default and enabled via
    // Firebase Remote Config (the team turns it on — globally or via a staged
    // rollout — without shipping a build). Precedence: local dev override
    // (QA) > Firebase Remote Config (registered default false).

    /// Fresh, isolated UserDefaults suite so the local-override key can't bleed
    /// across tests or into `.standard`.
    private func makeInAppNavFlags() -> (flags: RemoteFeatureFlags, suite: UserDefaults, name: String) {
        let name = "test.inAppPlaybackNav.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        return (RemoteFeatureFlags(defaults: suite), suite, name)
    }

    /// No local override and no Firebase server value (the unit-test state):
    /// the feature is OFF and reflects the Remote Config flag rather than a
    /// hardcoded constant. Reverting the getter to `return true` (the prior GA
    /// behavior) fails the first assertion.
    func testInAppPlaybackNav_noOverride_defaultsOff() {
        let (flags, suite, name) = makeInAppNavFlags()
        defer { suite.removePersistentDomain(forName: name) }

        XCTAssertFalse(flags.isInAppPlaybackNavEnabled,
                       "Absent a local override or Firebase value, in-app playback nav must default OFF (Firebase-gated)")
        XCTAssertEqual(flags.isInAppPlaybackNavEnabled,
                       flags.isFeatureEnabled(.inAppPlaybackNavEnabled),
                       "Without a local override, the getter must reflect the Remote Config flag, not a constant")
    }

    /// A local override of `true` forces the feature ON regardless of the OFF
    /// default — QA/dev can preview the in-app player before the rollout.
    /// Kills a mutant that ignores the override and returns the (false in tests)
    /// Remote Config value.
    func testInAppPlaybackNav_localOverrideTrue_forcesOn() {
        let (flags, suite, name) = makeInAppNavFlags()
        defer { suite.removePersistentDomain(forName: name) }

        suite.set(true, forKey: RemoteFeatureFlags.inAppPlaybackNavLocalOverrideKey)
        XCTAssertTrue(flags.isInAppPlaybackNavEnabled,
                      "A local override of true must force the feature ON")
    }

    /// A local override of `false` forces the legacy player even if Firebase
    /// would enable the feature. Kills the prior hardcoded `return true`.
    func testInAppPlaybackNav_localOverrideFalse_forcesOff() {
        let (flags, suite, name) = makeInAppNavFlags()
        defer { suite.removePersistentDomain(forName: name) }

        suite.set(false, forKey: RemoteFeatureFlags.inAppPlaybackNavLocalOverrideKey)
        XCTAssertFalse(flags.isInAppPlaybackNavEnabled,
                       "A local override of false must force the feature OFF (legacy toolkit player)")
    }

    /// The registered production default is OFF — pins the Firebase-gated
    /// posture so a regression to on-by-default is caught.
    func testInAppPlaybackNav_featureFlagDefault_isOff() {
        XCTAssertFalse(RemoteFeatureFlags.FeatureFlag.inAppPlaybackNavEnabled.defaultValue,
                       "in-app playback nav default must be OFF — Firebase Remote Config turns it on")
    }

    // MARK: - Continuation Cards (Firebase-gated, default OFF, independent flag)
    //
    // The Continue Reading/Listening hero rows are gated by their OWN flag,
    // split from in-app playback nav so the cards and the mini-player roll out
    // independently. Same posture: default OFF, Firebase enables, local override
    // wins.

    func testContinuationCards_noOverride_defaultsOff() {
        let (flags, suite, name) = makeInAppNavFlags()
        defer { suite.removePersistentDomain(forName: name) }

        XCTAssertFalse(flags.isContinuationCardsEnabled,
                       "Absent a local override or Firebase value, continuation cards must default OFF")
        XCTAssertEqual(flags.isContinuationCardsEnabled,
                       flags.isFeatureEnabled(.continuationCardsEnabled),
                       "Without a local override, the getter must reflect the Remote Config flag, not a constant")
    }

    func testContinuationCards_localOverrideTrue_forcesOn() {
        let (flags, suite, name) = makeInAppNavFlags()
        defer { suite.removePersistentDomain(forName: name) }

        suite.set(true, forKey: RemoteFeatureFlags.continuationCardsLocalOverrideKey)
        XCTAssertTrue(flags.isContinuationCardsEnabled,
                      "A local override of true must force the continuation cards ON")
    }

    func testContinuationCards_localOverrideFalse_forcesOff() {
        let (flags, suite, name) = makeInAppNavFlags()
        defer { suite.removePersistentDomain(forName: name) }

        suite.set(false, forKey: RemoteFeatureFlags.continuationCardsLocalOverrideKey)
        XCTAssertFalse(flags.isContinuationCardsEnabled,
                       "A local override of false must force the continuation cards OFF")
    }

    func testContinuationCards_featureFlagDefault_isOff() {
        XCTAssertFalse(RemoteFeatureFlags.FeatureFlag.continuationCardsEnabled.defaultValue,
                       "continuation cards default must be OFF — Firebase Remote Config turns it on")
    }

    /// The split's core guarantee: the two flags are independent. Forcing the
    /// continuation cards ON while forcing in-app playback nav OFF (and vice
    /// versa) must be honored — one does not leak into the other. A mutant that
    /// re-pointed either getter at the wrong override key fails here.
    func testFlags_continuationAndInAppNav_areIndependent() {
        let (flags, suite, name) = makeInAppNavFlags()
        defer { suite.removePersistentDomain(forName: name) }

        suite.set(true, forKey: RemoteFeatureFlags.continuationCardsLocalOverrideKey)
        suite.set(false, forKey: RemoteFeatureFlags.inAppPlaybackNavLocalOverrideKey)
        XCTAssertTrue(flags.isContinuationCardsEnabled,
                      "continuation ON must not be suppressed by in-app-nav OFF")
        XCTAssertFalse(flags.isInAppPlaybackNavEnabled,
                       "in-app-nav OFF must be honored independently of continuation ON")

        suite.set(false, forKey: RemoteFeatureFlags.continuationCardsLocalOverrideKey)
        suite.set(true, forKey: RemoteFeatureFlags.inAppPlaybackNavLocalOverrideKey)
        XCTAssertFalse(flags.isContinuationCardsEnabled,
                       "continuation OFF must be honored independently of in-app-nav ON")
        XCTAssertTrue(flags.isInAppPlaybackNavEnabled,
                      "in-app-nav ON must not be suppressed by continuation OFF")
    }
}
