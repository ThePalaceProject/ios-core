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
/// `@unchecked Sendable`: `FeatureFlagProvider` (the protocol this conforms to in
/// `RemoteFeatureFlags+PalaceCatalog.swift`) is now `Sendable` (PalaceCatalog
/// Swift 6). This shared singleton is already accessed app-wide concurrently; the
/// conformance is honest — its only mutable stored property, `lastFetchTime`, is
/// accessed exclusively under `lock` (an `NSLock`); every other stored property
/// is `let`. `final` keeps the assertion subclass-proof.
final class RemoteFeatureFlags: @unchecked Sendable {
    static let shared = RemoteFeatureFlags()

    private var lastFetchTime: Date?
    private let fetchInterval: TimeInterval = 3600 // 1 hour
    private let lock = NSLock()

    /// `UserDefaults` backing store for local-override reads (CarPlay
    /// cache, reset-account override, triage-bot override, etc.).
    /// `.shared` binds `.standard`; tests construct a fresh instance
    /// via the explicit initializer with a per-suite
    /// `UserDefaults(suiteName:)` so override checks don't leak
    /// across tests. There is NO fallback once injected.
    private let defaults: UserDefaults

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
        case triageBotEnabled = "triage_bot_enabled"
        case triageBotTicketSubmissionEnabled = "triage_bot_ticket_submission_enabled"
        case triageBotAIFallbackEnabled = "triage_bot_ai_fallback_enabled"
        /// Gates the in-app playback-navigation feature (swarm_0b7616e7 +
        /// polish 2026-06-02): Continue Reading/Listening hero rows on
        /// the Catalog top, the persistent mini-player chrome above the
        /// tab bar, and the tap-to-resume routing that wires both to
        /// `AudiobookSessionPresenter`. Default OFF — the feature is
        /// opt-in via the developer settings toggle until broad rollout.
        case inAppPlaybackNavEnabled = "in_app_playback_nav_enabled"
        /// Gates every side-loading surface (swarm_495a88d9 — PP-2677 /
        /// PP-2678 / PP-2679): the Settings "Side Loading" import screen and
        /// the catalog side-loaded lane. Test-only capability for exercising
        /// the real reader + DRM stack against local files with no OPDS feed.
        /// Default OFF; enabled via `isSideLoadingEnabled` whose precedence is
        /// UserDefaults local override (dev-menu toggle) > Firebase remote
        /// (default false). No DEBUG auto-enable — QA/TestFlight builds are
        /// non-DEBUG, so the feature is turned on explicitly by the dev-menu
        /// toggle rather than by build configuration.
        case sideLoadingEnabled = "side_loading_enabled"
        /// Master kill-switch for the app-rating prompt feature (Epic PP-4086).
        /// Default ON; set to false in Remote Config to suppress the prompt
        /// entirely regardless of engagement state.
        case appRatingPromptEnabled = "app_rating_prompt_enabled"

