import XCTest
@testable import TriageBotCore

/// Two axes the shipped `MatchCorpus` does not cover, because every case there
/// carries exactly one text and one category:
///
///  1. **Paraphrase** — a patron does not type the catalog's keyword. Several
///     phrasings per intent show whether an answer rests on one lucky wording.
///  2. **Chip** — the patron picks the topic themselves, and reasonable people
///     pick differently for the same question ("where do I enter my card" is a
///     Sign in question to one patron and a Library question to another).
///
/// The corpus below is AUTHORED, not mined, and is deliberately not used to
/// claim generalization — its phrasings were written with the catalog in view,
/// so a high answer rate here is not evidence the bot handles unseen tickets.
/// What it is valid for is the axis it varies: holding the intent fixed and
/// changing only the wording or the chip, does the outcome change? That is a
/// property of the classifier, not of the sample, and it is what these gates
/// assert. The answer RATE is printed, never asserted, for the same reason the
/// held-out slice in `MatchCorpusTests` is reported and not gated.
final class ParaphraseChipRobustnessTests: XCTestCase {

    struct Intent {
        let name: String
        let expected: String
        let isHowTo: Bool
        /// Chips a real patron might plausibly pick for this intent.
        let chips: [KBCategory]
        let phrasings: [String]
    }

    enum Outcome: Equatable {
        case answered
        case misrouted(String)
        case asked
        case scoped
        case blind
    }

    static let intents: [Intent] = [
        Intent(name: "renew", expected: "HT-2026-001-renewals", isHowTo: true,
               chips: [.other, .library], phrasings: [
            "How do I renew my loan?",
            "Can I renew this book?",
            "How many times can an ebook be renewed if there are no holds on it?",
            "I want to keep this book longer, how do I extend it?",
            "Is there a way to extend my checkout?",
            "My book is due tomorrow, can I get more time?",
        ]),
        Intent(name: "return-early", expected: "HT-2026-002-return-early", isHowTo: true,
               chips: [.other, .library], phrasings: [
            "How do I return a book early?",
            "I finished my book, how do I give it back?",
            "Can I return this before the due date?",
            "How do I return a book I'm done with?",
            "I want to send this back early",
        ]),
        Intent(name: "add-card", expected: "HT-2026-008-add-library-card", isHowTo: true,
               chips: [.signin, .library], phrasings: [
            "Where do I enter my library card?",
            "How do I add my library card?",
            "Where do I put in my barcode?",
            "How do I sign in with my card?",
            "I need to register my card",
        ]),
        Intent(name: "kindle", expected: "HT-2026-009-formats-kindle", isHowTo: true,
               chips: [.other, .reader], phrasings: [
            "Can I read these on my Kindle?",
            "Can I send this to Kindle?",
            "What formats does Palace use?",
            "Does this work with my e-reader?",
        ]),
        Intent(name: "switch-library", expected: "HT-2026-003-switch-library", isHowTo: true,
               chips: [.library, .other], phrasings: [
            "How do I switch between libraries?",
            "How do I change libraries?",
            "I want to go back to my other library",
        ]),
        Intent(name: "hold-pickup", expected: "HT-2026-005-hold-pickup-window", isHowTo: true,
               chips: [.other, .library], phrasings: [
            "How long do I have to pick up my hold?",
            "How long is my hold available?",
            "When do I lose my hold?",
        ]),
        Intent(name: "notifications", expected: "HT-2026-004-notifications", isHowTo: true,
               chips: [.other, .library], phrasings: [
            "Does Palace remind me when a book is due?",
            "Can I get notified when my hold is ready?",
            "How do I turn on notifications?",
        ]),
        Intent(name: "borrow-limit", expected: "HT-2026-006-borrow-limit", isHowTo: true,
               chips: [.other, .library], phrasings: [
            "How many books can I borrow at once?",
            "What's the checkout limit?",
        ]),
        Intent(name: "loan-length", expected: "HT-2026-007-loan-length", isHowTo: true,
               chips: [.other], phrasings: [
            "How long is a loan?",
            "When is my book due?",
            "How long can I keep it?",
        ]),
        Intent(name: "audiobook-hang", expected: "KI-2026-001-audiobook-first-open-hang", isHowTo: false,
               chips: [.audiobook], phrasings: [
            "My audiobook won't play. I tap play and nothing happens.",
            "The audiobook won't load at all",
            "I press the play button and it just blinks",
            "Audiobook sits there and never starts",
            "My audiobook stops playing partway through",
            "The audiobook just keeps spinning the first time I open it",
        ]),
        Intent(name: "download-stuck", expected: "KI-2026-008-download-no-network", isHowTo: false,
               chips: [.download], phrasings: [
            "I've been trying to download this book for two days and it's stuck at no progress",
            "The download is stuck",
            "My book won't download",
            "Download failed again",
            "The download hasn't moved in an hour",
        ]),
        Intent(name: "signin-greyed", expected: "KI-2026-003-signin-placeholder-contrast", isHowTo: false,
               chips: [.signin], phrasings: [
            "The sign-in fields are greyed out and I can't type my card number",
            "The login boxes look disabled",
            "I can't type anything into the sign in screen",
            "I was never prompted to sign in",
        ]),
    ]

