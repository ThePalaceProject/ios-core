import XCTest
@testable import TriageBotCore

/// Filler substitution means two keywords that differ only in a determiner are
/// the SAME keyword to the matcher. When they belong to different entries, the
/// classifier sees a tie it cannot break and asks a disambiguating question
/// instead of answering — reach lost, silently, with no gate to notice.
///
/// A per-keyword audit structurally cannot see this: each keyword is fine on its
/// own, and the collision only exists between two entries. Raised by SoD review
/// on the shipped catalog — `add a card` (KI-2026-009) canonicalizes to the same
/// form as `add my card` (HT-2026-008), which turned "How do I add my card?"
/// under the `library` chip from an answer into a question.
final class KeywordCanonicalCollisionTests: XCTestCase {

    /// A keyword's identity under filler substitution: content tokens in order,
    /// with every filler replaced by a single wildcard marker. Two keywords with
    /// the same canonical form match exactly the same patron text.
    ///
    /// Mirrors `TextTokenizer`'s rule, including the thin-keyword guard — a
    /// keyword with fewer than two content tokens gets no variation, so it can
    /// only collide with a byte-identical twin and is canonicalized as itself.
    private func canonical(_ keyword: String) -> String {
        let tokens = TextTokenizer.tokens(TextNormalizer.normalize(keyword))
        guard tokens.filter({ !TextTokenizer.fillerTokens.contains($0) }).count >= 2 else {
            return tokens.joined(separator: " ")
        }
        return tokens.map { TextTokenizer.fillerTokens.contains($0) ? "*" : $0 }
            .joined(separator: " ")
    }

    func testNoTwoEntriesShareAKeywordUnderFillerSubstitution() throws {
        let entries = try BundledCatalogSource.loadCatalogSync().entries

        // canonical form -> the entries claiming it
        var owners: [String: Set<String>] = [:]
        for entry in entries {
            let keywords = entry.symptomKeywords + (entry.corroboratingKeywords ?? [])
            for keyword in keywords {
                owners[canonical(keyword), default: []].insert(entry.id)
            }
        }

        let collisions = owners
            .filter { $0.value.count > 1 }
            .map { "  \"\($0.key)\" claimed by \($0.value.sorted().joined(separator: " + "))" }
            .sorted()

        XCTAssertTrue(
            collisions.isEmpty,
            """
            Keywords from different entries collapse to the same form under filler \
            substitution, so the classifier cannot tell them apart and will \
            disambiguate instead of answering:
            \(collisions.joined(separator: "\n"))
            Fix by making one of them more specific, not by widening the other.
            """
        )
    }

    /// The lint above is only meaningful if `canonical` actually merges anything
    /// — a bug that made it the identity function would report a permanently
    /// clean catalog. Pins that it collapses determiners and respects the
    /// thin-keyword guard.
    func testCanonicalFormActuallyMergesDetermimerVariants() {
        XCTAssertEqual(canonical("return the book"), canonical("return my book"))
        XCTAssertNotEqual(canonical("return the book"), canonical("return the loan"))
        // Thin keyword: no variation, so it canonicalizes to itself and its
        // trailing filler is NOT wildcarded.
        XCTAssertEqual(canonical("notification that"), "notification that")
    }
}
