import XCTest
@testable import TriageBotCore

/// A ticket filed after a remedy ladder must still carry whatever the classifier
/// recognised, not the ladder's own id.
///
/// Weak recognition is what scopes a ticket for support: the patron's words
/// brushed an entry without earning a suggestion, and that hint is worth more to
/// a triager than nothing. Routing those patrons through a generic ladder must
/// not overwrite the hint — "generic-ladder-audiobook" tells support only that
/// the bot had no idea, which they can already see from the absence of an answer.
final class LadderScopingTests: XCTestCase {

    private func kb() -> KnowledgeBase {
        // Weak-only keyword: matches, cannot suggest, carries a recognition.
        let weak = KBEntry(
            id: "KI-WEAK", category: .audiobook, status: .open,
            symptomKeywords: ["a phrase nobody types"],
            corroboratingKeywords: ["crashes"],
            userFacingWorkaround: "The CarPlay workaround.",
            confidenceThreshold: 0.1)
        let ladder = KBEntry(
            id: "GF-audiobook", category: .audiobook, kind: .genericFlow,
            symptomKeywords: [],
            userFacingWorkaround: "A few things to try.",
            userFacingSteps: [KBStep(id: "g1", instruction: "Try the thing.", check: "Any change?",
                                     remedy: .pullToRefresh)])
        return KnowledgeBase(catalog: KBCatalog(
            version: "t", updatedAt: "x", entries: [weak, ladder],
            categoryFollowUps: ["audiobook": KBEscalationFollowUp(prompt: "Start or partway?",
                                                                 presumesIssue: false)]))
    }

    func testTicketAfterLadder_isScopedToTheWeaklyRecognizedEntry() {
        let r = ConversationReducer(knowledgeBase: kb())
        var (s, _) = r.reduce(state: ConversationState(), action: .start)
        (s, _) = r.reduce(state: s, action: .userTappedCategory(.audiobook))
        (s, _) = r.reduce(state: s, action: .inputChanged("the app crashes when I open it"))
        (s, _) = r.reduce(state: s, action: .userSubmittedDescription)

        guard case .matched(let offered) = s.step, offered == "GF-audiobook" else {
            return XCTFail("expected the ladder to be offered; got \(s.step)")
        }
        (s, _) = r.reduce(state: s, action: .userTappedStartGuidedFlow(entryId: "GF-audiobook"))
        (s, _) = r.reduce(state: s, action: .userConfirmedStepDidNotResolve(stepId: "g1"))

        // Walk past any follow-up to the draft.
        if case .awaitingEscalationFollowUp = s.step {
            (s, _) = r.reduce(state: s, action: .userAnsweredEscalationFollowUp(answer: nil))
        }
        guard case .drafting(let ticket) = s.step else {
            return XCTFail("expected a ticket preview; got \(s.step)")
        }
        XCTAssertEqual(ticket.matchedEntryId, "KI-WEAK",
                       "the ticket must carry the recognised entry, not the ladder id")
    }

    /// Abandoning a ladder mid-way must scope the ticket the same way — the
    /// patron gave up on the remedies, not on the hint about what they reported.
    func testTicketAfterAbandonedLadder_isAlsoScopedToTheRecognizedEntry() {
        let r = ConversationReducer(knowledgeBase: kb())
        var (s, _) = r.reduce(state: ConversationState(), action: .start)
        (s, _) = r.reduce(state: s, action: .userTappedCategory(.audiobook))
        (s, _) = r.reduce(state: s, action: .inputChanged("the app crashes when I open it"))
        (s, _) = r.reduce(state: s, action: .userSubmittedDescription)
        (s, _) = r.reduce(state: s, action: .userTappedStartGuidedFlow(entryId: "GF-audiobook"))
        (s, _) = r.reduce(state: s, action: .userTappedAbandonGuidedFlow)

        if case .awaitingEscalationFollowUp = s.step {
            (s, _) = r.reduce(state: s, action: .userAnsweredEscalationFollowUp(answer: nil))
        }
        guard case .drafting(let ticket) = s.step else {
            return XCTFail("expected a ticket preview; got \(s.step)")
        }
        XCTAssertEqual(ticket.matchedEntryId, "KI-WEAK")
    }
}
