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
        let normalized = TextNormalizer.normalize(userText)
        let rawCandidates: [KBEntry]
        if let category {
            rawCandidates = kb.entries(in: category)
                .filter { entry in passesContextFilters(entry: entry, context: context) }
        } else {
            rawCandidates = kb.entries(matching: context)
        }

        // Version-aware filter — don't surface a `fixed_in` entry to a user
        // who's already on / past the fix version. They have the fix; if
        // they're still hitting the symptom, it's a regression candidate
        // that needs to escalate, not a workaround they've already
        // implicitly accepted. Entries without `fixed_in_version`, entries
        // with `status: open`, or contexts without an app version all pass
        // through unfiltered.
        let candidates = rawCandidates.filter { entry in
            // Only known-issue `fixed_in` entries are version-gated. how_to
            // (general-help) entries have no fix version and must always
            // surface — a "how do I renew?" answer never expires against a
            // build number.
            guard entry.resolvedKind == .knownIssue, entry.status == .fixedIn else { return true }
            return !FixVersionGate.userAlreadyHasFix(for: entry, userAppVersion: context?.appVersion)
        }

        guard !candidates.isEmpty else {
            return ClassificationResult(
                decision: .escalate,
                confidence: 0,
                matchedKeywords: [],
                consideredEntryIds: []
            )
        }

        let scored = candidates.map { entry -> (entry: KBEntry, score: Double, matched: [String], distinctCount: Int, strongCount: Int) in
            let strongMatched = entry.symptomKeywords.filter { keyword in
                normalized.contains(TextNormalizer.normalize(keyword))
            }
            let weakMatched = (entry.corroboratingKeywords ?? []).filter { keyword in
                normalized.contains(TextNormalizer.normalize(keyword))
            }
            let matched = strongMatched + weakMatched

            // Count DISTINCT non-overlapping regions of the patron's text — not
            // raw keyword-list hits. A single word ("hangs") substring-matches
            // every nested variant an entry lists ("hang", "hangs"), which
            // inflated the raw count. Counting merged match regions collapses
            // those synonyms to the one concept the patron actually mentioned.
            //
            // Strong and weak regions are counted SEPARATELY, because they answer
            // different questions: strong regions decide whether we may suggest at
            // all, weak regions only shade how confident the suggestion reads.
            let strongCount = Self.distinctMatchRegionCount(
                of: strongMatched.map { TextNormalizer.normalize($0) },
                in: normalized
            )
            let totalCount = Self.distinctMatchRegionCount(
                of: matched.map { TextNormalizer.normalize($0) },
                in: normalized
            )
            let weakCount = max(totalCount - strongCount, 0)

            // A strong region is worth a full unit, a weak one half — a generic
            // "stuck" alongside "won't play" should sharpen the match, not count
            // as much as a second decisive phrase. Saturates at 3.0 → 1.0, so a
            // confident hit reads as "very likely" regardless of how exhaustive
            // the entry's synonym list is.
            let kSaturation = 3.0
            let weightedEvidence = Double(strongCount) + 0.5 * Double(weakCount)
            let normalizedScore = min(weightedEvidence / kSaturation, 1.0)
            return (entry, normalizedScore, matched, totalCount, strongCount)
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
        // AND beats the runner-up. THREE guards:
        //   1. matchCountMargin ≥ 1 — top must lead by at least one region
        //   2. runner-up score < 0.8 — when BOTH entries are at/near saturation
        //      (e.g. user stuffed keywords from multiple entries), we have
        //      genuine ambiguity and should disambiguate, not confidently pick.
        //   3. top.strongCount ≥ 1 — the precision guard. See below.
        let secondScore = ranked.count > 1 ? ranked[1].score : 0
        let secondMatchCount = ranked.count > 1 ? ranked[1].distinctCount : 0
        let matchCountMargin = top.distinctCount - secondMatchCount

        // The precision guard: at least one STRONG match region, for every kind.
        //
        // This replaces a per-kind COUNT floor (known_issue needed ≥2 regions of
        // any kind, how_to needed 1). That floor was a proxy for evidence quality
        // — chaos-qa F-002 (2026-05-29) showed a lone weak match could route a
        // generic auth-loop complaint to the wrong-library workaround, and
        // requiring two matches made that unlikely. But it was a bad proxy: it
        // also suppressed the single DECISIVE phrase. Measured on the shipped
        // catalog, 17 of 21 realistic patron phrasings escalated, including ones
        // where the classifier had already identified the right entry — a patron
        // typing "my book won't download" was told "I haven't seen exactly that
        // before" (PP-4865).
        //
        // Gating on strength instead of count keeps F-002 closed — a weak word
        // alone still cannot suggest, which is what that defect actually was —
        // while letting one decisive phrase through, which is how patrons write.
        // how_to entries are unaffected: they carry no corroborating keywords, so
        // every match they can make is strong and their floor stays effectively 1.
        //
        // The partition is enforced by CatalogSchemaLintTests, so a generic word
        // cannot drift back into `symptom_keywords` and quietly become sufficient.
        let hasStrongEvidence = top.strongCount >= 1

        // confidenceThreshold lets an individual entry DEMAND more evidence than
        // its kind floor. Scores are quantized to {1/3, 2/3, 1.0} (1, 2, 3+
        // regions), so a threshold in (1/3, 2/3] means "require ≥2 regions" and
        // (2/3, 1.0] means "require ≥3". A threshold ≤ 1/3 is a no-op beyond the
        // kind floor. Shipped catalog entries sit at the floor; the knob exists
        // for a future entry so broad it needs 3 regions to be safe.
        //
        // NOTE: the old `scoreMargin >= 0.1` disjunct was removed — with quantized
        // scores, scoreMargin ≥ 0.1 can only happen when the region counts differ,
        // which already implies matchCountMargin ≥ 1. It was provably dead.
        let runnerUpAlsoSaturated = secondScore >= 0.8
        if top.score >= top.entry.confidenceThreshold &&
           hasStrongEvidence &&
           matchCountMargin >= 1 &&
           !runnerUpAlsoSaturated {
            // escalate_anyway: recognized AND confident, but this class of problem
            // has no safe self-serve fix (e.g. an account-side error only staff can
            // resolve). Route to a human carrying the recognized context — so the
            // escalation asks the entry's targeted follow-up and files a scoped
            // ticket — rather than showing a workaround the patron can't act on.
            if top.entry.escalateAnyway {
                return ClassificationResult(
                    decision: .escalate,
                    confidence: top.score,
                    matchedKeywords: top.matched,
                    consideredEntryIds: consideredIds,
                    recognizedEntryId: top.entry.id
                )
            }
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

        // Single low-confidence match — escalate rather than over-promise. We DID
        // recognize a topic (top.entry), just not confidently enough to suggest;
        // carry it so the escalation can ask that entry's targeted follow-up and
        // hand support a scoped ticket instead of a blank hand-off.
        return ClassificationResult(
            decision: .escalate,
            confidence: top.score,
            matchedKeywords: top.matched,
            consideredEntryIds: consideredIds,
            recognizedEntryId: top.entry.id
        )
    }

    /// Count how many distinct, non-overlapping regions of `text` are covered
    /// by any of `keywords` (all already normalized). Nested variants
    /// ("hang" ⊂ "hangs") and positional overlaps ("won't download" ⊃
    /// "download") collapse to a single region, so a concept the patron
    /// mentioned once counts once — not once per synonym the entry lists.
    /// Uses each keyword's first occurrence; merges overlapping/touching
    /// ranges and returns the cluster count.
    static func distinctMatchRegionCount(of keywords: [String], in text: String) -> Int {
        var ranges: [Range<String.Index>] = []
        for keyword in keywords where !keyword.isEmpty {
            if let range = text.range(of: keyword) {
                ranges.append(range)
            }
        }
        guard !ranges.isEmpty else { return 0 }

        ranges.sort { $0.lowerBound < $1.lowerBound }
        var clusters = 1
        var currentUpper = ranges[0].upperBound
        for range in ranges.dropFirst() {
            if range.lowerBound >= currentUpper {
                clusters += 1
                currentUpper = range.upperBound
            } else if range.upperBound > currentUpper {
                currentUpper = range.upperBound
            }
        }
        return clusters
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
