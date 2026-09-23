import Foundation

/// Why a ticket submission didn't complete. PP-4808: the reducer must never
/// dead-end the user on a failure, so it needs to distinguish a *user backing
/// out* (not a failure — restore the preview and let them retry) from a *real
/// transport problem* (offer Retry / Copy details / Start over and persist the
/// draft so it survives to the next chat open).
///
/// Lives in TriageBotCore so the reducer can branch on it without importing
/// MessageUI / the iOS gateway. Concrete gateway errors map into this via
/// `SubmissionFailureConvertible`.
public enum SubmissionFailure: Equatable, Sendable {
    /// User cancelled the OS composer / share sheet. Nothing was sent and
    /// nothing is wrong — the reducer restores the ticket preview.
    case userCancelled
    /// A real failure (no mail account, composer error, network, server).
    /// `detail` is a raw, possibly-technical string surfaced ONLY behind a
    /// "Copy details" affordance — never shown inline (see UserFacingErrorMessage).
    case transport(detail: String)
}

/// Bridges a concrete gateway `Error` to a `SubmissionFailure`. The iOS
/// `EmailGatewayError` conforms in TriageBotIOS; the ViewModel maps any thrown
/// error through this and falls back to `.transport(detail:)` for unknown
/// errors, so no error can strand the user.
public protocol SubmissionFailureConvertible {
    var asSubmissionFailure: SubmissionFailure { get }
}

/// Pure mapping from a failure to the patron-facing sentence. Replaces the old
/// raw `error.localizedDescription` interpolation (PP-4808) — a technical
/// server message never appears in the chat; the raw detail is reachable only
/// via Copy details.
public enum UserFacingErrorMessage {
    public static func from(_ failure: SubmissionFailure) -> String {
        switch failure {
        case .userCancelled:
            return "No problem — nothing was sent. Your ticket is still here whenever you're ready."
        case .transport:
            return "I couldn't send your ticket. You can try again, copy the details to email support yourself, or start over — nothing was lost."
        }
    }
}
