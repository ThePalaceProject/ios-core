import Foundation

/// Pure predicate for the single security invariant that keeps the network-backed
/// Claude AI fallback **inert by default**: the fallback classifier is only ever
/// wired behind the local keyword matcher when BOTH a remote kill-switch flag is
/// on AND an API key is actually present on the device. Either condition alone is
/// not enough — a flag with no key, or a key with the flag off, both stay local-only.
///
/// The host composition root (`TriageBotFactory`) is the only caller, but the
/// factory imports UIKit/Firebase and cannot be unit-tested inside the package.
/// Extracting the decision here (no UIKit) means the invariant is exercised by
/// `swift test` on macOS, so a refactor that accidentally loosens it — e.g. wiring
/// the fallback on the flag alone — fails a table test rather than shipping silently.
public enum TriageBotAIWiring {

    /// Whether the AI fallback classifier should be wired.
    ///
    /// - Parameters:
    ///   - flagEnabled: the `triage_bot_ai_fallback_enabled` Remote Config value.
    ///   - keyPresent: whether an Anthropic API key is present (Keychain, after
    ///     the DEBUG env bootstrap).
    /// - Returns: `true` only when the flag is enabled **and** a key is present.
    public static func aiWiring(flagEnabled: Bool, keyPresent: Bool) -> Bool {
        flagEnabled && keyPresent
    }
}
