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
            // The bound this assertion must discriminate is the INNER hang (10s),
            // not a wall-clock ideal. 2.0s was tight enough to fail on a loaded
            // runner: measured 2026-09-11, this family produced one 4.851s
            // sample against a 0.217s median — 22x — and reddened a PR whose
            // diff contained no Swift at all.
            //
            // 8.0s still fails a regression that lets the inner sleep run to
            // completion, which is the only thing this can usefully detect, and
            // it no longer measures the machine. The tight bound is kept as an
            // opt-in below rather than deleted — it is the more sensitive
            // instrument, it just cannot gate CI.
            let elapsed = Date().timeIntervalSince(start)
            XCTAssertLessThan(elapsed, 8.0,
                              "withTimeout(0.2s) must return before the inner 10s sleep completes, got \(elapsed)s")
            assertPromptlyBounded(elapsed, label: "cancellable hang")
        } catch {
            XCTFail("Expected RemoteConfigFetchTimeout, got \(type(of: error)): \(error)")
        }
    }

    /// The case the `Task.sleep` test above CANNOT reproduce: `Task.sleep` honors
    /// cancellation, so a task-group `withTimeout` unblocks when it cancels the
    /// child. The real Firebase `fetchAndActivate()` ignores cancellation — and a
    /// task-group implementation re-awaits that child at scope exit, so the bound
    /// silently fails to fire (the 120s `testFetchIfNeeded_doesNotCrash` hang).
    /// This drives an operation that never completes AND ignores cancellation:
    /// `withTimeout` must still return promptly on the timeout, orphaning it.
    func testWithTimeout_boundsANonCancellableHangingOperation() async {
        let start = Date()
        do {
            _ = try await FirebaseManager.withTimeout(seconds: 0.2) { () async throws -> Bool in
                // Never resumes, and does not observe cancellation — mirrors the
                // non-cancellable Firebase fetch.
                await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
                return true
            }
            XCTFail("withTimeout must throw when a non-cancellable operation exceeds the bound")
        } catch is FirebaseManager.RemoteConfigFetchTimeout {
            // Reaching this catch is itself the proof. The inner operation never
            // resumes and ignores cancellation, so a task-group implementation
            // that re-awaited its child at scope exit would hang here forever
            // rather than throw — the 120s hang this test was written for. The
            // elapsed figure adds only "promptly", which is a property of the
            // machine as much as of the code, so it is reported rather than
            // gated at CI-hostile tightness.
            let elapsed = Date().timeIntervalSince(start)
            XCTAssertLessThan(elapsed, 8.0,
                              "withTimeout must orphan a NON-cancellable hang and return, got \(elapsed)s")
            assertPromptlyBounded(elapsed, label: "non-cancellable hang")
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
    /// Pins the Remote Config side so a test asserts the CODE's behaviour rather
    /// than whatever flag state the machine happens to hold. Before this seam
    /// existed, a flag getter falling through its local override read
    /// `FirebaseManager.shared`, which no test could reach — so "defaults off"
    /// was really "this machine never fetched Remote Config" (PP-5224).
    private struct StubRemoteConfig: RemoteConfigProviding {
        var bools: [FirebaseManager.RemoteConfigKey: Bool] = [:]
        var doubles: [FirebaseManager.RemoteConfigKey: Double] = [:]
        var enhancedLogging = false

        func fetchAndActivateRemoteConfig() async -> Bool { true }
        func getBoolValue(forKey key: FirebaseManager.RemoteConfigKey,
                          checkingDeviceSpecific: Bool) -> Bool {
            bools[key] ?? false
        }
        func getDoubleValue(forKey key: FirebaseManager.RemoteConfigKey) -> Double {
            doubles[key] ?? 0
        }
        func isEnhancedLoggingEnabled() -> Bool { enhancedLogging }
        func getDeviceInfo() -> [String: String] { [:] }
        func setUserPropertiesForTargeting() {}
    }

    /// `remote` defaults to an all-false stub, which is the posture the existing
    /// callers assumed — but now it is PINNED by the test rather than inherited
    /// from the machine.
    private func makeInAppNavFlags(
        remote: StubRemoteConfig = StubRemoteConfig()
    ) -> (flags: RemoteFeatureFlags, suite: UserDefaults, name: String) {
        let name = "test.inAppPlaybackNav.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        return (RemoteFeatureFlags(defaults: suite, remoteConfig: remote), suite, name)
    }

    /// No local override, Remote Config says OFF: the feature is OFF.
    ///
    /// PP-5224: this assertion used to depend on ambient state. The test pinned
    /// the override in a throwaway suite, then the getter read
    /// `FirebaseManager.shared` — so it passed on CI's fresh simulators (which
    /// never fetch) and failed on any machine that had run the app since
    /// `in_app_playback_nav_enabled` was switched on. The Remote Config value is
    /// now pinned, so this asserts the code rather than the machine.
    func testInAppPlaybackNav_noOverride_remoteOff_isOff() {
        let (flags, suite, name) = makeInAppNavFlags(
            remote: StubRemoteConfig(bools: [.inAppPlaybackNavEnabled: false])
        )
        defer { suite.removePersistentDomain(forName: name) }

        XCTAssertFalse(flags.isInAppPlaybackNavEnabled,
                       "Absent a local override, an OFF Remote Config value must read OFF")
        XCTAssertEqual(flags.isInAppPlaybackNavEnabled,
                       flags.isFeatureEnabled(.inAppPlaybackNavEnabled),
                       "Without a local override, the getter must reflect the Remote Config flag, not a constant")
    }

    /// No local override, Remote Config says ON: the feature is ON.
    ///
    /// This is the case the old test could not express at all — the rolled-out
    /// production posture. Without it, a getter hardcoded to `return false`
    /// would have passed the whole suite.
    func testInAppPlaybackNav_noOverride_remoteOn_isOn() {
        let (flags, suite, name) = makeInAppNavFlags(
            remote: StubRemoteConfig(bools: [.inAppPlaybackNavEnabled: true])
        )
        defer { suite.removePersistentDomain(forName: name) }

        XCTAssertTrue(flags.isInAppPlaybackNavEnabled,
                      "Absent a local override, an ON Remote Config value must read ON — this is the shipped rollout state")
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

    /// A local override of `false` forces the legacy player even when Remote
    /// Config says ON.
    ///
    /// Remote Config is pinned ON here deliberately. With it ambient-false, as
    /// before, this test could not tell "the override won" from "Remote Config
    /// happened to be false too" — the precedence it names was never actually
    /// exercised.
    func testInAppPlaybackNav_localOverrideFalse_beatsRemoteOn() {
        let (flags, suite, name) = makeInAppNavFlags(
            remote: StubRemoteConfig(bools: [.inAppPlaybackNavEnabled: true])
        )
        defer { suite.removePersistentDomain(forName: name) }

        suite.set(false, forKey: RemoteFeatureFlags.inAppPlaybackNavLocalOverrideKey)
        XCTAssertFalse(flags.isInAppPlaybackNavEnabled,
                       "A local override of false must beat an ON Remote Config value (legacy toolkit player)")
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

    /// PP-5224: this test carried the SAME defect as the in-app-nav one and was
    /// passing only because `continuation_cards_enabled` has not been switched
    /// on yet — the identical failure waiting for its own rollout, not a
    /// different one. Remote Config is pinned now.
    func testContinuationCards_noOverride_remoteOff_isOff() {
        let (flags, suite, name) = makeInAppNavFlags(
            remote: StubRemoteConfig(bools: [.continuationCardsEnabled: false])
        )
        defer { suite.removePersistentDomain(forName: name) }

        XCTAssertFalse(flags.isContinuationCardsEnabled,
                       "Absent a local override, an OFF Remote Config value must read OFF")
        XCTAssertEqual(flags.isContinuationCardsEnabled,
                       flags.isFeatureEnabled(.continuationCardsEnabled),
                       "Without a local override, the getter must reflect the Remote Config flag, not a constant")
    }

    /// The rolled-out posture for the cards — previously inexpressible.
    func testContinuationCards_noOverride_remoteOn_isOn() {
        let (flags, suite, name) = makeInAppNavFlags(
            remote: StubRemoteConfig(bools: [.continuationCardsEnabled: true])
        )
        defer { suite.removePersistentDomain(forName: name) }

        XCTAssertTrue(flags.isContinuationCardsEnabled,
                      "Absent a local override, an ON Remote Config value must read ON")
    }

    /// The two flags were split so they roll out independently. Turning one on
    /// in Remote Config must not drag the other with it — a real risk, since
    /// both read the same provider through the same code path.
    func testContinuationCardsAndInAppNav_rollOutIndependently() {
        let (flags, suite, name) = makeInAppNavFlags(
            remote: StubRemoteConfig(bools: [.inAppPlaybackNavEnabled: true,
                                             .continuationCardsEnabled: false])
        )
        defer { suite.removePersistentDomain(forName: name) }

        XCTAssertTrue(flags.isInAppPlaybackNavEnabled,
                      "in-app nav ON must not be affected by the cards flag")
        XCTAssertFalse(flags.isContinuationCardsEnabled,
                       "cards OFF must survive in-app nav being ON — the flags were split to roll out independently")
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

    /// The tight timing bound, kept as an opt-in rather than deleted.
    ///
    /// `withTimeout(0.2s)` should return in well under a second on an idle
    /// machine, and a regression that widened the bound without breaking it
    /// entirely would show up here first. But a wall-clock assertion at that
    /// tightness measures the runner: on 2026-09-11 this family logged one
    /// 4.851s sample against a 0.217s median and turned a PR red whose diff
    /// contained no Swift. CLAUDE.md's CI contract is explicit that a test which
    /// flips with unrelated load cannot gate CI.
    ///
    /// So the sensitive instrument is preserved and made deliberate. Run it with
    /// `TEST_RUNNER_PALACE_STRESS_TIMING=1`, the same shape
    /// `AccountRegistryStorePoolStarvationTests` uses for its load-sensitive
    /// variant. Off by default it reports rather than fails, so a drift toward
    /// the bound is still visible in the log.
    private func assertPromptlyBounded(_ elapsed: TimeInterval,
                                       label: String,
                                       file: StaticString = #filePath,
                                       line: UInt = #line) {
        let tight: TimeInterval = 2.0
        guard ProcessInfo.processInfo.environment["PALACE_STRESS_TIMING"] == "1" else {
            if elapsed >= tight {
                print("[timing] \(label): \(elapsed)s exceeded the \(tight)s opt-in bound "
                      + "— load, or a real widening. Re-run with "
                      + "TEST_RUNNER_PALACE_STRESS_TIMING=1 on an idle machine to tell them apart.")
            }
            return
        }
        XCTAssertLessThan(elapsed, tight,
                          "\(label): withTimeout must return promptly; got \(elapsed)s",
                          file: file, line: line)
    }

}
