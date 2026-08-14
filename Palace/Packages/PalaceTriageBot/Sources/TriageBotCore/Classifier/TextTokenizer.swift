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

    /// Token-index ranges where `keyword` occurs as a contiguous run inside
    /// `text`. Empty when the keyword does not occur, or is empty.
    ///
    /// Returns EVERY occurrence, not just the first: a phrase repeated in a long
    /// complaint is still one concept, and leaving the merge to the caller keeps
    /// that decision in one place.
    static func matchRanges(of keyword: [String], in text: [String]) -> [Range<Int>] {
        guard !keyword.isEmpty, keyword.count <= text.count else { return [] }
        var ranges: [Range<Int>] = []
        for start in 0...(text.count - keyword.count) {
            if Array(text[start..<(start + keyword.count)]) == keyword {
                ranges.append(start..<(start + keyword.count))
            }
        }
        return ranges
    }
}
