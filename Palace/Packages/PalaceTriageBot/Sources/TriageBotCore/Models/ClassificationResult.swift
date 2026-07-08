import Foundation

/// What the bot decided to do with a user's message. Pure data — the reducer
/// consumes this and chooses the next conversational step. Never carries the
/// matched KB entry's body text; the UI looks it up by id so the redaction
/// rules in ContextRedactor can't be bypassed.
public struct ClassificationResult: Equatable, Sendable {
    public enum Decision: Equatable, Sendable {
        /// High-confidence match — render the entry's workaround / fixed-in
        /// response and offer notify-me / file-anyway / dismiss.
        case suggest(entryId: String)
        /// Low confidence; the bot should ask one disambiguating question
        /// before deciding between suggest and escalate.
        case disambiguate(candidates: [String])
        /// No match — go straight to ticket draft with the user's text and
        /// the context snapshot.
        case escalate
    }

    public let decision: Decision
    public let confidence: Double
    public let matchedKeywords: [String]
    public let consideredEntryIds: [String]

    public init(
        decision: Decision,
        confidence: Double,
        matchedKeywords: [String] = [],
        consideredEntryIds: [String] = []
    ) {
        self.decision = decision
        self.confidence = confidence
        self.matchedKeywords = matchedKeywords
        self.consideredEntryIds = consideredEntryIds
    }
}
