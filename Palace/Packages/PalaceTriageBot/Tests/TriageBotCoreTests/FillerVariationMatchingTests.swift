import XCTest
@testable import TriageBotCore

/// Determiners and possessives vary freely between patrons describing the same
/// thing, and the matcher required a CONTIGUOUS token run, so every variation
/// was a miss the catalog had to enumerate by hand. That is why the shipped
/// renewals entry lists "renew my loan", "renew the loan", "renew a book" and
/// "renew my book" as four separate keywords — four spellings of one concept,
/// and still not the one a patron typed.
///
/// Only ONE variation is admitted, and two are refused. The refusals are the
/// load-bearing part — both were implemented and measured before being cut.
///
///  - **Substitution (ADMITTED)** — the patron swaps one filler for another.
///    "keep this book longer" matches `keep the book longer`. The run stays
///    contiguous and equal-length; only a filler's identity varies, so a
///    keyword covers no more text than it did before.
///  - **Insertion (REFUSED)** — skipping a text filler the keyword lacks, so
///    `on kindle` would match "on my kindle". Measured: it bought four
///    paraphrase cells and cost a real misroute — "the app switched my library
///    on its own and lost my place" matched KI-002's `switched library` and was
///    handed an LCP playback workaround for a reading-position complaint. The
///    rejection corpus caught it; see `testInsertionIsRefused`.
///  - **Elision (REFUSED)** — a filler in the KEYWORD matching nothing at all.
///    An audit of all 257 shipped keywords found this collapses the STRONG
///    keywords "notification that" and "notifications that" (KI-006 hold-ready
///    desync) to the bare words, so any patron who used the word would strongly
///    match a known issue. That is chaos-qa F-002 rebuilt from scratch.
final class FillerVariationMatchingTests: XCTestCase {

    private func kb() throws -> KnowledgeBase {
        KnowledgeBase(catalog: try BundledCatalogSource.loadCatalogSync())
    }

    private func tokens(_ s: String) -> [String] {
        TextTokenizer.tokens(TextNormalizer.normalize(s))
    }

    private func matches(_ keyword: String, in text: String) -> Bool {
        !TextTokenizer.matchRanges(
            of: tokens(keyword), in: tokens(text), allowingFillerVariation: true
        ).isEmpty
    }

    // MARK: - Admitted variation

    func testSubstitution_PatronSwapsOneFillerForAnother() {
        XCTAssertTrue(matches("keep the book longer", in: "i want to keep this book longer"))
        XCTAssertTrue(matches("return the book", in: "how do i return my book"))
    }

    // MARK: - The refusals

    /// Insertion stays out. This is not a "not yet" — it was implemented,
    /// measured against the rejection corpus, and cut for the misroute quoted in
    /// the type comment. A future attempt must re-run that corpus, not just this
    /// assertion.
    func testInsertionIsRefused() {
        XCTAssertFalse(
            matches("on kindle", in: "can i read these on my kindle"),
            "insertion widens what a keyword covers; it cost a real misroute when measured"
        )
        XCTAssertFalse(
            matches("switched library", in: "the app switched my library on its own"),
            "the exact rejection-corpus input that ruled insertion out"
        )
    }


    /// The exact pair the keyword audit flagged. If a keyword's filler could
    /// match nothing, these become the bare word.
    func testElision_IsRefused_SoAStrongKeywordCannotCollapseToOneWord() {
        XCTAssertFalse(
            matches("notification that", in: "i got a notification"),
            "'notification that' must not match a bare 'notification' — that hands the "
                + "hold-desync workaround to anyone who says the word"
        )
        XCTAssertFalse(matches("notifications that", in: "i turned on notifications"))
    }

    /// End-to-end version of the same guard, through the real classifier and
    /// catalog: mentioning notifications must not produce the desync workaround.
    func testMentioningNotifications_IsNotHandedTheHoldDesyncWorkaround() throws {
        let r = LocalClassifier().classify(
            userText: "How do I turn on notifications?",
            category: .library, context: nil, knowledgeBase: try kb()
        )
        if case .suggest(let id) = r.decision {
            XCTAssertNotEqual(id, "KI-2026-006-hold-ready-desync")
        }
    }

    /// A filler may not bridge two CONTENT words. The run stays contiguous and
    /// equal-length, so any non-filler token between keyword tokens breaks it.
    func testContentWordsBetweenKeywordTokens_StillBreakTheMatch() {
        XCTAssertFalse(matches("won't play", in: "won't download or play"))
        XCTAssertFalse(matches("tap play", in: "tap the big green download play"))
    }

    /// Strictness is preserved for callers that did not opt in — RemedyDetector
    /// matches destructive-action phrases and keeps the exact-run rule.
    func testStrictModeIsUnchanged_ByDefault() {
        XCTAssertTrue(
            TextTokenizer.matchRanges(of: tokens("on kindle"), in: tokens("read on my kindle")).isEmpty,
            "the default (strict) path must not have loosened"
        )
    }
}
