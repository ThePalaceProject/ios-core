import Foundation

/// The surfaces that host the shared `HelpButton` — the flag-gated entry into
/// the triage bot. Kept in TriageBotCore (not the host) so the visibility rule
/// is pure, KMP-portable, and testable without a UIKit/SwiftUI host.
///
/// NB: the Settings "Get Help" row is intentionally NOT here — it resolves
/// through `SupportSectionDecision` (which adds a legacy-email fallback when the
/// bot is off), gated on the same `isTriageBotEnabled` kill-switch. This enum
/// covers only the surfaces that construct a `HelpButton`.
public enum HelpEntryPoint: String, Sendable, CaseIterable {
    case bookDetail
    case signIn
}

/// Pure decision for whether the shared Help affordance should be visible at a
/// given entry point. Centralizes the AC-14 kill-switch: when
/// `isTriageBotEnabled` is off, every entry point vanishes together — no
/// Settings row and no toolbar Help button. Extracted here so the rule is
/// mutation-testable in isolation from the SwiftUI hosts (which can't build
/// under macOS `swift test`).
public enum HelpEntryPointPolicy {

    /// - Parameters:
    ///   - entryPoint: which surface is asking (kept for call-site clarity and
    ///     the stable accessibility identifier the host derives from it).
    ///   - triageBotEnabled: the master kill-switch
    ///     (`RemoteFeatureFlags.shared.isTriageBotEnabled` on iOS).
    /// - Returns: whether the Help affordance should render.
    public static func shouldShowHelp(
        at entryPoint: HelpEntryPoint,
        triageBotEnabled: Bool
    ) -> Bool {
        triageBotEnabled
    }
}