    private func outcome(_ text: String, _ chip: KBCategory, _ expected: String, _ kb: KnowledgeBase) -> Outcome {
        let r = LocalClassifier().classify(userText: text, category: chip, context: nil, knowledgeBase: kb)
        switch r.decision {
        case .suggest(let id):  return id == expected ? .answered : .misrouted(id)
        case .disambiguate:     return .asked
        case .escalate:         return r.recognizedEntryId == nil ? .blind : .scoped
        }
    }

    /// A patron who picks a different — but equally reasonable — topic chip must
    /// not lose an answer the catalog holds.
    ///
    /// Stated as "never BLIND where another chip answers" rather than as strict
    /// equality across chips, because the chip legitimately carries information
    /// for KNOWN ISSUES: under `library`, "can I get notified when my hold is
    /// ready?" genuinely competes with the hold-desync known issue, and asking
    /// which one the patron means is a correct outcome. Going BLIND is not — that
    /// is the answer existing and being unreachable, which is the defect this
    /// gate exists to catch.
    func testAnswerableIntent_IsNeverBlind_OnAnotherPlausibleChip() throws {
        let kb = KnowledgeBase(catalog: try BundledCatalogSource.loadCatalogSync())

        for intent in Self.intents where intent.chips.count > 1 {
            for phrasing in intent.phrasings {
                let results = intent.chips.map {
                    ($0, outcome(phrasing, $0, intent.expected, kb))
                }
                // Only compares chips against each other. A phrasing that is
                // blind on EVERY chip is not a chip-sensitivity failure and is
                // covered by the per-intent floor below instead.
                guard results.contains(where: { $0.1 == .answered }) else { continue }
                for (chip, result) in results where result == .blind {
                    XCTFail(
                        """
                        "\(phrasing)" is answered on one chip but BLIND on \(chip). \
                        The catalog holds \(intent.expected); the patron cannot reach it.
                        """
                    )
                }
            }
        }
    }

    /// The floor that stops the chip-invariance test above from weakening
    /// itself. That test compares chips against each other, so a phrasing that
    /// regresses to BLIND on every chip satisfies it vacuously — the worst
    /// outcome would have been the quietest. Raised by SoD review.
    ///
    /// Asserted per intent rather than per phrasing: a single phrasing may
    /// legitimately be beyond the catalog's wording (several are, and they are
    /// listed as known gaps), but an INTENT the catalog answers must stay
    /// reachable by at least one of the phrasings a patron might use.
    func testEveryIntent_RemainsReachable_ByAtLeastOnePhrasing() throws {
        let kb = KnowledgeBase(catalog: try BundledCatalogSource.loadCatalogSync())

        for intent in Self.intents {
            let answered = intent.phrasings.contains { phrasing in
                intent.chips.contains { chip in
                    outcome(phrasing, chip, intent.expected, kb) == .answered
                }
            }
            XCTAssertTrue(
                answered,
                """
                No phrasing of "\(intent.name)" reaches \(intent.expected) on any chip. \
                The catalog holds the answer and no patron wording in this corpus finds it.
                """
            )
        }
    }

