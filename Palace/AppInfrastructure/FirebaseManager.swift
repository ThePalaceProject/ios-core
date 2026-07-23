//
//  FirebaseManager.swift
//  Palace
//
//  Centralized Firebase management.
//  Copyright © 2025 The Palace Project. All rights reserved.
//

import Foundation
import os
import FirebaseCore
import FirebaseRemoteConfig
import FirebaseAnalytics
import FirebaseCrashlytics
import PalaceLogging

/// Lock-guarded, resume-exactly-once holder for a `CheckedContinuation`, shared
/// across the two racing tasks in `FirebaseManager.withTimeout`. A
/// `CheckedContinuation` is not `Sendable`, so it rides inside this
/// `@unchecked Sendable` box; the continuation is nil'd on the first resume, so
/// the losing task's later resume is a no-op rather than a double-resume crash.
/// File-scope (not nested in the generic `withTimeout`) because Swift forbids a
/// local type inside a generic function.
private final class ResumeOnceBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }
    func resume(returning value: T) {
        lock.lock(); let c = continuation; continuation = nil; lock.unlock()
        c?.resume(returning: value)
    }
    func resume(throwing error: Error) {
        lock.lock(); let c = continuation; continuation = nil; lock.unlock()
        c?.resume(throwing: error)
    }
}

/// Centralized manager for all Firebase services.
///
/// Thread Safety:
/// - Device IDs are immutable `let` properties computed once at init
/// - RemoteConfig is thread-safe internally (no external locking needed)
/// - lastFetchTime is advisory only; RemoteConfig handles its own rate limiting
/// `@unchecked Sendable` invariant (mirrors `TPPAgeCheck`): all stored
/// properties are `let`; the only mutable state (`isFetching`) is guarded by
/// `OSAllocatedUnfairLock`; `remoteConfig` is Firebase's internally-thread-safe
/// `RemoteConfig`. This lets the `self`-capturing `@Sendable` operation closure
/// passed to `withTimeout(...)` compile without a signature change.
final class FirebaseManager: @unchecked Sendable {
    static let shared = FirebaseManager()

    // MARK: - Configuration

    private enum Configuration {
        static let minimumFetchIntervalDebug: TimeInterval = 60 // 1 minute
        static let minimumFetchIntervalRelease: TimeInterval = 3600 // 1 hour
        static let deviceIdentifierKey = "TPPDeviceIdentifier"
        /// Hard upper bound on a single remote-config fetch+activate so it can
        /// never hang the caller (dead network in production; unconfigured
        /// Firebase in unit tests). Generous vs. a healthy fetch (~1-3s).
        static let fetchTimeoutSeconds: Double = 10
    }

    // MARK: - Immutable State (thread-safe by design)

    /// Unique device identifier, persisted across app launches
    let deviceID: String

    /// Device ID without hyphens for Firebase parameter compatibility
    let sanitizedDeviceID: String

    // MARK: - Firebase Services

    private let remoteConfig: RemoteConfig

    /// Atomic flag to prevent concurrent fetch operations
    private let isFetching = OSAllocatedUnfairLock(initialState: false)

    // MARK: - Remote Config Keys

    enum RemoteConfigKey: String {
        case enhancedErrorLoggingEnabled = "enhanced_error_logging_enabled"
        case enhancedErrorLoggingDevicePrefix = "enhanced_error_logging_device_"
        case downloadRetryEnabled = "download_retry_enabled"
        case circuitBreakerEnabled = "circuit_breaker_enabled"
        case carPlayEnabled = "carplay_enabled"
        case opds2Enabled = "opds2_enabled"
        case triageBotEnabled = "triage_bot_enabled"
        case triageBotTicketSubmissionEnabled = "triage_bot_ticket_submission_enabled"
        case triageBotAIFallbackEnabled = "triage_bot_ai_fallback_enabled"
        case inAppPlaybackNavEnabled = "in_app_playback_nav_enabled"
        case continuationCardsEnabled = "continuation_cards_enabled"
        case sideLoadingEnabled = "side_loading_enabled"
        // App-rating prompt (Epic PP-4086). Master switch + tunable thresholds.
        case appRatingPromptEnabled = "app_rating_prompt_enabled"
        case appRatingMinSessions = "app_rating_min_sessions"
        case appRatingMinBooksCompleted = "app_rating_min_books_completed"
        case appRatingCooldownDays = "app_rating_cooldown_days"
        case appRatingLifetimePromptCap = "app_rating_lifetime_prompt_cap"
    }

