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
        case triageBotEnabled = "triage_bot_enabled"
        case triageBotTicketSubmissionEnabled = "triage_bot_ticket_submission_enabled"
        case triageBotAIFallbackEnabled = "triage_bot_ai_fallback_enabled"

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
            case .triageBotEnabled:
                return .triageBotEnabled
            case .triageBotTicketSubmissionEnabled:
                return .triageBotTicketSubmissionEnabled
            case .triageBotAIFallbackEnabled:
                return .triageBotAIFallbackEnabled
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

    /// UserDefaults override that lets QA / support force the Reset
    /// Account button on for a specific device without a Firebase round-trip.
    /// Settable from `TPPDeveloperSettingsTableViewController`. Falls through
    /// to the Remote Config flag when nil.
    static let resetAccountLocalOverrideKey = "RemoteFeatureFlags.resetAccountLocalOverride"

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

    /// UserDefaults override that lets QA / support force the triage bot on
    /// for a specific device without a Firebase round-trip. Settable from
    /// `TPPDeveloperSettingsTableViewController`. Falls through to the
    /// Remote Config flag when nil.
    static let triageBotLocalOverrideKey = "RemoteFeatureFlags.triageBotLocalOverride"

    /// Master kill-switch for the Palace Triage Bot. Defaults OFF in production,
    /// but defaults ON in DEBUG builds so an engineer building from Xcode onto
    /// a device or sim doesn't have to set anything — the feature is visible
    /// automatically. TestFlight and App Store builds still respect the
    /// Firebase Remote Config flag (default off), unchanged.
    ///
    /// Override precedence:
    ///   1. UserDefaults local override (QA / staged demos)
    ///   2. DEBUG build → true
    ///   3. Firebase Remote Config
    ///
    /// When false, the Settings "Get Help" row, the floating help button, and
    /// every other entry point are invisible — no surface area at all.
    var isTriageBotEnabled: Bool {
        if let override = UserDefaults.standard.object(forKey: Self.triageBotLocalOverrideKey) as? Bool {
            return override
        }
        #if DEBUG
        return true
        #else
        return isFeatureEnabled(.triageBotEnabled)
        #endif
    }

    /// Whether the bot may post real HelpSpot tickets. When false but the bot
    /// is otherwise enabled, the chat still drafts tickets and shows the
    /// preview, but the confirm action copies the JSON payload to the
    /// pasteboard instead of submitting. Used during the demo and during
    /// staged rollout before HelpSpot rate-limit negotiation completes.
    ///
    /// Same DEBUG-default-on policy as isTriageBotEnabled — dev builds get
    /// the full email-gateway flow without per-device setup.
    var isTriageBotTicketSubmissionEnabled: Bool {
        #if DEBUG
        return true
        #else
        return isFeatureEnabled(.triageBotTicketSubmissionEnabled)
        #endif
    }

    /// Whether the triage bot may consult the Claude-backed fallback
    /// classifier when the local keyword matcher returns escalate. Defaults
    /// OFF in production (no Anthropic traffic until a server-proxy path
    /// is in place); defaults ON in DEBUG so dev/device builds exercise
    /// the fallback when an ANTHROPIC_API_KEY is configured in the
    /// engineer's Xcode scheme. Even when this flag is true, the
    /// fallback only fires if the Keychain holds an API key — no key,
    /// no Anthropic traffic.
    var isTriageBotAIFallbackEnabled: Bool {
        #if DEBUG
        return true
        #else
        return isFeatureEnabled(.triageBotAIFallbackEnabled)
        #endif
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
