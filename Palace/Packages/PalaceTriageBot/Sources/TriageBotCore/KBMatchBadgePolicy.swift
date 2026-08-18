import Foundation

/// What the badge at the top of a KB match card claims about the entry below it.
///
/// Semantic rather than presentational so the decision lives in `TriageBotCore`
/// (testable under macOS `swift test`) while `TriageBotUI` — which sits behind
/// `canImport(UIKit)` and cannot be reached by the package's own tests — only
/// maps a case to a string, an SF Symbol, and a colour.
public enum KBMatchBadge: Equatable, Sendable {
    case fixedIn(version: String)
    case knownIssueFixComing(version: String)
    case knownIssueWorkaround
    case setupMixUp
    case byDesign
    case tracked
    /// An authoritative answer to a question the patron asked.
    case howTo
    /// A generic troubleshooting ladder — NOT an answer. See the policy below.
    case narrowingDown
}

/// Chooses the badge for a KB entry.
///
/// The rule that matters is the first one: a `generic_flow` entry is not a
/// how-to and must not be badged as one.
///
/// Generic ladders carry no `status`, and the badge previously switched on
/// `status` alone, so all five of them fell into the same `nil` arm as the
/// how-to entries and were labelled "How to". That is the most misleading
/// possible label for them. A how-to card states a fact the patron asked for
/// ("Palace doesn't renew loans inside the app — borrow the title again"); a
/// generic ladder is what the bot shows when it did NOT recognise the problem,
/// and its body reads "Two things worth checking before we send this to
/// support." Badging the second as the first makes a failed match look like an
/// answer — a patron who asked how to renew a loan was shown a "How to" card
/// whose first step was "check which library is selected… are your books
/// there?" (observed on device, PP-4865 follow-up).
///
/// Kind is checked before status precisely because status cannot distinguish
/// them: both arms are `nil`.
public enum KBMatchBadgePolicy {

    public static func badge(for entry: KBEntry) -> KBMatchBadge {
        // Kind first — a generic ladder and a how-to are indistinguishable by
        // status (both carry none), and conflating them is the defect.
        if entry.resolvedKind == .genericFlow { return .narrowingDown }

        switch entry.status {
        case .fixedIn:
            return .fixedIn(version: entry.fixedInVersion ?? "next release")
        case .open:
            if let version = entry.fixedInVersion {
                return .knownIssueFixComing(version: version)
            }
            return .knownIssueWorkaround
        case .userError:   return .setupMixUp
        case .wontfix:     return .byDesign
        case .duplicateOf: return .tracked
        case .none:        return .howTo
        }
    }
}