    // MARK: - Initialization

    private init() {
        // Compute device ID once - it never changes after creation
        if let existing = UserDefaults.standard.string(forKey: Configuration.deviceIdentifierKey) {
            self.deviceID = existing
        } else {
            let newID = UUID().uuidString
            UserDefaults.standard.set(newID, forKey: Configuration.deviceIdentifierKey)
            self.deviceID = newID
            Log.info(#file, "Generated new device ID: \(newID)")
        }
        self.sanitizedDeviceID = deviceID.replacingOccurrences(of: "-", with: "")

        // Get the shared RemoteConfig instance
        self.remoteConfig = RemoteConfig.remoteConfig()

        // Configure settings
        configureRemoteConfigSettings()
        setDefaultValues()
    }

    private func configureRemoteConfigSettings() {
        let settings = RemoteConfigSettings()

        #if DEBUG
        settings.minimumFetchInterval = Configuration.minimumFetchIntervalDebug
        #else
        settings.minimumFetchInterval = Configuration.minimumFetchIntervalRelease
        #endif

        remoteConfig.configSettings = settings
    }

    private func setDefaultValues() {
        remoteConfig.setDefaults([
            RemoteConfigKey.enhancedErrorLoggingEnabled.rawValue: NSNumber(value: false),
            RemoteConfigKey.downloadRetryEnabled.rawValue: NSNumber(value: true),
            RemoteConfigKey.circuitBreakerEnabled.rawValue: NSNumber(value: true),
            RemoteConfigKey.carPlayEnabled.rawValue: NSNumber(value: true),
            RemoteConfigKey.opds2Enabled.rawValue: NSNumber(value: true),
            RemoteConfigKey.triageBotEnabled.rawValue: NSNumber(value: false),
            RemoteConfigKey.triageBotTicketSubmissionEnabled.rawValue: NSNumber(value: false),
            RemoteConfigKey.triageBotAIFallbackEnabled.rawValue: NSNumber(value: false),
            RemoteConfigKey.inAppPlaybackNavEnabled.rawValue: NSNumber(value: false),
            RemoteConfigKey.continuationCardsEnabled.rawValue: NSNumber(value: false),
            RemoteConfigKey.sideLoadingEnabled.rawValue: NSNumber(value: false),
            RemoteConfigKey.appRatingPromptEnabled.rawValue: NSNumber(value: true),
            RemoteConfigKey.appRatingMinSessions.rawValue: NSNumber(value: RatingConfig.fallback.minSessions),
            RemoteConfigKey.appRatingMinBooksCompleted.rawValue: NSNumber(value: RatingConfig.fallback.minBooksCompleted),
            RemoteConfigKey.appRatingCooldownDays.rawValue: NSNumber(value: RatingConfig.fallback.cooldownDays),
            RemoteConfigKey.appRatingLifetimePromptCap.rawValue: NSNumber(value: RatingConfig.fallback.lifetimePromptCap)
        ])
    }

    // MARK: - Remote Config Access

    /// Fetches and activates remote config.
    /// Uses atomic flag to prevent concurrent fetches (which could trigger Firebase mutex issues).
    @discardableResult
    func fetchAndActivateRemoteConfig() async -> Bool {
        // Atomically check and set fetching flag - if already fetching, skip
        let alreadyFetching = isFetching.withLock { fetching -> Bool in
            if fetching { return true }
            fetching = true
            return false
        }

        guard !alreadyFetching else {
            Log.info(#file, "Remote config fetch already in progress, skipping")
            return false
        }

        defer {
            isFetching.withLock { $0 = false }
        }

        do {
            // Bound the fetch so it can never hang indefinitely. Firebase's
            // `fetchAndActivate()` can stall when the network is dead/slow or
            // (in unit tests) when Firebase is not configured — leaving the
            // `await` suspended forever. A real user on a dead network must not
            // have flag-fetch hang the caller, and the unit-test
            // `testFetchIfNeeded_doesNotCrash` must not hang the suite. On
            // timeout we proceed with cached/default config (return false).
            let status = try await Self.withTimeout(seconds: Configuration.fetchTimeoutSeconds) {
                try await self.remoteConfig.fetchAndActivate()
            }

            switch status {
            case .successFetchedFromRemote:
                Log.info(#file, "✅ Remote config fetched from server")
                return true
            case .successUsingPreFetchedData:
                Log.info(#file, "ℹ️ Using pre-fetched remote config")
                return true
            case .error:
                Log.error(#file, "❌ Error activating remote config")
                return false
            @unknown default:
                return false
            }
        } catch is RemoteConfigFetchTimeout {
            Log.error(#file, "Remote config fetch timed out — proceeding with cached/default values")
            return false
        } catch {
            Log.error(#file, "Failed to fetch remote config: \(error.localizedDescription)")
            return false
        }
    }

    /// Sentinel thrown by `withTimeout` when the wrapped operation exceeds the bound.
    struct RemoteConfigFetchTimeout: Error {}

    /// Runs `operation`, racing it against a timeout. If the timeout wins, the
    /// operation's task is cancelled and `RemoteConfigFetchTimeout` is thrown.
    /// (The underlying Firebase call may not honour cancellation; the orphaned
    /// fetch completes harmlessly in the background while the caller proceeds.)
    ///
    /// `internal` (not `private`) so the tests can pin the bound-a-hang
    /// behaviour deterministically (see `RemoteFeatureFlagsTests`).
    static func withTimeout<T: Sendable>(
        seconds: Double,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        // A `withThrowingTaskGroup` race is WRONG here: the group re-awaits the
        // operation child at scope exit, so when the timeout wins and we
        // `cancelAll()`, exiting still blocks on the operation if it ignores
        // cancellation — which Firebase's `fetchAndActivate()` does. That made
        // the 10s bound a no-op for the one call it exists to bound (the 120s
        // RemoteFeatureFlagsTests hang; a dead-network hang in production). The
        // existing `Task.sleep`-based guard test passed only because sleep
        // honors cancellation and so didn't reproduce the non-cancellable case.
        //
        // Instead: resume the caller from whichever task wins, and ORPHAN the
        // loser. When the timeout wins, the operation task keeps running
        // (untethered) but no longer blocks the caller — exactly the documented
        // "orphaned fetch completes harmlessly in the background" contract.
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let box = ResumeOnceBox(continuation)
            Task {
                do { box.resume(returning: try await operation()) }
                catch { box.resume(throwing: error) }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                box.resume(throwing: RemoteConfigFetchTimeout())
            }
        }
    }

    /// Gets a boolean value from remote config.
    func getBoolValue(forKey key: RemoteConfigKey) -> Bool {
        remoteConfig.configValue(forKey: key.rawValue).boolValue
    }

    /// Gets a boolean value with device-specific override check.
    func getBoolValue(forKey key: RemoteConfigKey, checkingDeviceSpecific: Bool) -> Bool {
        if checkingDeviceSpecific {
            let deviceKey = key.rawValue + "_device_" + sanitizedDeviceID
            let deviceValue = remoteConfig.configValue(forKey: deviceKey)

            if deviceValue.source == .remote {
                return deviceValue.boolValue
            }
        }

        return remoteConfig.configValue(forKey: key.rawValue).boolValue
    }

    /// Gets a numeric value from remote config (returns 0 when unset and no
    /// default is registered). Used for the app-rating tunable thresholds.
    func getDoubleValue(forKey key: RemoteConfigKey) -> Double {
        remoteConfig.configValue(forKey: key.rawValue).numberValue.doubleValue
    }

    /// Checks if a config value came from the remote server.
    func isRemoteValue(forKey key: RemoteConfigKey) -> Bool {
        remoteConfig.configValue(forKey: key.rawValue).source == .remote
    }

    /// Best-effort "was the previous app session crash-free?" signal for the
    /// app-rating eligibility policy (PP-4088). Returns `true` when crash
    /// reporting is unavailable (non-production or `FEATURE_CRASH_REPORTING`
    /// off), so an absent signal never blocks an otherwise-eligible patron.
    func wasLastSessionCrashFree() -> Bool {
        #if FEATURE_CRASH_REPORTING
        return !Crashlytics.crashlytics().didCrashDuringPreviousExecution()
        #else
        return true
        #endif
    }

    // MARK: - Enhanced Logging

    /// Checks if enhanced error logging is enabled for this device.
    func isEnhancedLoggingEnabled() -> Bool {
        // Check device-specific flag first
        let deviceKey = RemoteConfigKey.enhancedErrorLoggingDevicePrefix.rawValue + sanitizedDeviceID
        let deviceValue = remoteConfig.configValue(forKey: deviceKey)

        if deviceValue.source == .remote {
            return deviceValue.boolValue
        }

        // Check global flag
        let globalValue = remoteConfig.configValue(forKey: RemoteConfigKey.enhancedErrorLoggingEnabled.rawValue)
        if globalValue.source == .remote {
            return globalValue.boolValue
        }

        return false
    }

    // MARK: - Analytics User Properties

    /// Sets user properties for Firebase Analytics targeting.
    func setUserPropertiesForTargeting() {
        let deviceInfo = getDeviceInfo()

        Analytics.setUserProperty(deviceInfo["device_id"], forName: "device_id")
        Analytics.setUserProperty(deviceInfo["device_model"], forName: "device_model")
        Analytics.setUserProperty(deviceInfo["ios_version"], forName: "ios_version")
        Analytics.setUserProperty(deviceInfo["build_type"], forName: "build_type")

        Log.info(#file, "✅ Firebase user properties set for targeting")
    }

    /// Off-main-safe snapshot of the `@MainActor`-isolated `UIDevice.current`
    /// constants. On the main thread we read them directly via
    /// `MainActor.assumeIsolated` (provably-main branch); off-main we return
    /// `unknown`/`nil` rather than touch UIKit off the main actor. The values are
    /// device constants, so a main-thread caller always gets the real values and
    /// there is no behaviour change on the paths that matter (launch-time setup
    /// runs on main). Mirrors `URLRequest+Extensions.cachedUserAgent()`.
    nonisolated private static func currentDeviceConstants()
        -> (model: String, systemVersion: String, vendorID: String?) {
        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                (UIDevice.current.model,
                 UIDevice.current.systemVersion,
                 UIDevice.current.identifierForVendor?.uuidString)
            }
        }
        return ("unknown", "unknown", nil)
    }

    /// Returns device information dictionary for targeting and logging.
    func getDeviceInfo() -> [String: String] {
        var info: [String: String] = [:]

        info["device_id"] = deviceID
        // `UIDevice.current` is `@MainActor`-isolated under `complete`; this method
        // has nonisolated + off-main callers (RemoteFeatureFlags, error monitors).
        // Read the device constants on main when we're already there, else fall back
        // to `unknown` — same off-main-safe pattern as `URLRequest+Extensions`'
        // `cachedUserAgent()`. Values are constant, so no correctness change.
        let device = Self.currentDeviceConstants()
        info["device_model"] = device.model
        info["ios_version"] = device.systemVersion
        info["app_version"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        info["build_number"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"

        #if DEBUG
        info["build_type"] = "debug"
        #else
        info["build_type"] = "release"
        #endif

        if let accountId = AppContainer.production().accountsManager.currentAccountId {
            info["library_id"] = accountId
        }

        return info
    }

    // MARK: - Crashlytics

    /// Configures Crashlytics with device-specific information.
    func configureCrashlytics() {
        guard Bundle.main.applicationEnvironment == .production else { return }

        #if FEATURE_CRASH_REPORTING
        Crashlytics.crashlytics().setCustomValue(deviceID, forKey: "PalaceDeviceID")

        // Same `@MainActor` UIDevice guard as `getDeviceInfo()` above.
        if let vendorID = Self.currentDeviceConstants().vendorID {
            Crashlytics.crashlytics().setCustomValue(vendorID, forKey: "VendorDeviceID")
        }
        #endif
    }

    /// Sets the user ID for Crashlytics (hashed for privacy).
    func setCrashlyticsUserID(_ userID: String?) {
        guard Bundle.main.applicationEnvironment == .production else { return }

        #if FEATURE_CRASH_REPORTING
        if let userIDmd5 = userID?.md5hex() {
            Crashlytics.crashlytics().setUserID(userIDmd5)
        } else {
            Crashlytics.crashlytics().setUserID("SIGNED_OUT_USER")
        }
        #endif
    }

    /// Logs an error to Crashlytics with enhanced metadata if enabled.
    func logError(_ error: NSError) {
        guard Bundle.main.applicationEnvironment == .production else {
            Log.error("LOG_ERROR", "\(error)")
            return
        }

        #if FEATURE_CRASH_REPORTING
        if isEnhancedLoggingEnabled() {
            Crashlytics.crashlytics().setCustomValue(true, forKey: "enhanced_logging_enabled")
            Crashlytics.crashlytics().setCustomValue(deviceID, forKey: "device_id")
            Crashlytics.crashlytics().log("Context: \(error.domain)")
        }

        Crashlytics.crashlytics().record(error: error)
        #else
        Log.error("LOG_ERROR", "\(error)")
        #endif
    }

    /// Logs a breadcrumb message to Crashlytics.
    func logBreadcrumb(_ message: String) {
        guard Bundle.main.applicationEnvironment == .production else { return }

        #if FEATURE_CRASH_REPORTING
        Crashlytics.crashlytics().log(message)
        #endif
    }

    /// Sets a custom key-value pair on Crashlytics for dashboard filtering.
    func setCrashlyticsKey(_ key: String, value: String) {
        #if FEATURE_CRASH_REPORTING
        Crashlytics.crashlytics().setCustomValue(value, forKey: key)
        #endif
    }

    // MARK: - Analytics Events

    /// Logs an enhanced error event to Analytics.
    func logEnhancedErrorEvent(
        error: Error,
        context: String,
        metadata: [String: Any] = [:]
    ) {
        guard isEnhancedLoggingEnabled() else { return }

        let params: [String: Any] = [
            "error_domain": (error as NSError).domain,
            "error_code": (error as NSError).code,
            "context": context,
            "device_id": deviceID
        ]

        Analytics.logEvent("enhanced_error_logged", parameters: params)

        #if FEATURE_CRASH_REPORTING
        let stackTrace = Thread.callStackSymbols.joined(separator: "\n")
        Crashlytics.crashlytics().log("Enhanced Error: \(context)")
        Crashlytics.crashlytics().log("Error: \(error.localizedDescription)")
        Crashlytics.crashlytics().log("Stack Trace:\n\(stackTrace)")

        for (key, value) in metadata {
            Crashlytics.crashlytics().log("\(key): \(value)")
        }
        #endif

        Log.info(#file, "📊 Enhanced error data sent to Firebase")
    }

    // MARK: - Lifecycle

    /// Called when the app enters background.
    func applicationDidEnterBackground() {
        Log.info(#file, "Firebase: App entering background")
    }

    /// Called when the app becomes active.
    func applicationDidBecomeActive() {
        Log.info(#file, "Firebase: App became active")

        // RemoteConfig handles its own rate limiting via minimumFetchInterval
        Task {
            await fetchAndActivateRemoteConfig()
        }
    }
}
