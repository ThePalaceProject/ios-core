import Foundation

/// One open-ended question the bot asks the user RIGHT BEFORE it files
/// the escalation ticket. Gives support a structured piece of context
/// that would otherwise require a back-and-forth ("which library are you
/// trying to add?", "which audiobook title is hanging?", "what car
/// model?"). The answer attaches to `TicketDraft.escalationFollowUp` and
/// surfaces inline in the email body, so the triager opens the ticket
/// with the answer already there.
///
/// Always optional — users can tap "Skip this question" if they're not
/// sure. Skipped questions still attach to the ticket so support sees
/// "user declined to answer" (a signal in itself).
public struct KBEscalationFollowUp: Codable, Equatable, Sendable {
    /// Patron-facing question. Should be one sentence, ending with a
    /// question mark. ("Which library are you trying to add?")
    public let prompt: String
    /// Hint text inside the input field. Useful when the answer shape
    /// isn't obvious from the prompt. ("City or library name")
    public let placeholder: String?
    /// Optional telemetry tag — emitted on answered + skipped events
    /// so support can see which follow-ups patrons actually answer vs
    /// skip past.
    public let diagnostic: String?

    public init(prompt: String, placeholder: String? = nil, diagnostic: String? = nil) {
        self.prompt = prompt
        self.placeholder = placeholder
        self.diagnostic = diagnostic
    }
}

/// What the user answered (or skipped). Attaches to TicketDraft so the
/// email body + preview can render the structured context. `answer == nil`
/// means the user explicitly skipped — different from "no question
/// existed" (entry without `escalationFollowUp` simply doesn't surface
/// this field).
public struct EscalationFollowUpAnswer: Codable, Equatable, Sendable {
    public let prompt: String
    /// User's free-text answer, or nil if they tapped Skip.
    public let answer: String?

    public init(prompt: String, answer: String?) {
        self.prompt = prompt
        self.answer = answer
    }
}
