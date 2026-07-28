//
//  FeatureFlagProviding.swift
//  PalaceFeatureFlags
//
//  THE feature-flag read seam (god-class decomposition Wave 1b §3c).
//  Consolidates the per-package protocol copies (PalaceCatalog's
//  FeatureFlagProvider) into one Layer-0 leaf. The Firebase-Remote-Config-
//  backed implementation (RemoteFeatureFlags) stays in the app target;
//  consumers hold this protocol, injected from AppContainer
//  (`appContainer.featureFlags`). Packages that need flag reads depend on
//  THIS package — never on Firebase, never on the app target.
//
//  Deliberately NOT here: `appRatingConfig` (returns the app-target
//  RatingConfig type — read it off the concrete impl at the composition
//  root), the DEBUG-only force-submit-failure override (build-config-forked
//  requirement), and fetch/lifecycle methods (Firebase wiring, impl-only).
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
}
