//
//  RemoteFeatureFlags.swift
//  Palace
//
//  Created for Remote Feature Flag & Device-Specific Monitoring
//  Copyright © 2025 The Palace Project. All rights reserved.
//

import Foundation
import FirebaseCore
import FirebaseAnalytics
import PalaceLogging

/// Remote feature flags using Firebase Remote Config.
///
/// NOTE: This class delegates all Firebase RemoteConfig access to FirebaseManager
/// to prevent race conditions that cause the "recursive_mutex lock failed" crash.
/// Do NOT access RemoteConfig directly from this class.
final class RemoteFeatureFlags {
    static let shared = RemoteFeatureFlags()

    private var lastFetchTime: Date?
    private let fetchInterval: TimeInterval = 3600 // 1 hour
    private let lock = NSLock()

    // MARK: - Feature Flag Keys

    enum FeatureFlag: String {
        case enhancedErrorLogging = "enhanced_error_logging_enabled"
        case enhancedErrorLoggingDeviceSpecific = "enhanced_error_logging_device_"
        case downloadRetryEnabled = "download_retry_enabled"
        case circuitBreakerEnabled = "circuit_breaker_enabled"
        case carPlayEnabled = "carplay_enabled"
        case opds2Enabled = "opds2_enabled"
        case readingStatsEnabled = "reading_stats_enabled"
        case advancedTypographyEnabled = "advanced_typography_enabled"
        case resetAccountEnabled = "reset_account_enabled"

        var defaultValue: Bool {
            switch self {
            case .downloadRetryEnabled, .circuitBreakerEnabled:
                return true
            case .carPlayEnabled:
                return true
            case .opds2Enabled:
                return true
            default:
                return false
            }
        }

        /// Converts to FirebaseManager key if available.
        var managerKey: FirebaseManager.RemoteConfigKey? {
            switch self {
            case .enhancedErrorLogging:
                return .enhancedErrorLoggingEnabled
            case .downloadRetryEnabled:
                return .downloadRetryEnabled
            case .circuitBreakerEnabled:
                return .circuitBreakerEnabled
            case .carPlayEnabled:
                return .carPlayEnabled
            case .opds2Enabled:
                return .opds2Enabled
            case .resetAccountEnabled:
                return .resetAccountEnabled
            default:
                return nil
            }
        }

        /// Whether this flag also looks up a per-device override key
        /// (`<rawValue>_device_<sanitizedDeviceID>`). Used for staged rollouts
        /// where support enables a feature for one patron at a time via
        /// Firebase Remote Config conditions.
        var supportsDeviceSpecificOverride: Bool {
            switch self {
            case .enhancedErrorLogging, .resetAccountEnabled:
                return true
            default:
                return false
            }
        }
    }

    // MARK: - Initialization

    private init() {}

    // MARK: - Setup

    /// Call this on app launch to fetch remote config.
    func initialize() async {
        await fetchAndActivate()
    }

    // MARK: - Fetching

    /// Fetch and activate remote config.
    @discardableResult
    func fetchAndActivate() async -> Bool {
        let success = await FirebaseManager.shared.fetchAndActivateRemoteConfig()

        lock.lock()
        lastFetchTime = Date()
        lock.unlock()

        return success
    }

    /// Force a Remote Config fetch + activate, bypassing the SDK's
    /// `minimumFetchInterval` for this single call. Bound to user-initiated
    /// screen appearances (e.g., AccountDetailView) where the patron expects
    /// the latest server-side flag value, not whatever was cached an hour ago.
    @discardableResult
    func forceFetchAndActivate() async -> Bool {
        let success = await FirebaseManager.shared.forceFetchAndActivateRemoteConfig()

        lock.lock()
        lastFetchTime = Date()
        lock.unlock()

        return success
    }

    /// Fetch if needed (respects fetch interval).
    func fetchIfNeeded() async {
        guard shouldFetch() else { return }
        await fetchAndActivate()
    }

