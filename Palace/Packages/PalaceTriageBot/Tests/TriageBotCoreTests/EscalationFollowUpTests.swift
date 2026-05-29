import XCTest
@testable import TriageBotCore

/// Tests for the structured escalation follow-up question — entries that define
/// an `escalationFollowUp` get one targeted question (e.g. "which library?")
/// before the ticket preview, and the answer attaches to the TicketDraft so
/// support sees the structured context immediately.
///
/// Coverage:
///   - Local-classifier escalate path WITH follow-up routes to
///     .awaitingEscalationFollowUp, never straight to .drafting
///   - Local-classifier escalate path WITHOUT follow-up still goes straight
///     to .drafting (preserves prior behavior for entries that don't opt in)
///   - .userAnsweredEscalationFollowUp(answer:) merges the answer into the
///     draft + emits the answered telemetry + transitions to .drafting
///   - .userAnsweredEscalationFollowUp(answer: nil) is the Skip path —
///     attaches "(skipped)" marker + emits the skipped telemetry
///   - The action is a no-op outside .awaitingEscalationFollowUp (no crash)
///   - .userTappedFileTicketAnyway routes through the follow-up gate too
///   - Guided-flow escalate path (escalateWithTrace) also routes through
///     follow-up when the entry has one
final class EscalationFollowUpTests: XCTestCase {

    private static let kbWithFollowUp = KnowledgeBase(catalog: KBCatalog(
        version: "test",
        updatedAt: "x",
        entries: [
            KBEntry(
                id: "KI-FU",
                category: .library,
                status: .userError,
                symptomKeywords: ["wrong library"],
                userFacingWorkaround: "Tap the Palace logo top-left.",
                userFacingSteps: [
                    KBStep(id: "s1", instruction: "Tap logo.", check: "See list?", diagnostic: "d1")
                ],
                escalationFollowUp: KBEscalationFollowUp(
                    prompt: "Which library are you trying to add?",
                    placeholder: "e.g. Brooklyn Public Library",
                    diagnostic: "library.followup_name_captured"
                ),
                confidenceThreshold: 0.1
            )
        ]
    ))

    private static let kbWithoutFollowUp = KnowledgeBase(catalog: KBCatalog(
        version: "test",
        updatedAt: "x",
        entries: [
            KBEntry(
                id: "KI-NOFU",
                category: .reader,
                status: .open,
                symptomKeywords: ["reader"],
                userFacingWorkaround: "Workaround text.",
                userFacingSteps: nil,
                escalationFollowUp: nil,
                confidenceThreshold: 0.1
            )
        ]
    ))

    // MARK: - Local escalate path

    func testFileTicketAnyway_entryWithFollowUp_routesToAwaitingFollowUp() {
        let reducer = ConversationReducer(knowledgeBase: Self.kbWithFollowUp)
        var initial = ConversationState(step: .matched(entryId: "KI-FU"))
        initial.messages.append(.init(sender: .user, kind: .text("can't find my library")))
        let (next, effects) = reducer.reduce(state: initial, action: .userTappedFileTicketAnyway)

        guard case .awaitingEscalationFollowUp(let prompt, let pendingDraft) = next.step else {
            return XCTFail("Expected .awaitingEscalationFollowUp, got \(next.step)")
        }
        XCTAssertEqual(prompt, "Which library are you trying to add?")
        XCTAssertEqual(pendingDraft.matchedEntryId, "KI-FU")
        XCTAssertNil(pendingDraft.escalationFollowUp, "Pending draft must not yet have the answer attached")
        XCTAssertTrue(effects.contains { effect in
            if case .emitTelemetry(let e) = effect {
                return e.name == "triage_escalation_followup_asked" && e.parameters["entry_id"] == "KI-FU"
            }
            return false
        }, "Must emit the followup-asked telemetry")
    }

    func testFileTicketAnyway_entryWithoutFollowUp_goesStraightToDrafting() {
        let reducer = ConversationReducer(knowledgeBase: Self.kbWithoutFollowUp)
        var initial = ConversationState(step: .matched(entryId: "KI-NOFU"))
        initial.messages.append(.init(sender: .user, kind: .text("doesn't work")))
        let (next, _) = reducer.reduce(state: initial, action: .userTappedFileTicketAnyway)

        guard case .drafting(let draft) = next.step else {
            return XCTFail("Expected .drafting, got \(next.step)")
        }
        XCTAssertEqual(draft.matchedEntryId, "KI-NOFU")
        XCTAssertTrue(next.messages.contains { msg in
            if case .ticketPreview = msg.kind { return true }
            return false
        }, "Ticket preview must appear when no follow-up gate")
    }

    // MARK: - Answer + Skip

