import Foundation

/// Pure visibility rules for the secondary actions on a KB match card.
///
/// Kept in TriageBotCore, alongside `HelpEntryPointPolicy`, so the rule is
/// portable and testable without a SwiftUI host (which cannot build under
/// macOS `swift test`).
public enum KBMatchActionPolicy {

    /// Whether the "Notify me" affordance should render on a KB match card.
    ///
    /// Currently always false. The affordance used to render whenever an entry
    /// carried a `fixed_in_version`, and tapping it produced a synthetic local
    /// receipt plus a reassuring message. Nothing was ever scheduled and no
    /// mechanism existed to deliver a notification, so the card promised the
    /// patron something the app could not do.
    ///
    /// `entryHasFixVersion` is the condition that gates the affordance once a
    /// real delivery path exists; return it in place of `false` to restore.
    /// The reducer still handles `.userTappedNotifyMeOnFix`, and its tests
    /// still cover that path, so restoring is a one-line change here.
    public static func showsNotifyMeOnFix(entryHasFixVersion: Bool) -> Bool {
        false
    }
}
