import XCTest
@testable import TriageBotCore

/// A guided flow that runs out of steps must still ask something before filing.
///
/// `askEscalationFollowUpOrDraft` falls back to the category's catch-all question
/// when the entry has none, but `escalateWithTrace` — the path taken when a
/// guided flow is exhausted or abandoned — only ever consulted the entry's own.
/// An entry with steps and no `escalationFollowUp` therefore walked the patron
/// through a troubleshooting flow and then filed a ticket with no question asked:
/// the blank-ticket class this branch exists to eliminate, surviving on the one
/// path that had the most patron effort invested in it.
final class EscalationFollowUpFallbackTests: XCTestCase {

    private func kb() -> KnowledgeBase {
        // Steps, but deliberately NO escalationFollowUp of its own.
        let entry = KBEntry(
            id: "K", category: .audiobook, status: .open,
            symptomKeywords: ["alpha thing"],
            userFacingWorkaround: "Try the fix.",
            userFacingSteps: [KBStep(id: "s1", instruction: "Do the thing.", check: "Better?")],
            confidenceThreshold: 0.1)
        return KnowledgeBase(catalog: KBCatalog(
            version: "t", updatedAt: "x", entries: [entry],
            categoryFollowUps: ["audiobook": KBEscalationFollowUp(
                prompt: "Does it fail at the start, or partway through?",
                presumesIssue: false)]))
    }

    private func walkToExhaustion() -> ConversationState {
        let r = ConversationReducer(knowledgeBase: kb())
        var (s, _) = r.reduce(state: ConversationState(), action: .start)
        (s, _) = r.reduce(state: s, action: .userTappedCategory(.audiobook))
        (s, _) = r.reduce(state: s, action: .inputChanged("the alpha thing is broken"))
        (s, _) = r.reduce(state: s, action: .userSubmittedDescription)
        (s, _) = r.reduce(state: s, action: .userTappedStartGuidedFlow(entryId: "K"))
        return r.reduce(state: s, action: .userConfirmedStepDidNotResolve(stepId: "s1")).0
    }

    func testGuidedFlowExhausted_entryWithoutOwnFollowUp_asksTheCategoryQuestion() {
        let state = walkToExhaustion()
        guard case .awaitingEscalationFollowUp(let prompt, _) = state.step else {
            return XCTFail("""
                exhausted a guided flow and filed without asking anything — \
                got \(state.step)
                """)
        }
        XCTAssertTrue(prompt.contains("at the start, or partway through"),
                      "should fall back to the category's catch-all: \(prompt)")
    }
}
