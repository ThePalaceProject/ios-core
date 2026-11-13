//
//  FeatureFlagProviding.swift
//  PalaceFeatureFlags
//
//  The feature-flag read seam, injected from `AppContainer.featureFlags`.
//  Packages that read flags depend on this, never on Firebase or the app.
//  Not here: `appRatingConfig` (returns an app-target type), the DEBUG-only
//  force-submit-failure override, and Firebase fetch/lifecycle methods.
//

import Foundation

public protocol FeatureFlagProviding: AnyObject, Sendable {
    /// Raw remote read (+ per-device override where supported) with
    /// `flag.defaultValue` as the no-value fallback. The named accessors
    /// below additionally fold in UserDefaults local overrides and DEBUG
    /// defaults — use them when one exists for your flag.
    func isFeatureEnabled(_ feature: PalaceFeatureFlag) -> Bool

    var isOPDS2Enabled: Bool { get }
    var isCarPlayEnabled: Bool { get }
    /// Last-known CarPlay value for early app lifecycle (pre-fetch).
    var isCarPlayEnabledCached: Bool { get }
    var isTriageBotEnabled: Bool { get }
    var isTriageBotTicketSubmissionEnabled: Bool { get }
    var isTriageBotAIFallbackEnabled: Bool { get }
    var isInAppPlaybackNavEnabled: Bool { get }
    var isContinuationCardsEnabled: Bool { get }
    var isSideLoadingEnabled: Bool { get }
    var isAppRatingPromptEnabled: Bool { get }
    var isAppRatingForceEligible: Bool { get }
    /// PP-5006 prototype: the EPUB reader's drag-to-navigate chapter scrubber.
    /// Local Testing-menu override only — no remote flag behind it.
    var isChapterScrubberEnabled: Bool { get }
    /// PP-5070 / PP-5217: deploy-time library pre-selection from an MDM's
    /// Managed App Configuration. Default OFF — it changes the first-run path,
    /// which every new install takes.
    var isManagedLibraryConfigurationEnabled: Bool { get }
}
