import XCTest
@testable import TriageBotCore

/// A how-to question is not a symptom, so the topic chip carries no information
/// about which how-to answers it.
///
/// `KBCategory` was designed for known issues, where the chip IS evidence: a
/// patron reporting an audiobook that won't play picks "Audiobook", and scoping
/// candidates to that category is what keeps a PDF workaround from reaching
/// them. How-to entries are the opposite — "how do I renew my loan?" is not a
/// Library problem or an Other problem, and the category the catalog happens to
/// assign them (renewals→other, switch-library→library) is filing metadata, not
/// a property of the question.
///
/// Scoping them anyway made the shipped catalog's answer reachable from exactly
/// one of six chips. Measured across a paraphrase corpus before this change,
/// how-to intents answered 22/65 phrasing×chip cells, and nearly every failure
/// on a plausible-but-different chip was a BLIND escalation — the answer existed
/// and the patron could not reach it (PP-4865 follow-up).
///
/// Worse, the absence was not neutral: with the right how-to excluded from the
/// candidate set, a known-issue entry could win the category by default. That is
/// the `notifications` case below, which was a real MISROUTE, not just a miss.
final class HowToCategoryAgnosticTests: XCTestCase {

    private func kb() throws -> KnowledgeBase {
        KnowledgeBase(catalog: try BundledCatalogSource.loadCatalogSync())
    }

    private func decision(_ text: String, _ category: KBCategory) throws -> ClassificationResult.Decision {
        LocalClassifier().classify(
            userText: text,
            category: category,
            context: nil,
            knowledgeBase: try kb()
        ).decision
    }

    // MARK: - The fix

    /// The matched pair driven on the simulator: the same sentence answered
    /// correctly under "Other" and produced the generic library ladder ("check
    /// which library is selected… are your books there?") under "Library".
    func testRenewalQuestion_IsAnswered_FromEveryPlausibleChip() throws {
        for category in [KBCategory.other, .library, .reader] {
            XCTAssertEqual(
                try decision("How do I renew my loan?", category),
                .suggest(entryId: "HT-2026-001-renewals"),
                "a renewal answer must not depend on which topic chip the patron guessed (chip: \(category))"
            )
        }
    }

    /// HT-008 is filed under `library`, but "where do I enter my card" is a
    /// sign-in question to anyone typing it.
    func testAddCardQuestion_IsAnswered_UnderSignIn() throws {
        XCTAssertEqual(
            try decision("Where do I enter my library card?", .signin),
            .suggest(entryId: "HT-2026-008-add-library-card")
        )
    }

    /// The misroute this fix closes. Under `library` the notifications how-to was
    /// not a candidate at all, so the hold-desync KNOWN ISSUE won unopposed and a
    /// patron asking a question was shown a bug workaround. Asserted as
    /// "not that entry" rather than "is the how-to": either answering the
    /// question or asking which of the two they mean is acceptable; confidently
    /// handing over the desync workaround is not.
    func testNotificationQuestion_UnderLibrary_IsNotHandedTheHoldDesyncWorkaround() throws {
        let result = try decision("Can I get notified when my hold is ready?", .library)
        // Asserted positively. An `if case .suggest` guard would pass vacuously
        // on escalate/disambiguate, so it could not tell "we fixed the misroute"
        // apart from "the classifier stopped answering at all".
        switch result {
        case .suggest(let id):
            XCTAssertEqual(id, "HT-2026-004-notifications", "answered with the wrong entry")
        case .disambiguate(let candidates):
            XCTAssertTrue(
                candidates.contains("HT-2026-004-notifications"),
                "asking is acceptable, but the how-to must be one of the options"
            )
        case .escalate:
            XCTFail("the catalog answers this; escalating is a reach regression")
        }
    }

    // MARK: - The guard (this must hold BEFORE and AFTER the change)

    /// Known issues stay category-scoped. This is the half of the category model
    /// that is load-bearing, and the reason the fix is "how-tos are agnostic"
    /// rather than "fall back across all categories when nothing matches":
    /// "won't open" is a decisive phrase for the LCP PDF entry, so a blanket
    /// fallback would hand a PDF workaround to an audiobook patron.
    func testKnownIssue_DoesNotLeakAcrossCategories() throws {
        // Positive assertion: this text has no audiobook entry to match, so the
        // ONLY correct outcome is a non-suggestion. Written as "must not suggest
        // anything" rather than "must not suggest KI-007", which would still
        // pass if it started suggesting some other unrelated entry.
        let result = try decision("It won't open, I just get a blank screen", .audiobook)
        if case .suggest(let id) = result {
            XCTFail("no audiobook entry describes this, yet it suggested \(id)")
        }
    }

    /// The symmetric guard: a decisive AUDIOBOOK phrase must not reach someone
    /// who said they have a downloading problem.
    func testKnownIssue_AudiobookPhrase_DoesNotReachDownloadCategory() throws {
        let result = try decision("I tap play and nothing happens", .download)
        if case .suggest(let id) = result {
            XCTFail("an audiobook phrase reached the download chip as \(id)")
        }
    }

    /// Making how-tos ubiquitous must not let them outrank a real symptom in
    /// their own category — a patron describing a broken audiobook still gets
    /// the known issue, not a formats FAQ.
    func testKnownIssue_StillWins_AgainstNowUbiquitousHowTos() throws {
        XCTAssertEqual(
            try decision("My audiobook won't play. I tap play and nothing happens.", .audiobook),
            .suggest(entryId: "KI-2026-001-audiobook-first-open-hang")
        )
    }
}
