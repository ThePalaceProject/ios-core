import XCTest
@testable import TriageBotCore

/// Scores the local matcher against a corpus of real patron phrasings
/// (`Fixtures/MatchCorpus.json`) so recall and misrouting are numbers we can
/// regress against rather than impressions.
///
/// Two rates, and they trade against each other — a change that only moves one
/// has not been evaluated:
///
///  - **capture** — of the cases where the catalog genuinely has the answer, how
///    many did the bot surface? Every uncaptured case is a patron who gets
///    "I haven't seen exactly that before" for an issue we have a documented fix
///    for, and who never reaches the guided troubleshooting steps (those live
///    only on `known_issue` entries).
///  - **misroute** — how many cases were handed the WRONG entry's workaround?
///    This is worse than escalating: it tells a patron to fix a bug they don't
///    have. The `trap` slice exists to hold this at zero.
///
/// Read the `held_out` slice as the honest generalization number; see the
/// fixture's `_readme` for why `mined` is an upper bound.
///
/// Complements `HoldoutGeneralizationTests` rather than replacing it. That suite
/// classifies with NO category, so every entry in the catalog competes — the
/// harshest precision test available, and it pins its exact miss / false-suggest
/// sets. This one classifies WITH the category the patron tapped, which is the
/// path the UI actually drives, and adds the `trap` slice plus per-slice capture
/// reporting. Keep both: the no-category suite guards precision under maximum
/// competition, this one measures what a real session does. A change that moves
/// either number should be explained against both.
final class MatchCorpusTests: XCTestCase {

    // MARK: - Fixture

    private struct Corpus: Decodable {
        struct Case: Decodable {
            let id: String
            let provenance: String
            let category: String
            let text: String
            let expected: String
            let alsoAcceptable: [String]?

            enum CodingKeys: String, CodingKey {
                case id, provenance, category, text, expected
                case alsoAcceptable = "also_acceptable"
            }

            var expectsEscalation: Bool { expected == "escalate" }

            /// Entry ids that count as a correct suggestion for this case.
            var acceptableEntryIds: Set<String> {
                var ids = Set(alsoAcceptable ?? [])
                if !expectsEscalation { ids.insert(expected) }
                return ids
            }
        }
        let cases: [Case]
    }

    /// Three outcomes, not two — because with the AI fallback off, "we could not
    /// self-serve this" is not the end of the bot's usefulness. An escalation that
    /// carries `recognizedEntryId` hands support a SCOPED ticket and asks the
    /// entry's targeted follow-up ("which title?", "which library?") before filing.
    /// A blind escalation hands them "patron reports a problem".
    ///
    /// So the goal is layered: capture what we can, and for everything we cannot,
    /// prefer a triaged escalation over a blind one. Misrouting stays the only
    /// truly bad outcome — it is the one where the patron acts on wrong advice.
    private enum Outcome {
        case captured(String)       // suggested an acceptable entry — patron self-serves
        case misrouted(String)      // suggested an entry that is not acceptable
        case triaged(String)        // escalated, but recognized the topic → scoped ticket
        case blindEscalated         // escalated with no recognition → generic ticket
        case disambiguated
    }

    private struct Tally {
        var capturable = 0          // cases where an entry is the right answer
        var captured = 0
        var misrouted = 0
        var triaged = 0
        var blind = 0
        var total = 0
    }

