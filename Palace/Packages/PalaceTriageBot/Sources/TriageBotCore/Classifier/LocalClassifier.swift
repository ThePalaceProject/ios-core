import Foundation

/// Pure-function classifier — given user text + (optional) context + a KB,
/// returns what the bot should do next. No I/O, no side effects, deterministic.
///
/// Scoring is simple keyword overlap normalized to [0, 1]: count of matched
/// keywords ÷ total keywords on the entry. Confidence threshold per entry
/// gates suggest-vs-disambiguate. Below the lowest entry threshold the
/// classifier returns .escalate — we'd rather waste a triager's time on a
/// known issue than tell the user something wrong about a novel bug.
public struct LocalClassifier: Sendable {
    public init() {}

    public func classify(
        userText: String,
        category: KBCategory? = nil,
        context: ContextSnapshot? = nil,
        knowledgeBase kb: KnowledgeBase
    ) -> ClassificationResult {
        let normalized = userText.lowercased()
        let candidates: [KBEntry]
        if let category {
            candidates = kb.entries(in: category)
                .filter { entry in passesContextFilters(entry: entry, context: context) }
        } else {
            candidates = kb.entries(matching: context)
        }

        guard !candidates.isEmpty else {
            return ClassificationResult(
                decision: .escalate,
                confidence: 0,
                matchedKeywords: [],
                consideredEntryIds: []
            )
        }

        let scored = candidates.map { entry -> (entry: KBEntry, score: Double, matched: [String]) in
            let matched = entry.symptomKeywords.filter { keyword in
                normalized.contains(keyword.lowercased())
            }
            // Score on a capped denominator: each match is worth at most 1/3,
            // saturating at 3+ matches → score 1.0. Rationale: KB entries with
            // many synonym keywords (e.g. ten ways to say "won't load") were
            // being unfairly diluted under the old matched/total formula.
            // The cap means a confident 3-keyword hit reads as "very likely"
            // regardless of how exhaustive the entry's synonym list is.
            // Calibrated against the HelpSpot-mined corpus (May 2026 batch).
            let kSaturation = 3
            let normalizedScore = min(Double(matched.count) / Double(kSaturation), 1.0)
            return (entry, normalizedScore, matched)
        }

        let consideredIds = scored.map { $0.entry.id }
        let ranked = scored.sorted { $0.score > $1.score }

        guard let top = ranked.first, top.score > 0 else {
            return ClassificationResult(
                decision: .escalate,
                confidence: 0,
                matchedKeywords: [],
                consideredEntryIds: consideredIds
            )
        }

        // Suggest only when the top score clears the entry's own threshold
        // AND beats the runner-up. Two guards:
        //   1. matchCountMargin ≥ 1 OR scoreMargin ≥ 0.1 — top must clearly lead
        //   2. runner-up score < 0.8 — when BOTH entries are at/near saturation
        //      (e.g. user stuffed keywords from multiple entries), we have
        //      genuine ambiguity and should disambiguate, not confidently pick.
        // Without #2 the keyword-stuffing chaos test would over-promote.
        let secondScore = ranked.count > 1 ? ranked[1].score : 0
        let secondMatchCount = ranked.count > 1 ? ranked[1].matched.count : 0
        let scoreMargin = top.score - secondScore
        let matchCountMargin = top.matched.count - secondMatchCount

        let runnerUpAlsoSaturated = secondScore >= 0.8
        if top.score >= top.entry.confidenceThreshold &&
           (matchCountMargin >= 1 || scoreMargin >= 0.1) &&
           !runnerUpAlsoSaturated {
            return ClassificationResult(
                decision: .suggest(entryId: top.entry.id),
                confidence: top.score,
                matchedKeywords: top.matched,
                consideredEntryIds: consideredIds
            )
        }

        // Multiple plausible matches → disambiguate by asking a follow-up
        let plausible = ranked.prefix(3).filter { $0.score > 0 }.map { $0.entry.id }
        if plausible.count >= 2 {
            return ClassificationResult(
                decision: .disambiguate(candidates: Array(plausible)),
                confidence: top.score,
                matchedKeywords: top.matched,
                consideredEntryIds: consideredIds
            )
        }

        // Single low-confidence match — escalate rather than over-promise
        return ClassificationResult(
            decision: .escalate,
            confidence: top.score,
            matchedKeywords: top.matched,
            consideredEntryIds: consideredIds
        )
    }

    private func passesContextFilters(entry: KBEntry, context: ContextSnapshot?) -> Bool {
        if let distributors = entry.distributorFilter,
           let actual = context?.distributor,
           !distributors.contains(actual) {
            return false
        }
        if let authTypes = entry.authTypeFilter,
           let actual = context?.authType,
           !authTypes.contains(actual) {
            return false
        }
        return true
    }
}
