import XCTest
@testable import TriageBotCore

/// Tests for the guided troubleshooting flow added 2026-05-29.
///
/// Coverage:
///   - .userTappedStartGuidedFlow enters the .guidedStep state with stepIndex 0
///     and appends a guidedStep message to the UI log
///   - .userConfirmedStepResolved short-circuits to a friendly close, records
///     the resolved StepAttempt, never escalates
///   - .userConfirmedStepDidNotResolve advances to next step OR exhausts
///     into escalation-with-trace
///   - .userTappedAbandonGuidedFlow records an abandoned attempt and escalates
///   - All actions are no-ops outside .guidedStep state (no crash, no transition)
///   - The escalation TicketDraft carries the full ResolutionTrace with
///     timestamps + outcomes for every step
final class GuidedFlowTests: XCTestCase {

    private static let kbWithSteps = KnowledgeBase(catalog: KBCatalog(
        version: "test",
        updatedAt: "x",
        entries: [
            KBEntry(
                id: "KI-GUIDED",
                category: .audiobook,
                status: .open,
                fixedInVersion: "3.2.0",
                symptomKeywords: ["test"],
                userFacingWorkaround: "Summary text.",
                userFacingSteps: [
                    KBStep(id: "step1", instruction: "Try X.", check: "Did X work?", diagnostic: "diag.x"),
                    KBStep(id: "step2", instruction: "Try Y.", check: "Did Y work?", diagnostic: "diag.y"),
                    KBStep(id: "step3", instruction: "Try Z.", check: "Did Z work?", diagnostic: "diag.z")
                ],
                confidenceThreshold: 0.1
            )
        ]
    ))

    private static let kbNoSteps = KnowledgeBase(catalog: KBCatalog(
        version: "test",
        updatedAt: "x",
        entries: [
            KBEntry(
                id: "KI-NO-STEPS",
                category: .audiobook,
                status: .open,
                symptomKeywords: ["x"],
                userFacingWorkaround: "Just read this.",
                userFacingSteps: nil,
                confidenceThreshold: 0.1
            )
        ]
    ))

    // MARK: - Start guided flow

    func testStartGuidedFlow_entersGuidedStep_andAppendsCard() {
        let reducer = ConversationReducer(knowledgeBase: Self.kbWithSteps)
        let initial = ConversationState(step: .matched(entryId: "KI-GUIDED"))
        let (next, effects) = reducer.reduce(state: initial, action: .userTappedStartGuidedFlow(entryId: "KI-GUIDED"))

        guard case .guidedStep(let id, let idx, _, let attempts) = next.step else {
            return XCTFail("Expected .guidedStep, got \(next.step)")
        }
        XCTAssertEqual(id, "KI-GUIDED")
        XCTAssertEqual(idx, 0)
        XCTAssertTrue(attempts.isEmpty, "Fresh flow has no attempts yet")
        XCTAssertTrue(next.messages.contains { msg in
            if case .guidedStep(let mid, let mIdx) = msg.kind {
                return mid == "KI-GUIDED" && mIdx == 0
            }
            return false
        }, "First step card must be appended to messages")
        XCTAssertTrue(effects.contains { effect in
            if case .emitTelemetry(let e) = effect {
                return e.name == "triage_guided_flow_started" && e.parameters["entry_id"] == "KI-GUIDED"
            }
            return false
        })
    }

    func testStartGuidedFlow_entryWithoutSteps_isNoOp() {
        let reducer = ConversationReducer(knowledgeBase: Self.kbNoSteps)
        let initial = ConversationState(step: .matched(entryId: "KI-NO-STEPS"))
        let (next, _) = reducer.reduce(state: initial, action: .userTappedStartGuidedFlow(entryId: "KI-NO-STEPS"))
        XCTAssertEqual(next.step, initial.step, "Entry without steps must not transition state")
    }

    // MARK: - Resolved short-circuits

    func testStepResolved_atFirstStep_closesOut_recordsResolved() {
        let reducer = ConversationReducer(knowledgeBase: Self.kbWithSteps)
        let initial = ConversationState(step: .guidedStep(
            entryId: "KI-GUIDED",
            stepIndex: 0,
            startedAt: Date(timeIntervalSince1970: 0),
            attempts: []
        ))
        let (next, effects) = reducer.reduce(state: initial, action: .userConfirmedStepResolved(stepId: "step1"))

        guard case .sent(let receipt) = next.step else {
            return XCTFail("Expected .sent after resolved, got \(next.step)")
        }
        XCTAssertTrue(receipt.ticketId.contains("guided-resolved"))
        XCTAssertTrue(effects.contains { effect in
            if case .emitTelemetry(let e) = effect {
                return e.name == "triage_guided_step_resolved"
                    && e.parameters["step_id"] == "step1"
                    && e.parameters["steps_attempted"] == "1"
            }
            return false
        })
    }

    func testStepResolved_midFlow_closesOut_recordsCumulativeAttempts() {
        let reducer = ConversationReducer(knowledgeBase: Self.kbWithSteps)
        let priorAttempt = StepAttempt(stepId: "step1", outcome: .didNotResolve, timestamp: Date(timeIntervalSince1970: 1))
        let initial = ConversationState(step: .guidedStep(
            entryId: "KI-GUIDED",
            stepIndex: 1,
            startedAt: Date(timeIntervalSince1970: 0),
            attempts: [priorAttempt]
        ))
        let (next, effects) = reducer.reduce(state: initial, action: .userConfirmedStepResolved(stepId: "step2"))

        guard case .sent = next.step else { return XCTFail("Expected .sent, got \(next.step)") }
        XCTAssertTrue(effects.contains { effect in
            if case .emitTelemetry(let e) = effect {
                return e.name == "triage_guided_step_resolved" && e.parameters["steps_attempted"] == "2"
            }
            return false
        }, "Cumulative attempt count must include the prior didNotResolve + the now-resolved step")
    }

