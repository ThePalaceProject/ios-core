#if DEBUG
import Foundation

/// DEBUG-only `TicketGateway` that always fails, so QA / simdrive / the chaos
/// run can drive the ticket-submission error+retry UI (AC-8/9) on a bare
/// simulator.
///
/// **Why this exists.** On a bare simulator `MFMailComposeViewController
/// .canSendMail()` is false, so both the email and clipboard gateway branches
/// resolve to `ClipboardTicketGateway`, which always succeeds. Without this,
/// there was no way to reach the "Couldn't send / Try again / Copy details /
/// Start over" failure card on-screen — AC-8/9 were only covered by
/// unit/reducer tests, never driven in the UI.
///
/// The host (`TriageBotFactory`) injects this in place of the real gateway
/// only when the "Force ticket submission failure" developer toggle (or the
/// `-TriageBotForceSubmitFailure 1` launch argument) is on. It throws a
/// `ForcedSubmissionError`, which conforms to `SubmissionFailureConvertible`,
/// so the ViewModel maps it exactly like a real gateway error — the injected
/// failure lands on the genuine production `.error` recovery path (or the
/// cancel-restores-preview path), never a fake one.
///
/// Compiled only in DEBUG builds (`#if DEBUG`); no trace of it exists in
/// release.
public struct ForcedFailureTicketGateway: TicketGateway {
    /// Which failure to inject.
    /// - `.transport`: a real failure — lands on the `.error` recovery card
    ///   (Try again / Copy details / Start over). This is the AC-8/9 path.
    /// - `.userCancelled`: exercises the "cancel restores the preview" path.
    public enum Mode: Sendable {
        case transport
        case userCancelled
    }

    private let mode: Mode

    public init(mode: Mode = .transport) {
        self.mode = mode
    }

    public func submit(_ draft: TicketDraft) async throws -> TicketReceipt {
        throw ForcedSubmissionError(mode: mode)
    }
}

/// Error thrown by ``ForcedFailureTicketGateway``. Conforms to
/// `SubmissionFailureConvertible` so it maps through the exact same path the
/// ViewModel uses for real gateway errors — no special-casing, no fake UI.
public struct ForcedSubmissionError: Error, SubmissionFailureConvertible {
    public let mode: ForcedFailureTicketGateway.Mode

    public init(mode: ForcedFailureTicketGateway.Mode) {
        self.mode = mode
    }

    public var asSubmissionFailure: SubmissionFailure {
        switch mode {
        case .transport:
            return .transport(detail: "DEBUG: forced ticket-submission failure (developer toggle)")
        case .userCancelled:
            return .userCancelled
        }
    }
}
#endif
