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
    case audiobookPlayer
}

/// Pure decision for whether the shared Help affordance should be visible at a
/// given entry point. Centralizes the two rules every entry point must obey:
///
///   1. **AC-14 kill-switch:** when `isTriageBotEnabled` is off, every entry
///      point vanishes together — no Settings row, no toolbar button, no
///      audiobook overlay.
///   2. **Audiobook mini-player collision:** the audiobook Help control lives in
///      the FULL player chrome only. On the mini-player it would sit on top of
///      the transport row, so it stays hidden until the player is expanded.
///
/// Extracted here so both rules are mutation-testable in isolation from the
/// SwiftUI hosts (which can't build under macOS `swift test`).
public enum HelpEntryPointPolicy {

    /// - Parameters:
    ///   - entryPoint: which surface is asking.
    ///   - triageBotEnabled: the master kill-switch
    ///     (`RemoteFeatureFlags.shared.isTriageBotEnabled` on iOS).
    ///   - audiobookPlayerExpanded: for `.audiobookPlayer`, whether the full
    ///     player is currently expanded. Ignored for every other entry point.
    /// - Returns: whether the Help affordance should render.
    public static func shouldShowHelp(
        at entryPoint: HelpEntryPoint,
        triageBotEnabled: Bool,
        audiobookPlayerExpanded: Bool = false
    ) -> Bool {
        guard triageBotEnabled else { return false }
        switch entryPoint {
        case .audiobookPlayer:
            return audiobookPlayerExpanded
        case .bookDetail, .signIn:
            return true
        }
    }
}