    /// The safety property, on the paraphrase axis this time: no phrasing of a
    /// question may be handed a DIFFERENT entry's answer. This is the gate that
    /// caught the shipped misroute — "can I get notified when my hold is ready?"
    /// under `library` was confidently answered with the hold-desync workaround,
    /// which no case in `MatchCorpus` exercised.
    func testNoPhrasing_IsHandedTheWrongEntrysAnswer() throws {
        let kb = KnowledgeBase(catalog: try BundledCatalogSource.loadCatalogSync())

        for intent in Self.intents {
            for phrasing in intent.phrasings {
                for chip in intent.chips {
                    if case .misrouted(let got) = outcome(phrasing, chip, intent.expected, kb) {
                        XCTFail("""
                            "\(phrasing)" [\(chip)] was answered with \(got), \
                            but the intent is \(intent.name) (\(intent.expected)).
                            """)
                    }
                }
            }
        }
    }

    /// Per-intent floors, pinned at the values measured when this landed.
    ///
    /// The reachability floor above only asserts ≥1 cell per intent, which is
    /// loose for the four single-chip intents the chip-invariance test skips
    /// entirely — `audiobook-hang` could fall 6/6 → 1/6 with nothing failing.
    /// Raised by SoD review, and the objection that stopped me gating the rate
    /// does not apply here: an authored corpus cannot support a QUALITY claim
    /// ("the bot answers 70% of real patrons"), but it can support a
    /// DON'T-REGRESS claim ("this wording answered yesterday and must today").
    ///
    /// Raise a floor when reach improves; never lower one to make a build pass.
    func testPerIntentReach_DoesNotRegress() throws {
        let floors: [String: Int] = [
            "renew": 6, "return-early": 4, "add-card": 8, "kindle": 4,
            "switch-library": 6, "hold-pickup": 6, "notifications": 5,
            "borrow-limit": 4, "loan-length": 1, "audiobook-hang": 5,
            "download-stuck": 4, "signin-greyed": 3,
        ]
        let kb = KnowledgeBase(catalog: try BundledCatalogSource.loadCatalogSync())

        // Every intent must have a floor, or a new intent silently escapes.
        XCTAssertEqual(
            Set(floors.keys), Set(Self.intents.map(\.name)),
            "intent list and floor table disagree — add the new intent's floor"
        )

        for intent in Self.intents {
            let answered = intent.phrasings.reduce(0) { total, phrasing in
                total + intent.chips.filter {
                    outcome(phrasing, $0, intent.expected, kb) == .answered
                }.count
            }
            let floor = floors[intent.name] ?? 0
            XCTAssertGreaterThanOrEqual(
                answered, floor,
                "\(intent.name) reach regressed: \(answered) < \(floor) cells"
            )
        }
    }

    /// Reported, never asserted — see the type comment. Printed so a regression
    /// in reach shows up in the log even though it cannot fail the build.
    func testReportAnswerRate() throws {
        let kb = KnowledgeBase(catalog: try BundledCatalogSource.loadCatalogSync())
        var cells = 0, answered = 0

        print("=== PARAPHRASE × CHIP (reported, not gated) ===")
        for intent in Self.intents {
            var iCells = 0, iAnswered = 0
            for phrasing in intent.phrasings {
                for chip in intent.chips {
                    iCells += 1
                    if outcome(phrasing, chip, intent.expected, kb) == .answered { iAnswered += 1 }
                }
            }
            cells += iCells; answered += iAnswered
            print(String(format: "  %-16s %d/%d", (intent.name as NSString).utf8String!, iAnswered, iCells))
        }
        print("  TOTAL \(answered)/\(cells)")

        // The rate is deliberately NOT asserted (see the type comment). The
        // COVERAGE is, because otherwise this reporter could quietly measure
        // nothing — a corpus that stopped evaluating would print 0/0 and read
        // as healthy. Flagged as MISSING-001 by `lint-test-quality.py`, which
        // was right: a test with no assertion cannot fail.
        let expectedCells = Self.intents.reduce(0) { $0 + $1.phrasings.count * $1.chips.count }
        XCTAssertEqual(cells, expectedCells, "the corpus did not evaluate every phrasing x chip cell")
        XCTAssertFalse(Self.intents.isEmpty, "empty corpus reports a perfect score")
    }
}
