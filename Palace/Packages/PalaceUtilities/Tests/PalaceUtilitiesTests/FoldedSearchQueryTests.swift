//
//  FoldedSearchQueryTests.swift
//  PalaceUtilitiesTests
//

import XCTest
@testable import PalaceUtilities

/// Pins the matching a patron gets when they type into a search field that
/// filters text we already hold.
///
/// The characters a patron types are not the characters that arrive: the iOS
/// keyboard substitutes a curly apostrophe for a straight one as they type.
/// Measured on iOS 26.1 — typing `Alice's` lands `Alice\u{2019}s` in any field
/// that has not disabled the trait. The titles being filtered carry whichever
/// form the catalogue happens to use, so one side is routinely typographic and
/// the other routinely ASCII.
final class FoldedSearchQueryTests: XCTestCase {

    // MARK: - The defect this exists to close

    /// The predicate both search filters used before this type. Kept as a test
    /// so the reason for the change cannot quietly stop being true: if this
    /// ever starts passing, Foundation began folding punctuation and the
    /// FoldedSearchQuery indirection can go.
    func testLocalizedCaseInsensitiveContains_missesTheApostropheTheKeyboardTypes() {
        let title = "Alice's Adventures in Wonderland"
        let whatTheKeyboardProduces = "Alice\u{2019}s"

        XCTAssertFalse(
            title.localizedCaseInsensitiveContains(whatTheKeyboardProduces),
            "Foundation compares apostrophe variants as distinct characters — this is the miss that made a correctly typed title return nothing"
        )
    }

    // MARK: - Folding across the apostrophe variants

    func testCurlyQuery_matchesStraightTitle() {
        let query = FoldedSearchQuery("Alice\u{2019}s")

        XCTAssertTrue(
            query.matches("Alice's Adventures in Wonderland"),
            "a patron typing on the stock keyboard gets U+2019; a catalogue title with an ASCII apostrophe must still match"
        )
    }

    func testStraightQuery_matchesCurlyTitle() {
        let query = FoldedSearchQuery("Alice's")

        XCTAssertTrue(
            query.matches("Alice\u{2019}s Adventures in Wonderland"),
            "the reverse pairing must hold too — published titles are often typographic while the query arrives as ASCII (pasted, or from a keyboard with smart punctuation off)"
        )
    }

    func testLeftSingleQuoteAndModifierLetterApostrophe_alsoFold() {
        XCTAssertTrue(
            FoldedSearchQuery("Alice\u{2018}s").matches("Alice's Adventures"),
            "U+2018 appears in titles typeset with the opening quote in the possessive position"
        )
        XCTAssertTrue(
            FoldedSearchQuery("Hawai\u{02BC}i").matches("Hawai'i"),
            "U+02BC is the correct okina and appears in real catalogue records"
        )
    }

    // MARK: - Folding across the hyphen variants

    func testHyphenVariants_fold() {
        XCTAssertTrue(
            FoldedSearchQuery("grayed\u{2011}out").matches("grayed-out"),
            "a non-breaking hyphen in a title must not hide it from a query typed with an ASCII hyphen"
        )
        XCTAssertTrue(
            FoldedSearchQuery("1920-1930").matches("1920\u{2013}1930"),
            "an en dash in a date range is the common typographic case"
        )
    }

    // MARK: - Case

    func testMatchingIsCaseInsensitive() {
        XCTAssertTrue(FoldedSearchQuery("alice").matches("ALICE'S ADVENTURES"))
        XCTAssertTrue(FoldedSearchQuery("ALICE").matches("alice's adventures"))
    }

    // MARK: - The predicate must still be able to say no

    /// Without this the whole suite above is satisfiable by `return true`.
    func testUnrelatedQuery_doesNotMatch() {
        XCTAssertFalse(
            FoldedSearchQuery("Bob").matches("Alice's Adventures in Wonderland"),
            "folding must not widen matching to unrelated text"
        )
    }

    func testApostropheFoldingDoesNotCollapseDistinctWords() {
        XCTAssertFalse(
            FoldedSearchQuery("were").matches("we're"),
            "folding normalises the apostrophe's SHAPE, it must not delete it — otherwise `were` would match `we're`"
        )
    }

    // MARK: - Optional and empty inputs, since the call sites pass both

    func testNilCandidate_doesNotMatch() {
        XCTAssertFalse(
            FoldedSearchQuery("Alice").matches(nil),
            "authors is optional on a book; a missing value must read as no match rather than trapping"
        )
    }

    func testEmptyQuery_isReportedEmptyAndMatchesEverything() {
        let query = FoldedSearchQuery("   ")

        XCTAssertTrue(
            query.isEmpty,
            "a whitespace-only query is empty for search purposes; both call sites branch on this to restore the unfiltered list"
        )
        XCTAssertTrue(
            query.matches("anything"),
            "an empty query is a substring of everything — stated so the call sites' empty guard is a deliberate choice and not a silent dependency on this"
        )
    }

    func testQueryIsTrimmedBeforeMatching() {
        XCTAssertTrue(
            FoldedSearchQuery("  Alice  ").matches("Alice's Adventures"),
            "a trailing space from predictive insertion must not stop the match"
        )
    }

    // MARK: - Deliberately NOT folded

    /// Diacritics are left alone. Folding them would make `cafe` match
    /// `Café`, which is probably wanted, but it also changes matching for
    /// every non-English title in the catalogue and is a separate decision
    /// from the punctuation substitution a keyboard performs. Pinned so the
    /// boundary is explicit rather than an accident.
    func testDiacriticsAreNotFolded() {
        XCTAssertFalse(
            FoldedSearchQuery("cafe").matches("Café Stories"),
            "diacritic folding is out of scope here; this test records that, it does not endorse it"
        )
    }
}