    private func shouldFetch() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard let lastFetch = lastFetchTime else { return true }
        return Date().timeIntervalSince(lastFetch) > fetchInterval
    }

    // MARK: - Feature Flag Access

    /// Check if feature is enabled (with device-specific override).
    func isFeatureEnabled(_ feature: FeatureFlag) -> Bool {
        // Delegate to FirebaseManager for thread-safe access
        if let managerKey = feature.managerKey {
            return FirebaseManager.shared.getBoolValue(
                forKey: managerKey,
                checkingDeviceSpecific: feature.supportsDeviceSpecificOverride
            )
        }

        // For device-specific flags, check via FirebaseManager
        if feature == .enhancedErrorLogging {
            return FirebaseManager.shared.isEnhancedLoggingEnabled()
        }

        // Fallback to default
        return feature.defaultValue
    }

    // MARK: - Convenience Properties

    /// UserDefaults key for cached CarPlay feature flag.
    private static let carPlayEnabledCacheKey = "RemoteFeatureFlags.carPlayEnabled"

    /// Whether CarPlay support is enabled.
    /// Uses Firebase Remote Config for runtime control.
    var isCarPlayEnabled: Bool {
        let remoteValue = isFeatureEnabled(.carPlayEnabled)
        let previousCached: Bool? = UserDefaults.standard.object(forKey: Self.carPlayEnabledCacheKey) != nil
            ? UserDefaults.standard.bool(forKey: Self.carPlayEnabledCacheKey)
            : nil
        UserDefaults.standard.set(remoteValue, forKey: Self.carPlayEnabledCacheKey)

        if let prev = previousCached, prev != remoteValue {
            Log.info(#file, "🚗 CarPlay feature flag changed: \(prev) → \(remoteValue)")
        }

        return remoteValue
    }

    /// Cached CarPlay enabled value for use during early app lifecycle
    /// (before Remote Config is fetched). Returns the last known value.
    var isCarPlayEnabledCached: Bool {
        if UserDefaults.standard.object(forKey: Self.carPlayEnabledCacheKey) != nil {
            let cached = UserDefaults.standard.bool(forKey: Self.carPlayEnabledCacheKey)
            Log.debug(#file, "🚗 CarPlay feature flag (cached): \(cached)")
            return cached
        }
        // No cached value - return default
        Log.debug(#file, "🚗 CarPlay feature flag (no cache, using default): \(FeatureFlag.carPlayEnabled.defaultValue)")
        return FeatureFlag.carPlayEnabled.defaultValue
    }

    /// Whether OPDS 2 feed support is enabled.
    /// When disabled, the app falls back to OPDS 1 (XML) for all catalog requests.
    /// Default: true. Set to false in Firebase Remote Config to disable.
    var isOPDS2Enabled: Bool {
        isFeatureEnabled(.opds2Enabled)
    }

    /// PP-4282: UserDefaults override that lets QA / support force the Reset
    /// Account button on for a specific device without a Firebase round-trip.
    /// Settable from `TPPDeveloperSettingsTableViewController`. Falls through
    /// to the Remote Config flag when nil.
    static let resetAccountLocalOverrideKey = "RemoteFeatureFlags.resetAccountLocalOverride"

    /// Tri-state for the Reset Account local override surfaced in Developer
    /// Settings. `.useFirebase` removes the override and defers to Remote
    /// Config; the explicit `.forceOn` / `.forceOff` cases pin the flag for
    /// QA verification on a TestFlight build (where Firebase fetch is gated
    /// by `minimumFetchIntervalRelease`).
    enum ResetAccountOverride {
        case useFirebase
        case forceOn
        case forceOff

        var storedValue: Bool? {
            switch self {
            case .useFirebase: return nil
            case .forceOn: return true
            case .forceOff: return false
            }
        }
    }

    /// Current tri-state value of the local override. Reading collapses any
    /// non-Bool / missing UserDefaults entry to `.useFirebase`.
    var resetAccountLocalOverride: ResetAccountOverride {
        guard let override = UserDefaults.standard.object(forKey: Self.resetAccountLocalOverrideKey) as? Bool else {
            return .useFirebase
        }
        return override ? .forceOn : .forceOff
    }

    /// Persist a new tri-state value for the override. `.useFirebase` removes
    /// the key entirely so `isResetAccountEnabled` falls through to Remote
    /// Config on the next read (the difference between "explicitly off" and
    /// "no override" matters for the read path below).
    func setResetAccountLocalOverride(_ override: ResetAccountOverride) {
        switch override.storedValue {
        case .some(let value):
            UserDefaults.standard.set(value, forKey: Self.resetAccountLocalOverrideKey)
        case .none:
            UserDefaults.standard.removeObject(forKey: Self.resetAccountLocalOverrideKey)
        }
    }

    /// PP-4282 / HelpSpot 17716: gate for the destructive "Reset This Library
    /// Account" button in `AccountDetailView`. Defaults OFF in production.
    /// Enable per-patron via Firebase Remote Config key
    /// `reset_account_enabled_device_<sanitizedDeviceID>` (support workflow),
    /// or globally via `reset_account_enabled` (broad rollout). Local override
    /// via `resetAccountLocalOverrideKey` UserDefault is for QA only.
    var isResetAccountEnabled: Bool {
        if let override = UserDefaults.standard.object(forKey: Self.resetAccountLocalOverrideKey) as? Bool {
            return override
        }
        return isFeatureEnabled(.resetAccountEnabled)
    }

    // MARK: - Device Info for Targeting

    /// Get device info for Firebase targeting.
    func getDeviceInfo() -> [String: String] {
        FirebaseManager.shared.getDeviceInfo()
    }

    /// Set user properties for Firebase targeting.
    func setUserPropertiesForTargeting() {
        FirebaseManager.shared.setUserPropertiesForTargeting()
    }
}