        var defaultValue: Bool {
            switch self {
            case .downloadRetryEnabled, .circuitBreakerEnabled:
                return true
            case .carPlayEnabled:
                return true
            case .opds2Enabled:
                return true
            case .appRatingPromptEnabled:
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
            case .triageBotEnabled:
                return .triageBotEnabled
            case .triageBotTicketSubmissionEnabled:
                return .triageBotTicketSubmissionEnabled
            case .triageBotAIFallbackEnabled:
                return .triageBotAIFallbackEnabled
            case .inAppPlaybackNavEnabled:
                return .inAppPlaybackNavEnabled
            case .sideLoadingEnabled:
                return .sideLoadingEnabled
            case .appRatingPromptEnabled:
                return .appRatingPromptEnabled
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
            case .enhancedErrorLogging:
                return true
            default:
                return false
            }
        }
    }

    // MARK: - Initialization

    /// Designated initializer. Defaults to `.standard` so the
    /// `static let shared = RemoteFeatureFlags()` site keeps working
    /// unchanged. Tests construct a per-suite instance with their
    /// own `UserDefaults(suiteName:)` to isolate override-key state.
    /// Access stays `internal` (not `public`) — production code uses
    /// `.shared`; only the test target needs the seam.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

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

        lock.withLock { lastFetchTime = Date() }

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
        let previousCached: Bool? = defaults.object(forKey: Self.carPlayEnabledCacheKey) != nil
            ? defaults.bool(forKey: Self.carPlayEnabledCacheKey)
            : nil
        defaults.set(remoteValue, forKey: Self.carPlayEnabledCacheKey)

        if let prev = previousCached, prev != remoteValue {
            Log.info(#file, "🚗 CarPlay feature flag changed: \(prev) → \(remoteValue)")
        }

        return remoteValue
    }

    /// Cached CarPlay enabled value for use during early app lifecycle
    /// (before Remote Config is fetched). Returns the last known value.
    var isCarPlayEnabledCached: Bool {
        if defaults.object(forKey: Self.carPlayEnabledCacheKey) != nil {
            let cached = defaults.bool(forKey: Self.carPlayEnabledCacheKey)
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

    // The `reset_account_enabled` flag (PP-4282 / HelpSpot 17716) was retired
    // when the account reset became a permanent Developer Settings feature
    // (initiative init_401f1be1). It no longer gates any UI, so the flag case,
    // its `isResetAccountEnabled` accessor, and the local-override key were
    // removed here and from FirebaseManager.RemoteConfigKey.

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
        if let override = defaults.object(forKey: Self.triageBotLocalOverrideKey) as? Bool {
            return override
        }
        #if DEBUG
        return true
        #else
        return isFeatureEnabled(.triageBotEnabled)
        #endif
    }

    /// UserDefaults override for ticket submission. Mirrors the master
    /// `triageBotLocalOverrideKey` pattern so QA can toggle independently
    /// from `TPPDeveloperSettingsTableViewController`.
    static let triageBotTicketSubmissionLocalOverrideKey = "RemoteFeatureFlags.triageBotTicketSubmissionLocalOverride"

    /// Whether the bot may post real HelpSpot tickets. When false but the bot
    /// is otherwise enabled, the chat still drafts tickets and shows the
    /// preview, but the confirm action copies the JSON payload to the
    /// pasteboard instead of submitting. Used during the demo and during
    /// staged rollout before HelpSpot rate-limit negotiation completes.
    ///
    /// Override precedence:
    ///   1. UserDefaults local override (QA toggle)
    ///   2. DEBUG build → true
    ///   3. Firebase Remote Config
    var isTriageBotTicketSubmissionEnabled: Bool {
        if let override = defaults.object(forKey: Self.triageBotTicketSubmissionLocalOverrideKey) as? Bool {
            return override
        }
        #if DEBUG
        return true
        #else
        return isFeatureEnabled(.triageBotTicketSubmissionEnabled)
        #endif
    }

    /// UserDefaults override for AI fallback. Mirrors the master
    /// `triageBotLocalOverrideKey` pattern so QA can toggle independently
    /// from `TPPDeveloperSettingsTableViewController`.
    static let triageBotAIFallbackLocalOverrideKey = "RemoteFeatureFlags.triageBotAIFallbackLocalOverride"

    /// Whether the triage bot may consult the Claude-backed fallback
    /// classifier when the local keyword matcher returns escalate. Defaults
    /// OFF in production (no Anthropic traffic until a server-proxy path
    /// is in place); defaults ON in DEBUG so dev/device builds exercise
    /// the fallback when an ANTHROPIC_API_KEY is configured in the
    /// engineer's Xcode scheme. Even when this flag is true, the
    /// fallback only fires if the Keychain holds an API key — no key,
    /// no Anthropic traffic.
    ///
    /// Override precedence:
    ///   1. UserDefaults local override (QA toggle)
    ///   2. DEBUG build → true
    ///   3. Firebase Remote Config
    var isTriageBotAIFallbackEnabled: Bool {
        if let override = defaults.object(forKey: Self.triageBotAIFallbackLocalOverrideKey) as? Bool {
            return override
        }
        #if DEBUG
        return true
        #else
        return isFeatureEnabled(.triageBotAIFallbackEnabled)
        #endif
    }

    /// UserDefaults override that lets QA / a developer toggle the
    /// in-app playback nav feature without a Firebase round-trip.
    /// Settable from `TPPDeveloperSettingsTableViewController`. Falls
    /// through to the Remote Config flag when nil. Mirrors the
    /// `resetAccountLocalOverrideKey` pattern.
    static let inAppPlaybackNavLocalOverrideKey = "RemoteFeatureFlags.inAppPlaybackNavLocalOverride"

    /// Whether the in-app playback navigation feature is enabled:
    /// Continue Reading/Listening hero rows on the Catalog top, the
    /// persistent mini-player above the tab bar, and the tap-to-resume
    /// routing that wires both to `AudiobookSessionPresenter`. Default
    /// OFF; gateable via the developer settings toggle (local override)
    /// or `in_app_playback_nav_enabled` in Remote Config (broad rollout).
    ///
    /// When false, the Continue row and mini-player are not rendered;
    /// the persistent full-player overlay still surfaces when an
    /// audiobook is opened (so playback always has a UI). Minimize
    /// hides the overlay; without a mini-player to re-expand from, the
    /// user re-enters playback via My Books / Catalog the same way they
    /// did before the feature shipped.
    var isInAppPlaybackNavEnabled: Bool {
        if let override = defaults.object(forKey: Self.inAppPlaybackNavLocalOverrideKey) as? Bool {
            return override
        }
        return isFeatureEnabled(.inAppPlaybackNavEnabled)
    }

    /// UserDefaults override that lets QA / a developer force side loading on
    /// or off without a Firebase round-trip. Settable from
    /// `TPPDeveloperSettingsTableViewController`. Falls through to the
    /// DEBUG default / Remote Config flag when nil. Mirrors the
    /// `triageBotLocalOverrideKey` naming pattern.
    static let sideLoadingLocalOverrideKey = "RemoteFeatureFlags.sideLoadingLocalOverride"

    /// Whether the side-loading capability is enabled: the Settings "Side
    /// Loading" import screen and the catalog side-loaded lane. A test-only
    /// feature for exercising the real reader + DRM stack against local files
    /// with no OPDS feed (swarm_495a88d9 — PP-2677 / PP-2678 / PP-2679).
    ///
    /// Defaults OFF in production. There is NO DEBUG auto-enable; the feature
    /// is turned on explicitly via the dev-menu local override, otherwise it
    /// falls through to the Firebase Remote Config flag (default off).
    ///
    /// Side loading is a test-only capability enabled via the Testing settings
    /// menu (per PP-2581), so it is OFF by default and turned on explicitly by a
    /// tester/QA rather than auto-enabled by build configuration. A build-time
    /// `#if DEBUG` gate would only enable it in local Xcode debug builds anyway
    /// (TestFlight/Release are non-DEBUG), so it would not reach the QA builds
    /// that actually need it — the dev-menu local override does.
    ///
    /// Override precedence:
    ///   1. UserDefaults local override (dev-menu toggle / QA / staged demos)
    ///   2. Firebase Remote Config (default `false`)
    var isSideLoadingEnabled: Bool {
        if let override = defaults.object(forKey: Self.sideLoadingLocalOverrideKey) as? Bool {
            return override
        }
        return isFeatureEnabled(.sideLoadingEnabled)
    }

    // MARK: - App Rating (Epic PP-4086)

    /// Master switch for the app-rating prompt. When false, no eligibility
    /// evaluation should proceed. Default ON.
    var isAppRatingPromptEnabled: Bool {
        isFeatureEnabled(.appRatingPromptEnabled)
    }

    /// UserDefaults override that lets QA / simdrive force the rating prompt to
    /// be eligible without meeting the real thresholds or waiting out the
    /// cooldown. Settable from `TPPDeveloperSettingsTableViewController`. Mirrors
    /// the `triageBotLocalOverrideKey` pattern.
    static let appRatingForceEligibleLocalOverrideKey = "RemoteFeatureFlags.appRatingForceEligibleOverride"

    /// Whether the rating prompt is force-eligible for QA/simdrive. Defaults to
    /// false; no remote flag — this is a local debug override only.
    var isAppRatingForceEligible: Bool {
      defaults.object(forKey: Self.appRatingForceEligibleLocalOverrideKey) as? Bool ?? false
    }

    /// The remote-tunable eligibility thresholds. Any threshold missing or
    /// non-positive in Remote Config falls back to `RatingConfig.fallback`.
    var appRatingConfig: RatingConfig {
        RatingConfig(
            minSessions: positiveIntOrFallback(.appRatingMinSessions, RatingConfig.fallback.minSessions),
            minBooksCompleted: positiveIntOrFallback(.appRatingMinBooksCompleted, RatingConfig.fallback.minBooksCompleted),
            cooldownDays: positiveIntOrFallback(.appRatingCooldownDays, RatingConfig.fallback.cooldownDays),
            lifetimePromptCap: positiveIntOrFallback(.appRatingLifetimePromptCap, RatingConfig.fallback.lifetimePromptCap)
        )
    }

    /// Reads a numeric Remote Config value, returning `fallback` when the value
    /// is absent or non-positive (guards against a mis-set `0` disabling a
    /// threshold). `minBooksCompleted` is allowed to be as low as 1, never 0,
    /// so a positive-only guard is correct for every threshold here.
    private func positiveIntOrFallback(_ key: FirebaseManager.RemoteConfigKey, _ fallback: Int) -> Int {
        let value = FirebaseManager.shared.getDoubleValue(forKey: key)
        return value > 0 ? Int(value) : fallback
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
