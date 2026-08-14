import Foundation

/// Pure-function classifier — given user text + (optional) context + a KB,
/// returns what the bot should do next. No I/O, no side effects, deterministic.
///
/// Matching is token-based: both the patron's text and each keyword are split
/// into word tokens, and a keyword hits when its tokens appear as a contiguous
/// run. Evidence is then counted as DISTINCT match regions — overlapping hits
/// merge, so an entry listing a phrase and its head noun scores the concept
/// once.
///
/// Regions are weighted by keyword STRENGTH: a `symptom_keywords` hit is worth a
/// full unit and can carry a suggestion alone; a `corroborating_keywords` hit is
/// worth half and never can. Score = (strong + 0.5·weak) / 3, capped at 1.0.
/// A suggestion additionally requires clearing the entry's threshold and leading
/// the runner-up. Otherwise the classifier escalates — we would rather waste a
/// triager's time on a known issue than tell a patron something wrong.
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
        // Generic ladders are remedies, not diagnoses — they never compete for a
        // match. Excluded here rather than by relying on an empty keyword list,
        // because an empty-keyword entry still enters the candidate set and would
        // surface in consideredEntryIds (and would compete outright the moment
        // someone gave a ladder a keyword).
        let matchable = rawCandidates.filter { $0.resolvedKind != .genericFlow }

        // Version-aware filter — don't surface a `fixed_in` entry to a user
        // who's already on / past the fix version. They have the fix; if
        // they're still hitting the symptom, it's a regression candidate
        // that needs to escalate, not a workaround they've already
        // implicitly accepted. Entries without `fixed_in_version`, entries
        // with `status: open`, or contexts without an app version all pass
        // through unfiltered.
        let candidates = matchable.filter { entry in
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

        // Tokenize ONCE per classify() call, not per entry per keyword.
        let textTokens = TextTokenizer.tokens(normalized)

        let scored = candidates.map { entry -> (entry: KBEntry, score: Double, matched: [String], distinctCount: Int, strongCount: Int) in
            func hits(_ keyword: String) -> Bool {
                !TextTokenizer.matchRanges(
                    of: TextTokenizer.tokens(TextNormalizer.normalize(keyword)),
                    in: textTokens
                ).isEmpty
            }
            let strongMatched = entry.symptomKeywords.filter(hits)
            let weakMatched = (entry.corroboratingKeywords ?? []).filter(hits)
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
            _ = textTokens  // tokens are consumed by `hits` above
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
        // Rank on STRENGTH first, score second. Weak regions are worth half a
        // strong one, so two vague matches tie one decisive phrase on raw score —
        // and a score-only sort let the vague entry take the top slot, where its
        // lack of strong evidence then blocked the suggest outright. The decisive
        // match lost to a competitor that could not itself answer. Strength-first
        // ordering is what makes corroborating keywords safe to add at all.
        let ranked = scored.sorted {
            $0.strongCount != $1.strongCount ? $0.strongCount > $1.strongCount : $0.score > $1.score
        }

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
        let secondStrongCount = ranked.count > 1 ? ranked[1].strongCount : 0

        // Measure the lead on the same axis the ranking used, or the guard fights
        // the sort: a 1-strong-region winner trails a 2-weak-region runner-up on
        // total regions and would fail a region-only margin despite being the
        // better match. Strong evidence decides when it differs; total regions
        // break ties between entries with equal strong evidence.
        let strongMargin = top.strongCount - secondStrongCount
        let regionMargin = top.distinctCount - secondMatchCount
        let matchCountMargin = strongMargin >= 1 ? strongMargin : regionMargin

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

        // confidenceThreshold lets an entry DEMAND more evidence than the floor.
        //
        // CALIBRATION WARNING: the scale it is read against has changed twice and
        // the shipped values have not been re-derived. Scores were once quantized
        // to {1/3, 2/3, 1.0}, which is what made "a threshold in (1/3, 2/3] means
        // require two regions" true. Weighting corroborating regions at 0.5 put
        // halves on the scale, so a 0.5 threshold is now satisfiable by one strong
        // plus one weak — the knob no longer means "region count".
        //
        // Every threshold in the shipped catalog is 0.08-0.1, and the weakest
        // possible non-zero score is one corroborating region at 1/6 = 0.167, so
        // ALL of them currently pass unconditionally: the suggest gate is carried
        // entirely by hasStrongEvidence and the margin guards. The knob is inert,
        // not protective - do not read a shipped threshold as a safety property.
        // Either re-derive these against the strong-count axis the classifier
        // actually ranks on, or delete the field.
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
                    recognizedEntryId: top.entry.id,
                    // Reached only inside the strong-evidence branch, so this
                    // recognition is strong by construction — the entry's
                    // targeted follow-up is warranted.
                    recognitionIsStrong: true
                )
            }
            return ClassificationResult(
                decision: .suggest(entryId: top.entry.id),
                confidence: top.score,
                matchedKeywords: top.matched,
                consideredEntryIds: consideredIds,
                strongRegionCount: top.strongCount
            )
        }

        // Multiple plausible matches → disambiguate by asking a follow-up.
        //
        // Only when at least one candidate is backed by a decisive phrase. Offering
        // a choice asserts we have two good guesses; if every candidate rests on
        // vague words we have none, and the patron gets a menu of topics we merely
        // brushed against. Weak-only competition falls through to the escalation
        // below, which is honest about not knowing and still scopes the ticket.
        let plausible = ranked.prefix(3).filter { $0.score > 0 }.map { $0.entry.id }
        if plausible.count >= 2 && top.strongCount >= 1 {
            return ClassificationResult(
                decision: .disambiguate(candidates: Array(plausible)),
                confidence: top.score,
                matchedKeywords: top.matched,
                consideredEntryIds: consideredIds
            )
        }

        // Low-confidence match — escalate rather than over-promise. We DID
        // recognize a topic (top.entry), just not confidently enough to suggest;
        // carry it so the ticket reaches support scoped rather than blank.
        //
        // Whether that recognition also earns the entry's targeted follow-up
        // QUESTION depends on its strength: a decisive phrase that merely lost on
        // the margin justifies asking; a lone generic word does not, because every
        // such prompt presumes its bug and would read as the bot inventing one.
        return ClassificationResult(
            decision: .escalate,
            confidence: top.score,
            matchedKeywords: top.matched,
            consideredEntryIds: consideredIds,
            recognizedEntryId: top.entry.id,
            recognitionIsStrong: top.strongCount >= 1,
            strongRegionCount: top.strongCount
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
        let textTokens = TextTokenizer.tokens(text)
        var ranges: [Range<Int>] = []
        for keyword in keywords {
            let kw = TextTokenizer.tokens(keyword)
            // First occurrence only: a concept the patron mentioned once counts
            // once, and a phrase repeated across a long complaint is still one
            // concept.
            if let first = TextTokenizer.matchRanges(of: kw, in: textTokens).first {
                ranges.append(first)
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
