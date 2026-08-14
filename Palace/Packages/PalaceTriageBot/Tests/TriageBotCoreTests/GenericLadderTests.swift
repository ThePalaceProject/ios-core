import XCTest
@testable import TriageBotCore

/// A remedy ladder for the 88% of complaints that match no entry.
///
/// Measured on 114 sealed tickets, 13 reach guided steps and 100 escalate with no
/// remedy offered at all, against a ceiling of 42% — the share of real
/// resolutions naming something a patron could have done themselves. The gap is
/// not exotic; it is a handful of remedies that exist in the catalog but are
/// reachable only through an entry match that usually does not happen.
///
/// The ladder is NOT a classifier. Grouping 204 tickets by the remedy support
/// prescribed and mining for distinguishing patron language produced noise
/// ("to it", "so it", "it it") — there is no signal for picking the right remedy
/// from a complaint. So the ladder does not pick: it offers a short, safe,
/// per-category sequence and lets the patron eliminate. Elimination beats
/// classification precisely when classification has nothing to go on.
///
/// It is also not new machinery. A ladder is a catalog entry of kind
/// `generic_flow` whose steps carry remedy tags, executed by the guided-step
/// engine that already exists — so already-tried skipping, step advance,
/// exhaustion, abandonment and per-step telemetry all apply unchanged.
final class GenericLadderTests: XCTestCase {

    // MARK: - Fixtures

    private func ladder(
        category: KBCategory = .audiobook,
        steps: [KBStep] = [
            KBStep(id: "g1", instruction: "Pull down on the list to refresh.", check: "Any change?", remedy: .pullToRefresh),
            KBStep(id: "g2", instruction: "Open the App Store and install any Palace update.", check: "Any change?", remedy: .updateApp),
        ]
    ) -> KBEntry {
        KBEntry(id: "GF-\(category.rawValue)", category: category, kind: .genericFlow,
                symptomKeywords: [], userFacingWorkaround: "A few things worth trying.",
                userFacingSteps: steps, confidenceThreshold: 0.1)
    }

    private func reducer(_ entries: [KBEntry],
                         categoryFollowUps: [String: KBEscalationFollowUp]? = nil) -> ConversationReducer {
        ConversationReducer(knowledgeBase: KnowledgeBase(catalog: KBCatalog(
            version: "t", updatedAt: "x", entries: entries, categoryFollowUps: categoryFollowUps)))
    }

    private func drive(_ r: ConversationReducer, _ cat: KBCategory, _ text: String) -> ConversationState {
        var (s, _) = r.reduce(state: ConversationState(), action: .start)
        (s, _) = r.reduce(state: s, action: .userTappedCategory(cat))
        (s, _) = r.reduce(state: s, action: .inputChanged(text))
        return r.reduce(state: s, action: .userSubmittedDescription).0
    }

    // MARK: - Step 1: invisible to the classifier

    /// A ladder must never win a match. Its keyword list is empty, but an entry
    /// with no keywords still enters the candidate set today, which would let it
    /// pollute `consideredEntryIds` and — if it ever gained a keyword — compete
    /// for a suggestion against real entries.
    func testGenericFlowEntries_neverCompeteForMatches() {
        let trap = KBEntry(id: "GF-trap", category: .audiobook, kind: .genericFlow,
                           symptomKeywords: ["my audiobook wont play"],
                           userFacingWorkaround: "…", confidenceThreshold: 0.1)
        let result = LocalClassifier().classify(
            userText: "my audiobook wont play", category: .audiobook, context: nil,
            knowledgeBase: KnowledgeBase(catalog: KBCatalog(version: "t", updatedAt: "x", entries: [trap])))

        XCTAssertEqual(result.decision, .escalate, "a generic flow must never be suggested as a diagnosis")
        XCTAssertNil(result.recognizedEntryId, "…nor scope a ticket as though it were one")
        XCTAssertFalse(result.consideredEntryIds.contains("GF-trap"), "…nor appear as a considered candidate")
    }

    // MARK: - Step 2: the one changed cell

    func testUnmatchedComplaint_isOfferedTheLadder() {
        let state = drive(reducer([ladder()]), .audiobook, "something is wrong with this thing")
        XCTAssertEqual(state.step, .matched(entryId: "GF-audiobook"),
                       "an unmatched complaint should be offered remedies, not just a ticket")
    }

    /// Back-compat: a catalog with no ladder for the category must behave exactly
    /// as it does today.
    func testUnmatchedComplaint_withNoLadderForThatCategory_behavesAsBefore() {
        let r = reducer([ladder(category: .library)],
                        categoryFollowUps: ["audiobook": KBEscalationFollowUp(prompt: "Start or partway?", presumesIssue: false)])
        let state = drive(r, .audiobook, "something is wrong with this thing")
        guard case .awaitingEscalationFollowUp = state.step else {
            return XCTFail("expected today's category-question behaviour; got \(state.step)")
        }
    }

    // MARK: - Step 3: cells that must NOT get the ladder

    /// `escalate_anyway` encodes "no safe self-serve fix exists" — the quarter of
    /// real tickets only staff or the library can resolve. Offering remedies there
    /// is delay dressed as help.
    func testEscalateAnywayEntry_isNeverOfferedTheLadder() {
        let staffOnly = KBEntry(id: "KI-STAFF", category: .audiobook, status: .open,
                                symptomKeywords: ["card is expired"],
                                userFacingWorkaround: "Your library needs to renew the card.",
                                escalationFollowUp: KBEscalationFollowUp(prompt: "Which library issued it?"),
                                confidenceThreshold: 0.1, escalateAnyway: true)
        let state = drive(reducer([staffOnly, ladder()]), .audiobook, "my card is expired")
        if case .matched(let id) = state.step, id.hasPrefix("GF-") {
            XCTFail("offered self-serve remedies for a problem only staff can fix")
        }
    }

    func testMatchedEntry_overridesTheLadderEntirely() {
        let real = KBEntry(id: "KI-REAL", category: .audiobook, status: .open,
                           symptomKeywords: ["wont play"],
                           userFacingWorkaround: "Do the specific thing.",
                           confidenceThreshold: 0.1)
        let state = drive(reducer([real, ladder()]), .audiobook, "it wont play")
        XCTAssertEqual(state.step, .matched(entryId: "KI-REAL"),
                       "a real diagnosis always beats a generic ladder")
    }

    /// "I've tried everything" is a claim of exhausted effort. Walking that patron
    /// through rungs is the not-listening defect in its purest form.
    func testBlanketExhaustedEffort_bypassesTheLadder() {
        let r = reducer([ladder()],
                        categoryFollowUps: ["audiobook": KBEscalationFollowUp(prompt: "Start or partway?", presumesIssue: false)])
        let state = drive(r, .audiobook, "I have tried everything and nothing works")
        if case .matched(let id) = state.step, id.hasPrefix("GF-") {
            XCTFail("offered a remedy ladder to someone who said they had tried everything")
        }
    }

    // MARK: - Step 4: the existing engine does the work

    func testLadder_skipsRungsThePatronAlreadyTried() {
        let r = reducer([ladder()])
        var s = drive(r, .audiobook, "something is broken, I already pulled down to refresh")
        s = r.reduce(state: s, action: .userTappedStartGuidedFlow(entryId: "GF-audiobook")).0
        guard case .guidedStep(_, let index, _, _) = s.step else {
            return XCTFail("expected a rung; got \(s.step)")
        }
        XCTAssertEqual(index, 1, "must start at the first rung they have not already tried")
    }
}