    // MARK: - Not-resolved advances OR exhausts

    func testStepDidNotResolve_advancesToNextStep_withCumulativeAttempts() {
        let reducer = ConversationReducer(knowledgeBase: Self.kbWithSteps)
        let initial = ConversationState(step: .guidedStep(
            entryId: "KI-GUIDED",
            stepIndex: 0,
            startedAt: Date(timeIntervalSince1970: 0),
            attempts: []
        ))
        let (next, _) = reducer.reduce(state: initial, action: .userConfirmedStepDidNotResolve(stepId: "step1"))

        guard case .guidedStep(let id, let idx, _, let attempts) = next.step else {
            return XCTFail("Expected .guidedStep, got \(next.step)")
        }
        XCTAssertEqual(id, "KI-GUIDED")
        XCTAssertEqual(idx, 1, "Should advance from 0 → 1")
        XCTAssertEqual(attempts.count, 1)
        XCTAssertEqual(attempts.first?.stepId, "step1")
        XCTAssertEqual(attempts.first?.outcome, .didNotResolve)
        XCTAssertTrue(next.messages.contains { msg in
            if case .guidedStep(_, let idx) = msg.kind { return idx == 1 }
            return false
        }, "Next step card must render")
    }

    func testStepDidNotResolve_atLastStep_escalatesWithFullTrace() {
        let reducer = ConversationReducer(knowledgeBase: Self.kbWithSteps)
        let attempts = [
            StepAttempt(stepId: "step1", outcome: .didNotResolve, timestamp: Date(timeIntervalSince1970: 1)),
            StepAttempt(stepId: "step2", outcome: .didNotResolve, timestamp: Date(timeIntervalSince1970: 2))
        ]
        let initial = ConversationState(
            step: .guidedStep(
                entryId: "KI-GUIDED",
                stepIndex: 2,
                startedAt: Date(timeIntervalSince1970: 0),
                attempts: attempts
            ),
            context: ContextSnapshot(appVersion: "3", appBuild: "1", osVersion: "26", deviceModel: "x")
        )
        let (next, _) = reducer.reduce(state: initial, action: .userConfirmedStepDidNotResolve(stepId: "step3"))

        guard case .drafting(let draft) = next.step else {
            return XCTFail("Expected .drafting after exhaustion, got \(next.step)")
        }
        XCTAssertEqual(draft.matchedEntryId, "KI-GUIDED")
        guard let trace = draft.resolutionTrace else {
            return XCTFail("TicketDraft must carry the trace after exhaustion")
        }
        XCTAssertEqual(trace.outcome, .escalatedAfterStepsExhausted)
        XCTAssertEqual(trace.attempts.count, 3, "Trace must include all 3 attempts (2 prior + this one)")
        XCTAssertEqual(trace.attempts.map(\.stepId), ["step1", "step2", "step3"])
        XCTAssertTrue(draft.helpspotTags.contains(where: { $0.contains("guided-flow-escalated") }))
    }

    // MARK: - Abandon

    func testAbandonGuidedFlow_escalatesWithAbandonedTrace() {
        let reducer = ConversationReducer(knowledgeBase: Self.kbWithSteps)
        let priorAttempt = StepAttempt(stepId: "step1", outcome: .didNotResolve, timestamp: Date(timeIntervalSince1970: 1))
        let initial = ConversationState(
            step: .guidedStep(
                entryId: "KI-GUIDED",
                stepIndex: 1,
                startedAt: Date(timeIntervalSince1970: 0),
                attempts: [priorAttempt]
            ),
            context: ContextSnapshot(appVersion: "3", appBuild: "1", osVersion: "26", deviceModel: "x")
        )
        let (next, _) = reducer.reduce(state: initial, action: .userTappedAbandonGuidedFlow)

        guard case .drafting(let draft) = next.step else {
            return XCTFail("Expected .drafting after abandon, got \(next.step)")
        }
        guard let trace = draft.resolutionTrace else {
            return XCTFail("Abandon must still attach a trace")
        }
        XCTAssertEqual(trace.outcome, .abandoned)
        XCTAssertGreaterThanOrEqual(trace.attempts.count, 1, "At least the prior attempt is preserved in the trace")
        XCTAssertTrue(draft.helpspotTags.contains(where: { $0.contains("guided-flow-abandoned") }))
    }

    // MARK: - Out-of-state safety

    func testGuidedActions_outsideGuidedStep_areNoOps() {
        let reducer = ConversationReducer(knowledgeBase: Self.kbWithSteps)
        let initial = ConversationState(step: .welcome)
        let (a, _) = reducer.reduce(state: initial, action: .userConfirmedStepResolved(stepId: "step1"))
        let (b, _) = reducer.reduce(state: initial, action: .userConfirmedStepDidNotResolve(stepId: "step1"))
        let (c, _) = reducer.reduce(state: initial, action: .userTappedAbandonGuidedFlow)
        XCTAssertEqual(a.step, initial.step)
        XCTAssertEqual(b.step, initial.step)
        XCTAssertEqual(c.step, initial.step)
    }
}