    private func loadCorpus() throws -> Corpus {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "Fixtures/MatchCorpus", withExtension: "json")
                ?? Bundle.module.url(forResource: "MatchCorpus", withExtension: "json"),
            "MatchCorpus.json missing from the test bundle"
        )
        return try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url))
    }

    private func outcome(for testCase: Corpus.Case, kb: KnowledgeBase) throws -> Outcome {
        let category = try XCTUnwrap(
            KBCategory(rawValue: testCase.category),
            "unknown category '\(testCase.category)' in case \(testCase.id)"
        )
        let result = LocalClassifier().classify(
            userText: testCase.text,
            category: category,
            context: nil,
            knowledgeBase: kb
        )
        switch result.decision {
        case .suggest(let entryId):
            return testCase.acceptableEntryIds.contains(entryId)
                ? .captured(entryId)
                : .misrouted(entryId)
        case .escalate:
            // recognizedEntryId is what turns a dead-end into a scoped hand-off.
            if let recognized = result.recognizedEntryId { return .triaged(recognized) }
            return .blindEscalated
        case .disambiguate:
            return .disambiguated
        }
    }

    // MARK: - The scored run

    func testCorpus_captureAndMisrouteRates() throws {
        let kb = KnowledgeBase(catalog: try BundledCatalogSource.loadCatalogSync())
        let corpus = try loadCorpus()

        var bySlice: [String: Tally] = [:]
        var report: [String] = []

        for testCase in corpus.cases {
            let result = try outcome(for: testCase, kb: kb)
            var tally = bySlice[testCase.provenance] ?? Tally()
            tally.total += 1
            if !testCase.expectsEscalation { tally.capturable += 1 }

            let line: String
            switch result {
            case .captured(let id):
                tally.captured += 1
                line = "  ✓ captured    \(testCase.id) -> \(id)"
            case .misrouted(let id):
                tally.misrouted += 1
                line = "  ✗ MISROUTED   \(testCase.id) -> \(id) (expected \(testCase.expected))"
            case .triaged(let id):
                tally.triaged += 1
                line = testCase.expectsEscalation
                    ? "  ✓ triaged     \(testCase.id) (scoped to \(id))"
                    : "  ~ triaged     \(testCase.id) (no answer shown, but ticket scoped to \(id))"
            case .blindEscalated:
                tally.blind += 1
                line = testCase.expectsEscalation
                    ? "  ✓ escalated   \(testCase.id)"
                    : "  – MISSED      \(testCase.id) (expected \(testCase.expected); ticket unscoped)"
            case .disambiguated:
                line = "  ? ambiguous   \(testCase.id) (expected \(testCase.expected))"
            }
            report.append(line)
            bySlice[testCase.provenance] = tally
        }

        // Emit the full picture before asserting, so a failing run explains itself.
        print("=== MATCH CORPUS ===")
        for slice in ["mined", "held_out", "trap", "near_miss"] {
            guard let tally = bySlice[slice] else { continue }
            let pct = tally.capturable == 0 ? "n/a"
                : String(format: "%.0f%%", 100.0 * Double(tally.captured) / Double(tally.capturable))
            // "handled" = the patron got either an answer or a scoped hand-off.
            // With the AI fallback off this is the number that describes what the
            // bot is actually worth today; capture alone undersells it.
            let handled = tally.captured + tally.triaged
            let handledPct = tally.total == 0 ? "n/a"
                : String(format: "%.0f%%", 100.0 * Double(handled) / Double(tally.total))
            print("\n[\(slice)] cases=\(tally.total) capturable=\(tally.capturable) "
                  + "captured=\(tally.captured) (\(pct)) misrouted=\(tally.misrouted)")
            print("         triaged=\(tally.triaged) blind=\(tally.blind) "
                  + "→ handled (answered or scoped) = \(handled)/\(tally.total) (\(handledPct))")
        }
        print("\n--- per case ---")
        report.forEach { print($0) }

        // A misroute hands a patron the wrong bug's workaround. The trap slice is
        // built entirely from inputs whose only overlap with an entry is a weak,
        // non-diagnostic word, so any suggestion here is a defect — this is the
        // guard that stops "improve recall" from silently reintroducing F-002.
        // near_miss is the slice that can actually fail: real tickets carrying a
        // strong keyword whose true cause is elsewhere. The trap slice cannot
        // catch a mis-partitioned strong keyword, because it is sampled from the
        // weak side by construction.
        let nearMiss = bySlice["near_miss"] ?? Tally()
        XCTAssertEqual(
            nearMiss.misrouted, 0,
            "a real patron would be shown a workaround for a bug they do not have — see MISROUTED lines"
        )

        let trap = bySlice["trap"] ?? Tally()
        XCTAssertEqual(
            trap.misrouted, 0,
            "generic complaints were handed a specific entry's workaround — see MISROUTED lines above"
        )

        // Held-out capture is REPORTED, not asserted, and that is deliberate.
        //
        // The slice currently holds exactly one capturable case, which is far too
        // thin to gate on. Worse, gating it would create pressure to close the gap
        // the only way available — adding the missing phrasing to the catalog —
        // and the moment a keyword is written with a held-out ticket in view, that
        // ticket stops being held out. The slice's whole value is that nothing in
        // the catalog was authored against it; an assertion would quietly spend
        // that value to turn a light green.
        //
        // So: watch this number, grow the slice from new tickets, and let capture
        // rise as a side effect of catalog work aimed at patrons rather than at
        // the metric. Promote it to an assertion once the slice is large enough
        // that tuning to it is no longer the path of least resistance.
        let heldOut = bySlice["held_out"] ?? Tally()
        print("\nheld-out capture (reported, not gated): \(heldOut.captured)/\(heldOut.capturable)")
    }

    /// The floor the whole feature rests on: a patron who reaches the end of a
    /// conversation is never filed as "someone reported a problem".
    ///
    /// A ticket is better-identified than the email the patron would have sent
    /// unaided when it carries something that email would not have: the entry we
    /// recognised, an answer or explicit skip to a question we asked, or the
    /// remedies they told us they had already tried.
    ///
    /// The conversation is driven ALL THE WAY to a filed ticket — declining any
    /// ladder and skipping any question — because nothing reaches `.drafting` in
    /// one step any more. The first version of this test asserted on the state
    /// immediately after submitting the description, where every case is either
    /// `.matched` or `.awaitingEscalationFollowUp`, so it ran over an empty set
    /// and passed unconditionally. A mutation that stripped identification from
    /// every draft did not fail it; that is how the vacuum was found.
    func testEveryCase_WalkedToATicket_FilesAnIdentifiedTicket() throws {
        let kb = KnowledgeBase(catalog: try BundledCatalogSource.loadCatalogSync())
        let corpus = try loadCorpus()
        var blanks: [String] = []
        var filed = 0
        var beyondTheQuestion = 0

        for testCase in corpus.cases {
            guard let category = KBCategory(rawValue: testCase.category) else { continue }
            let reducer = ConversationReducer(knowledgeBase: kb)
            var (state, _) = reducer.reduce(state: ConversationState(), action: .start)
            (state, _) = reducer.reduce(state: state, action: .userTappedCategory(category))
            (state, _) = reducer.reduce(state: state, action: .inputChanged(testCase.text))
            (state, _) = reducer.reduce(state: state, action: .userSubmittedDescription)

            // A patron who wants a human: decline whatever is offered, skip
            // whatever is asked, and file. Bounded so a routing bug cannot spin.
            var hops = 0
            loop: while hops < 6 {
                hops += 1
                switch state.step {
                case .matched(let id):
                    (state, _) = reducer.reduce(state: state, action: .userTappedFileTicketAnyway)
                    _ = id
                case .awaitingEscalationFollowUp:
                    (state, _) = reducer.reduce(state: state, action: .userAnsweredEscalationFollowUp(answer: nil))
                default:
                    break loop
                }
            }

            guard case .drafting(let draft) = state.step else { continue }
            filed += 1
            let identified = draft.matchedEntryId != nil
                || draft.escalationFollowUp != nil
                || !draft.alreadyTried.isEmpty
                || draft.claimsExhaustedEffort
            if !identified { blanks.append(testCase.id) }
            if draft.matchedEntryId != nil || !draft.alreadyTried.isEmpty || draft.claimsExhaustedEffort {
                beyondTheQuestion += 1
            }
        }

        XCTAssertGreaterThan(filed, 20,
            "the walk reached only \(filed) tickets — if this collapses the assertions below are vacuous")
        XCTAssertTrue(blanks.isEmpty,
            "these filed with nothing support could not have read off the raw email: \(blanks)")

        // The assertion above is satisfied by the follow-up alone, which every
        // category has, so it cannot fail while catch-alls exist. This one can:
        // it requires that identification beyond the universal component actually
        // reaches the ticket. Stripping scoping or already-tried from the drafts
        // fails here and nowhere else in this suite.
        XCTAssertGreaterThan(beyondTheQuestion, 5,
            "no ticket carried anything beyond the question we ask everyone — scoping and already-tried are not reaching drafts")
    }

    /// The mined slice is where the catalog's own source tickets live. If the
    /// matcher cannot recall the very tickets its keywords were written from,
    /// nothing downstream is worth tuning.
    func testCorpus_minedSliceRecallsItsOwnSourceTickets() throws {
        let kb = KnowledgeBase(catalog: try BundledCatalogSource.loadCatalogSync())
        let corpus = try loadCorpus()

        let mined = corpus.cases.filter { $0.provenance == "mined" && !$0.expectsEscalation }
        var captured = 0
        var missed: [String] = []
        for testCase in mined {
            if case .captured = try outcome(for: testCase, kb: kb) {
                captured += 1
            } else {
                missed.append(testCase.id)
            }
        }

        // A RATCHET, not a target. This was a majority rule until the near-miss
        // slice showed the keywords carrying that majority were also misrouting
        // real patrons: "never works" captured hs-17976 (a genuine download
        // failure) and simultaneously fired KI-008's network advice at hs-18571,
        // whose audiobook simply would not play. Demoting it cost recall and
        // bought precision, which is the right direction — a missed ticket
        // escalates safely, a misrouted one hands out a wrong fix.
        //
        // The remaining misses are COVERAGE, not matching: hs-18028/18103 are
        // FAQ phrasings no how_to keyword covers, hs-17957 needs a "does not
        // appear" variant, hs-17917's own text does not support its label, and
        // hs-17930 would need a keyword overfitted to one ticket. Raise this
        // floor by adding entries and phrasings; never by re-promoting an
        // ambiguous phrase.
        XCTAssertGreaterThanOrEqual(
            captured, 7,
            "mined-slice recall regressed below the ratchet: \(captured)/\(mined.count); missed: \(missed.joined(separator: ", "))"
        )
    }
}
