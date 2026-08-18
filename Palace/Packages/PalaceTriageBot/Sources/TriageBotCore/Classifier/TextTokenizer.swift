import Foundation

/// Splits patron text and KB keywords into comparable word tokens.
///
/// Matching used to be `text.contains(keyword)`, which has no notion of a word
/// boundary. That was survivable while a known-issue entry needed two matches to
/// suggest — one accidental substring could not carry a decision on its own.
/// Once a single decisive phrase became sufficient, every accidental substring
/// became a full workaround card, and the catalog contains keywords that are
/// substrings of ordinary words:
///
///     "stalled"  ⊂  "I reinstalled the app"      → download-no-network advice
///     "add"      ⊂  "additional"
///     "card"     ⊂  "discard"
///
/// The first is not hypothetical — "reinstalled the app" is one of the most
/// common sentences in the support corpus, and it was matching KI-008's
/// `stalled` and suggesting a network fix for a launch crash.
///
/// Tokenizing both sides fixes the whole class at once. Pure Swift with no
/// Foundation-locale or NaturalLanguage dependency, so `TriageBotCore` stays
/// KMP-portable: the Kotlin port splits on the same rule and gets the same
/// tokens.
enum TextTokenizer {

    /// Lowercased alphanumeric runs. Everything else — spaces, apostrophes,
    /// hyphens, punctuation — separates.
    ///
    /// Apostrophes SEPARATE rather than bind, so "won't" becomes ["won", "t"].
    /// That looks lossy in isolation and is not, because the same rule is applied
    /// to the keyword: `won't download` and `wont download` both tokenize to
    /// ["won", "t", "download"] and ["wont", "download"] respectively, and the
    /// patron's text tokenizes the same way it was written. Consistency across
    /// both sides is what matters, not linguistic fidelity.
    static func tokens(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for ch in text.lowercased() {
            if ch.isLetter || ch.isNumber {
                current.append(ch)
            } else if !current.isEmpty {
                out.append(current)
                current = ""
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// Determiners and possessives. These vary freely between patrons describing
    /// the same thing ("on kindle" / "on my kindle", "keep the book longer" /
    /// "keep this book longer") and carry no diagnostic content of their own.
    ///
    /// Pronouns are deliberately absent. "it" reads like filler but is the only
    /// thing standing between `give it back early` and `give back`, and dropping
    /// that class widens keywords far more than determiners do.
    static let fillerTokens: Set<String> = [
        "a", "an", "the", "this", "that", "these", "those",
        "my", "your", "his", "her", "its", "our", "their"
    ]

    /// Token-index ranges where `keyword` occurs inside `text`. Empty when the
    /// keyword does not occur, or is empty.
    ///
    /// Returns EVERY occurrence, not just the first: a phrase repeated in a long
    /// complaint is still one concept, and leaving the merge to the caller keeps
    /// that decision in one place.
    ///
    /// With `allowingFillerVariation` a filler token in the keyword may be
    /// matched by a DIFFERENT filler token in the text — `keep the book longer`
    /// matches "keep this book longer", `return the book` matches "return my
    /// book". The match stays a contiguous, equal-length run; only the identity
    /// of a filler is allowed to vary.
    ///
    /// Two looser rules were implemented, measured, and REJECTED — both widen
    /// what a keyword covers rather than just tolerating how it is spelled:
    ///
    ///  - **Insertion** (skipping a text filler the keyword lacks, so `on
    ///    kindle` matches "on my kindle"). Measured against the rejection
    ///    corpus, this made "the app switched my library on its own and lost my
    ///    place" match KI-002's `switched library` and suggest an LCP playback
    ///    workaround for what is a reading-position complaint. It bought four
    ///    paraphrase cells and cost a real misroute.
    ///  - **Elision** (a keyword filler matching nothing). An audit of all 257
    ///    shipped keywords found this collapses the STRONG keywords
    ///    "notification that" / "notifications that" (KI-006) to the bare words,
    ///    so any patron who typed "notification" would strongly match the
    ///    hold-desync issue — chaos-qa F-002 rebuilt from scratch.
    ///
    /// Both refusals are pinned by `FillerVariationMatchingTests`.
    ///
    /// Callers that need the exact-run rule (RemedyDetector, which matches
    /// destructive-action claims) simply omit the flag.
    static func matchRanges(
        of keyword: [String],
        in text: [String],
        allowingFillerVariation: Bool = false
    ) -> [Range<Int>] {
        guard !keyword.isEmpty, keyword.count <= text.count else { return [] }

        guard allowingFillerVariation else {
            var ranges: [Range<Int>] = []
            for start in 0...(text.count - keyword.count) {
                if Array(text[start..<(start + keyword.count)]) == keyword {
                    ranges.append(start..<(start + keyword.count))
                }
            }
            return ranges
        }

        // A keyword thin enough that fillers carry its specificity gets NO
        // variation. `notification that` has one content word; letting its
        // trailing `that` stand in for any other filler collapses it to
        // "notification + <any determiner>", which is the bare-word F-002 the
        // elision refusal above was written to prevent, reached by a different
        // route. Both SoD reviewers found this independently on the shipped
        // catalog: "I never received a notification my book was due" was handed
        // the KI-006 hold-desync workaround. Enforced at authoring time too, by
        // `CatalogSchemaLintTests`.
        guard keyword.filter({ !fillerTokens.contains($0) }).count >= 2 else {
            return matchRanges(of: keyword, in: text)
        }

        // Equal-length run, exactly as in strict mode — only filler IDENTITY may
        // differ, so the window arithmetic is unchanged.
        var ranges: [Range<Int>] = []
        for start in 0...(text.count - keyword.count) {
            var matched = true
            for offset in 0..<keyword.count {
                let kw = keyword[offset], tx = text[start + offset]
                if kw == tx { continue }
                // A keyword filler is CONSUMED by a text filler, never elided.
                if fillerTokens.contains(kw), fillerTokens.contains(tx) { continue }
                matched = false
                break
            }
            if matched { ranges.append(start..<(start + keyword.count)) }
        }
        return ranges
    }
}
