import Foundation

/// Async classifier that runs when the local keyword matcher escalates.
/// Concrete implementation lives in TriageBotIOS (ClaudeFallbackClassifier);
/// the protocol lives here so the reducer + ViewModel can depend on the
/// abstraction without pulling in URLSession.
///
/// **Sterilization contract.** Implementations MUST run user text through
/// `ContextRedactor.redactLine` before any byte leaves the device. The
/// redactor strips Bearer/Basic/OAuth/SAML credentials, barcode/PIN values,
/// email addresses, and UUIDs — see `AIFallbackPromptBuilder.sanitize` for
/// the canonical call site.
public protocol FallbackClassifier: Sendable {
    func classify(
        userText: String,
        category: KBCategory?,
        context: ContextSnapshot?,
        knowledgeBase: KnowledgeBase
    ) async throws -> ClassificationResult
}

public enum FallbackError: Error, Equatable {
    case offline
    case timeout
    case apiKeyMissing
    case responseUnparseable(String)
    case rateLimited
    case other(String)
}

/// Pure functions that turn a user description + KB into a Claude prompt and
/// turn Claude's JSON response into a `ClassificationResult`. Lives in
/// TriageBotCore so tests can pin the prompt shape + parser behavior without
/// any network dependency.
///
/// **Why pure functions, not a class.** The prompt is part of the contract
/// with Claude — a regression in wording can shift the model's behavior in
/// subtle ways. By keeping the prompt builder as a static function with
/// snapshot-style tests, drift becomes loud.
public enum AIFallbackPromptBuilder {

    /// Sterilize user-typed text before it leaves the device. Applies the
    /// same patterns the snapshot redactor applies to log lines — strips
    /// tokens, credentials, barcodes, PINs, emails, UUIDs. Patrons sometimes
    /// paste sensitive material into the bot ("my email is X", "my barcode
    /// is 1234..."); this is the privacy gate.
    public static func sanitize(_ userText: String, with redactor: ContextRedactor = ContextRedactor()) -> String {
        redactor.redactLine(userText)
    }

    /// Build the user-content message body sent to Claude. Returns the full
    /// prompt string; the system prompt is a separate constant.
    ///
    /// The prompt is bounded by:
    ///   - The catalog (a few KB JSON, ships in the request)
    ///   - The user's sanitized symptom text
    ///   - Optional category + distributor context
    ///
    /// Output contract pinned to a strict JSON shape (see `systemPrompt`)
    /// so the parser can fail loudly when Claude drifts.
    public static func userPrompt(
        sanitizedUserText: String,
        category: KBCategory?,
        context: ContextSnapshot?,
        knowledgeBase kb: KnowledgeBase
    ) -> String {
        var lines: [String] = []
        lines.append("# Known issues catalog")
        lines.append("")
        for entry in kb.catalog.entries where entry.visibility == .userFacing {
            lines.append("- id: \(entry.id)")
            lines.append("  category: \(entry.category.rawValue)")
            lines.append("  status: \(entry.status.rawValue)")
            if let v = entry.fixedInVersion {
                lines.append("  fixed_in_version: \(v)")
            }
            if let distributors = entry.distributorFilter, !distributors.isEmpty {
                lines.append("  distributor_filter: \(distributors.joined(separator: ", "))")
            }
            lines.append("  symptom_keywords: \(entry.symptomKeywords.joined(separator: ", "))")
            lines.append("  workaround: \(entry.userFacingWorkaround)")
            lines.append("")
        }
        lines.append("# User report")
        lines.append("")
        if let category {
            lines.append("Category the user picked: \(category.rawValue)")
        }
        if let context, let dist = context.distributor {
            lines.append("Distributor: \(dist)")
        }
        lines.append("")
        lines.append("User's description (already sanitized of credentials / emails / UUIDs):")
        lines.append("\(quoted(sanitizedUserText))")
        lines.append("")
        lines.append("# Task")
        lines.append("")
        lines.append("Pick the single KB entry that best matches the user's symptom, OR return no match if nothing fits.")
        lines.append("Respect distributor_filter — don't match an entry whose distributor_filter excludes the user's distributor.")
        lines.append("Be conservative: false positives (matching the wrong entry) are worse than false negatives (escalating).")
        lines.append("")
        lines.append("Return ONLY this JSON shape, no prose, no markdown:")
        lines.append("{\"matched_entry_id\": \"KI-...\" or null, \"confidence\": 0.0-1.0, \"reasoning\": \"one short sentence\"}")
        return lines.joined(separator: "\n")
    }

    /// System prompt for Sonnet. Sets the role + the response contract.
    public static let systemPrompt: String = """
    You are a support-ticket triage classifier for the Palace library iOS app. \
    You receive a known-issues catalog and a user's symptom description, and \
    you decide which known issue (if any) the user is reporting. You respond \
    with strict JSON only — no markdown, no prose, no preamble. False positives \
    are worse than false negatives: when uncertain, return no match.
    """

    /// Parse Claude's JSON response into a ClassificationResult, validating
    /// against the KB so a hallucinated entry id surfaces as a parser error
    /// rather than a wrong-match suggestion. Threshold for accepting Claude's
    /// match is held HIGH (0.6) so the bot only routes to a KB workaround
    /// when the model is genuinely confident.
    public static func parseResponse(
        _ json: String,
        knowledgeBase kb: KnowledgeBase,
        minimumConfidence: Double = 0.6
    ) throws -> ClassificationResult {
        struct Payload: Decodable {
            let matchedEntryId: String?
            let confidence: Double
            let reasoning: String?

            enum CodingKeys: String, CodingKey {
                case matchedEntryId = "matched_entry_id"
                case confidence
                case reasoning
            }
        }

        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8) else {
            throw FallbackError.responseUnparseable("Non-UTF8 response")
        }

        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw FallbackError.responseUnparseable("Decode failed: \(error.localizedDescription); raw: \(trimmed.prefix(200))")
        }

        guard let matchedId = payload.matchedEntryId, !matchedId.isEmpty else {
            return ClassificationResult(
                decision: .escalate,
                confidence: payload.confidence,
                matchedKeywords: [],
                consideredEntryIds: kb.catalog.entries.map(\.id)
            )
        }

        // Hallucination guard: the entry id must exist in the KB. If Claude
        // invents one we treat the response as escalate (bias toward
        // false-negative per the prompt).
        guard kb.entry(id: matchedId) != nil else {
            return ClassificationResult(
                decision: .escalate,
                confidence: 0,
                matchedKeywords: [],
                consideredEntryIds: kb.catalog.entries.map(\.id)
            )
        }

        guard payload.confidence >= minimumConfidence else {
            return ClassificationResult(
                decision: .escalate,
                confidence: payload.confidence,
                matchedKeywords: [],
                consideredEntryIds: kb.catalog.entries.map(\.id)
            )
        }

        return ClassificationResult(
            decision: .suggest(entryId: matchedId),
            confidence: payload.confidence,
            matchedKeywords: [],
            consideredEntryIds: kb.catalog.entries.map(\.id)
        )
    }

    // MARK: - Helpers

    private static func quoted(_ text: String) -> String {
        // Wrap in <description>...</description> tags so the model can't
        // confuse it with instructions even if the patron typed something
        // that looks like an instruction.
        "<description>\n\(text)\n</description>"
    }
}
