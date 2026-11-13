//
//  FoldedSearchQuery.swift
//  PalaceUtilities
//
//  PP-5021: match the text a patron meant, not the characters iOS substituted.
//

import Foundation

/// A search query prepared for comparison against text the app already holds.
///
/// **Why this exists.** iOS applies smart-punctuation substitution inside the
/// input system, so a patron typing `Alice's` lands `Alice\u{2019}s` in any field
/// that has not disabled the trait. The titles being filtered carry whichever
/// form the catalogue used. `localizedCaseInsensitiveContains` treats the two
/// apostrophes as different characters, so a correctly typed title returned
/// nothing and the patron saw an empty shelf.
///
/// **Why folding rather than disabling the keyboard's substitution.** Where the
/// comparison happens in our own code — the My Books and Holds filters — we hold
/// both sides, so folding both is strictly better than constraining the input:
/// it works whichever form the patron's text arrives in (typed, pasted or
/// dictated) and whichever form the title uses. Catalog search cannot do this,
/// because the comparison happens on the server; there the only available fix is
/// to stop the substitution at the field, which is what `VerbatimTextField` does.
/// Searching *inside* a publication is the same shape as catalog search — Readium
/// and PDFKit own that comparison — so neither approach reaches it.
///
/// Fold both sides or neither. Comparing a folded query against unfolded text
/// silently matches less than before, which is why the folding is held in a type
/// that owns both halves instead of exposed as a `String` helper a caller can
/// apply to one side.
///
/// **Why not reuse `TextNormalizer`.** The triage bot's `TextNormalizer` already
/// folds the same two character classes, for the same reason, and its own doc
/// states the fold-both-sides rule. It is not reused here on purpose: it is tuned
/// for keyword recall against the triage corpus, so someone widening it to catch
/// another phrasing would silently change which books a patron can find. The
/// duplication is two small tables; the coupling would be a shared knob with two
/// unrelated owners. PalaceUtilities also declares no dependencies by design, and
/// reaching into the triage bot's package from the app's search path would add an
/// edge pointing the wrong way.
// PUBLIC_INTENT: crosses the SPM boundary. The two callers (MyBooksViewModel,
// HoldsViewModel) are in the app target, so `internal` would not compile.
// `Sendable` because MyBooks filters inside a `Task.detached`.
public struct FoldedSearchQuery: Sendable, Equatable {

    /// Apostrophe shapes that mean the same thing to a reader. U+2019 is what the
    /// keyboard types; U+2018 appears in titles typeset with the opening quote in
    /// the possessive position; U+02BC is the correct okina and is present in real
    /// catalogue records.
    private static let apostropheVariants: Set<Character> = ["\u{2019}", "\u{2018}", "\u{02BC}"]

    /// Dash and hyphen shapes that mean the same thing to a reader, including the
    /// non-breaking hyphen and the minus sign.
    private static let hyphenVariants: Set<Character> = [
        "\u{2010}", "\u{2011}", "\u{2012}", "\u{2013}", "\u{2014}", "\u{2212}"
    ]

    private let folded: String

    // PUBLIC_INTENT: the only way to construct the type from the app target.
    public init(_ query: String) {
        folded = Self.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// True when the query holds nothing to match on. Callers branch on this to
    /// restore the unfiltered list rather than relying on `matches` returning
    /// true for everything.
    // PUBLIC_INTENT: both callers branch on it to restore the unfiltered list.
    public var isEmpty: Bool { folded.isEmpty }

    /// True when `candidate` contains this query, with both sides folded.
    ///
    /// A nil candidate is no match: a book's `authors` is optional, and a missing
    /// value should not match a query the patron typed.
    // PUBLIC_INTENT: the predicate both filters call; the whole point of the type.
    public func matches(_ candidate: String?) -> Bool {
        guard let candidate else { return false }
        guard !folded.isEmpty else { return true }
        return Self.fold(candidate).contains(folded)
    }

    /// Lowercases and collapses the punctuation variants above to their ASCII
    /// spelling. Deliberately leaves diacritics alone: folding them would change
    /// matching for every non-English title in the catalogue, which is a separate
    /// decision from undoing a keyboard substitution.
    private static func fold(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for character in text.lowercased() {
            if apostropheVariants.contains(character) {
                result.append("'")
            } else if hyphenVariants.contains(character) {
                result.append("-")
            } else {
                result.append(character)
            }
        }
        return result
    }
}
