import XCTest
@testable import TriageBotCore

/// Every guided flow must leave a record of what was tried and how it ended.
///
/// The reducer builds a full `ResolutionTrace` on the resolved path and then
/// throws it away (`_ = trace`), so the one outcome worth learning from — the
/// remedy that WORKED — was the only one never recorded. Exhausted and abandoned
/// flows carried their trace out on the ticket; resolved flows carried it
/// nowhere, because there is no ticket.
///
/// That asymmetry makes the per-step diagnostics unusable for their stated
/// purpose ("support sees step 2 resolves 73% of KI-001 cases"), and it means
/// any future re-ordering of remedies would rest on the same 204-ticket priors
/// forever. The priors are already known to be era-bound — audiobook's
/// update-the-app rate reflects a specific broken release. Without this, there
/// is no path from those priors to measured ones.
final class ResolutionTracePersistenceTests: XCTestCase {

    private func flow() -> ConversationReducer {
        let entry = KBEntry(
            id: "K", category: .audiobook, status: .open,
            symptomKeywords: ["alpha thing"],
            userFacingWorkaround: "Try it.",
            userFacingSteps: [
                KBStep(id: "s1", instruction: "First thing.", check: "Better?", remedy: .pullToRefresh),
                KBStep(id: "s2", instruction: "Second thing.", check: "Better?", remedy: .updateApp),
            ],
            confidenceThreshold: 0.1)
        return ConversationReducer(knowledgeBase: KnowledgeBase(
            catalog: KBCatalog(version: "t", updatedAt: "x", entries: [entry])))
    }

    private func intoFlow(_ r: ConversationReducer) -> ConversationState {
        var (s, _) = r.reduce(state: ConversationState(), action: .start)
        (s, _) = r.reduce(state: s, action: .userTappedCategory(.audiobook))
        (s, _) = r.reduce(state: s, action: .inputChanged("the alpha thing is broken"))
        (s, _) = r.reduce(state: s, action: .userSubmittedDescription)
        return r.reduce(state: s, action: .userTappedStartGuidedFlow(entryId: "K")).0
    }

    private func persisted(_ effects: [ConversationEffect]) -> ResolutionTrace? {
        for e in effects { if case .persistResolutionTrace(let t) = e { return t } }
        return nil
    }

    /// The important one: a remedy that worked is the only evidence that can ever
    /// re-rank the ladder, and it was the one being discarded.
    func testResolvedFlow_persistsTheTraceWithTheWinningStep() {
        let r = flow()
        let state = intoFlow(r)
        let (_, effects) = r.reduce(state: state, action: .userConfirmedStepResolved(stepId: "s1"))

        let trace = persisted(effects)
        XCTAssertNotNil(trace, "the resolved outcome — the only one worth learning from — was discarded")
        XCTAssertEqual(trace?.outcome, .resolved)
        XCTAssertEqual(trace?.attempts.map(\.stepId), ["s1"], "must record WHICH step resolved it")
    }

    func testExhaustedFlow_persistsTheTrace() {
        let r = flow()
        var s = intoFlow(r)
        (s, _) = r.reduce(state: s, action: .userConfirmedStepDidNotResolve(stepId: "s1"))
        let (_, effects) = r.reduce(state: s, action: .userConfirmedStepDidNotResolve(stepId: "s2"))

        let trace = persisted(effects)
        XCTAssertEqual(trace?.outcome, .escalatedAfterStepsExhausted)
        XCTAssertEqual(trace?.attempts.count, 2, "both failed attempts must be recorded, in order")
    }

    func testAbandonedFlow_persistsTheTrace() {
        let r = flow()
        let s = intoFlow(r)
        let (_, effects) = r.reduce(state: s, action: .userTappedAbandonGuidedFlow)
        XCTAssertEqual(persisted(effects)?.outcome, .abandoned,
                       "abandonment is a signal about the rung, not an absence of one")
    }
}
