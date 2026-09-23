import Foundation

/// Folds patron text and KB keywords into a single comparison space so the
/// classifier's substring matching is stable across the quirks of a real iOS
/// keyboard. Two device realities the old `lowercased()`-only path missed:
///
///  - **Smart punctuation.** The iOS keyboard types a curly apostrophe (U+2019)
///    by default, so a patron typing "won't play" produces "won’t play" — which
///    matched neither the ASCII-apostrophe keyword ("won't play") nor the
///    apostrophe-free variant ("wont play"). Every apostrophe-bearing keyword —
///    the highest-signal phrases in the corpus — was unreachable from a stock
///    iPhone. We fold the curly single-quote variants to a plain apostrophe.
///  - **Hyphen variants.** En/em dashes and the non-breaking hyphen collapse to
///    a plain '-' so "grayed‑out" (U+2011) matches "grayed-out".
///
/// Pure, deterministic, no allocation beyond the folded string. Applied to both
/// sides of every comparison so the two spaces always agree.
public enum TextNormalizer {

    private static let apostropheVariants: [Character] = ["\u{2019}", "\u{2018}", "\u{02BC}"]
    private static let hyphenVariants: [Character] = [
        "\u{2010}", "\u{2011}", "\u{2012}", "\u{2013}", "\u{2014}", "\u{2212}"
    ]

    public static func normalize(_ text: String) -> String {
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