    func testAnsweredFollowUp_withText_mergesIntoDraft_andTransitionsToDrafting() {
        let reducer = ConversationReducer(knowledgeBase: Self.kbWithFollowUp)
        let pending = TicketDraft(
            userDescription: "can't find my library",
            category: .library,
            matchedEntryId: "KI-FU",
            context: minimalContext(),
            helpspotTags: ["pre-existing-tag"],
            priority: .low
        )
        let initial = ConversationState(step: .awaitingEscalationFollowUp(
            prompt: "Which library are you trying to add?",
            pendingDraft: pending
        ))
        let (next, effects) = reducer.reduce(
            state: initial,
            action: .userAnsweredEscalationFollowUp(answer: "Brooklyn Public Library")
        )

        guard case .drafting(let enriched) = next.step else {
            return XCTFail("Expected .drafting, got \(next.step)")
        }
        XCTAssertEqual(enriched.escalationFollowUp?.answer, "Brooklyn Public Library")
        XCTAssertEqual(enriched.escalationFollowUp?.prompt, "Which library are you trying to add?")
        XCTAssertTrue(
            enriched.helpspotTags.contains("escalation-follow-up-answered"),
            "Helpspot tag must mark this as answered for support's triage filters"
        )
        XCTAssertEqual(enriched.matchedEntryId, "KI-FU", "Pre-existing draft fields must survive the merge")
        XCTAssertTrue(enriched.helpspotTags.contains("pre-existing-tag"), "Original tags must survive")
        XCTAssertTrue(
            next.messages.contains { msg in
                if case .text(let t) = msg.kind, t == "Brooklyn Public Library" { return true }
                return false
            },
            "User's typed answer must appear in chat history"
        )
        XCTAssertTrue(next.messages.contains { msg in
            if case .ticketPreview(let d) = msg.kind {
                return d.escalationFollowUp?.answer == "Brooklyn Public Library"
            }
            return false
        }, "Ticket preview message must carry the enriched draft")
        XCTAssertTrue(effects.contains { effect in
            if case .emitTelemetry(let e) = effect {
                return e.name == "triage_escalation_followup_answered" && e.parameters["entry_id"] == "KI-FU"
            }
            return false
        })
        XCTAssertEqual(next.inputText, "", "Input must be cleared after answer is consumed")
    }

    func testAnsweredFollowUp_withNil_tagsAsSkipped_emitsSkippedTelemetry() {
        let reducer = ConversationReducer(knowledgeBase: Self.kbWithFollowUp)
        let pending = TicketDraft(
            userDescription: "can't find my library",
            category: .library,
            matchedEntryId: "KI-FU",
            context: minimalContext(),
            helpspotTags: [],
            priority: .low
        )
        let initial = ConversationState(step: .awaitingEscalationFollowUp(
            prompt: "Which library are you trying to add?",
            pendingDraft: pending
        ))
        let (next, effects) = reducer.reduce(
            state: initial,
            action: .userAnsweredEscalationFollowUp(answer: nil)
        )

        guard case .drafting(let enriched) = next.step else {
            return XCTFail("Expected .drafting, got \(next.step)")
        }
        XCTAssertNil(enriched.escalationFollowUp?.answer, "Skip answer must be nil")
        XCTAssertEqual(enriched.escalationFollowUp?.prompt, "Which library are you trying to add?")
        XCTAssertTrue(
            enriched.helpspotTags.contains("escalation-follow-up-skipped"),
            "Helpspot tag must distinguish skip from answer"
        )
        XCTAssertTrue(effects.contains { effect in
            if case .emitTelemetry(let e) = effect {
                return e.name == "triage_escalation_followup_skipped"
            }
            return false
        })
    }

    func testAnsweredFollowUp_outsideAwaitingState_isNoOp() {
        let reducer = ConversationReducer(knowledgeBase: Self.kbWithFollowUp)
        let initial = ConversationState(step: .awaitingCategory)
        let (next, effects) = reducer.reduce(
            state: initial,
            action: .userAnsweredEscalationFollowUp(answer: "should be ignored")
        )
        XCTAssertEqual(next.step, initial.step, "State must not change outside .awaitingEscalationFollowUp")
        XCTAssertTrue(effects.isEmpty, "No effects should fire when action is a no-op")
    }

    // MARK: - Guided flow exhaustion routes through follow-up

    func testGuidedFlowExhausted_entryWithFollowUp_routesToAwaitingFollowUp() {
        let reducer = ConversationReducer(knowledgeBase: Self.kbWithFollowUp)
        let initial = ConversationState(step: .guidedStep(
            entryId: "KI-FU",
            stepIndex: 0,
            startedAt: Date(timeIntervalSince1970: 0),
            attempts: []
        ))
        let (next, _) = reducer.reduce(state: initial, action: .userConfirmedStepDidNotResolve(stepId: "s1"))

        guard case .awaitingEscalationFollowUp(let prompt, let pendingDraft) = next.step else {
            return XCTFail("Guided-flow exhaustion with follow-up entry must route to .awaitingEscalationFollowUp, got \(next.step)")
        }
        XCTAssertEqual(prompt, "Which library are you trying to add?")
        XCTAssertNotNil(pendingDraft.resolutionTrace, "Trace must still be attached to the pending draft")
        XCTAssertEqual(pendingDraft.resolutionTrace?.attempts.count, 1)
        XCTAssertEqual(pendingDraft.resolutionTrace?.outcome, .escalatedAfterStepsExhausted)
    }

    // MARK: - Helpers

    private func minimalContext() -> ContextSnapshot {
        ContextSnapshot(
            appVersion: "3.2.0",
            appBuild: "999",
            osVersion: "26.0",
            deviceModel: "iPhone",
            capturedAt: Date(timeIntervalSince1970: 0)
        )
    }
}
