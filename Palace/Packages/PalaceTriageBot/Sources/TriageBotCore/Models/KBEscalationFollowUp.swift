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
    /// Whether this question only makes sense if we correctly identified the
    /// issue. Defaults TRUE, because most prompts do: "is it wired CarPlay or
    /// wireless?" is excellent triage off a confident match and baffling off a
    /// lone match on the word "crashes".
    ///
    /// Set FALSE for questions that are useful no matter what the patron is
    /// actually reporting — asking which library they use, or which title is
    /// involved. Those may be asked even when recognition is weak, which is how a
    /// hand-off we could not answer still reaches support with something in it.
    ///
    /// This is a property of the PROMPT's wording, not of the entry: it says "this
    /// sentence is safe to say to someone whose problem we may have misread."
    let presumesIssue: Bool

    enum CodingKeys: String, CodingKey {
        case prompt
        case placeholder
        case diagnostic
        case presumesIssue = "presumes_issue"
    }

    init(
        prompt: String,
        placeholder: String? = nil,
        diagnostic: String? = nil,
        presumesIssue: Bool = true
    ) {
        self.prompt = prompt
        self.placeholder = placeholder
        self.diagnostic = diagnostic
        self.presumesIssue = presumesIssue
    }

    // PUBLIC_INTENT: not a choice — Swift requires the witness for a public
    // protocol requirement to be public, and `KBEscalationFollowUp` is a public
    // `Decodable` type. Established by flipping it to `internal`, which fails the
    // build with "must be declared public because it matches a requirement in
    // public protocol 'Decodable'". The other 26 declarations flagged alongside
    // it built clean as `internal` and were narrowed instead.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        prompt = try c.decode(String.self, forKey: .prompt)
        placeholder = try c.decodeIfPresent(String.self, forKey: .placeholder)
        diagnostic = try c.decodeIfPresent(String.self, forKey: .diagnostic)
        // Absent in JSON means "presumes the issue" — the conservative reading,
        // so an existing catalog cannot start asking its prompts off weak matches
        // just because a field was added.
        presumesIssue = try c.decodeIfPresent(Bool.self, forKey: .presumesIssue) ?? true
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
