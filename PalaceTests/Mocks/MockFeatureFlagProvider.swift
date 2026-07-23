//
//  MockFeatureFlagProvider.swift
//  PalaceTests
//
//  Test double for the consolidated FeatureFlagProviding seam
//  (PalaceFeatureFlags, Wave 1b). Lets tests control which flag branches
//  consumers exercise without reaching RemoteFeatureFlags.shared.
//

import Foundation
import PalaceFeatureFlags

/// Mutable flags are set once during arrange and read on the test's serial
/// flow; `@unchecked Sendable` documents that confinement (the inherited
/// `FeatureFlagProviding: Sendable` requirement forbids plain `var`s otherwise).
final class MockFeatureFlagProvider: FeatureFlagProviding, @unchecked Sendable {
    var isOPDS2Enabled: Bool
    var isCarPlayEnabled = false
    var isCarPlayEnabledCached = false
    var isTriageBotEnabled = false
    var isTriageBotTicketSubmissionEnabled = false
    var isTriageBotAIFallbackEnabled = false
    var isInAppPlaybackNavEnabled = false
    var isContinuationCardsEnabled = false
    var isSideLoadingEnabled = false
    var isAppRatingPromptEnabled = false
    var isAppRatingForceEligible = false

    /// Per-flag overrides for the raw read; absent flags fall back to the
    /// flag's declared default (mirrors the no-Firebase production fallback).
    var rawFlagOverrides: [PalaceFeatureFlag: Bool] = [:]

    func isFeatureEnabled(_ feature: PalaceFeatureFlag) -> Bool {
        rawFlagOverrides[feature] ?? feature.defaultValue
    }

    init(isOPDS2Enabled: Bool = false) {
        self.isOPDS2Enabled = isOPDS2Enabled
    }
}
