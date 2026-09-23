import XCTest
@testable import TriageBotCore

/// PP-4832: escalation carries the context the bot already recognized, and the
/// previously-dead `escalate_anyway` / `trust_level` fields now change behavior.
final class StructuredEscalationTests: XCTestCase {

    private let classifier = LocalClassifier()

    private func kb(_ entries: [KBEntry]) -> KnowledgeBase {
        KnowledgeBase(catalog: KBCatalog(version: "test", updatedAt: "2026-07-20", entries: entries))
    }
    private func reducer(_ entries: [KBEntry]) -> ConversationReducer {
        ConversationReducer(knowledgeBase: kb(entries))
    }

    // MARK: - Classifier: recognizedEntryId

    func testLowConfidenceEscalate_carriesRecognizedEntryId() {
        // A weak-evidence-only hit → cannot carry a suggestion → escalate. But we
        // DID recognize the topic, so the id rides along for the hand-off.
        let entries = [KBEntry(id: "KI-FU", category: .other, status: .open,
                               symptomKeywords: ["some unrelated phrase"],
                               corroboratingKeywords: ["frobnicate widget"],
                               userFacingWorkaround: "Try turning it off and on again please.",
                               confidenceThreshold: 0.1)]
        let result = classifier.classify(userText: "my frobnicate widget is broken", knowledgeBase: kb(entries))
        XCTAssertEqual(result.decision, .escalate)
        XCTAssertEqual(result.recognizedEntryId, "KI-FU")
    }

    func testGenuineNoMatch_hasNilRecognizedEntryId() {
        let entries = [KBEntry(id: "KI-FU", category: .other, status: .open,
                               symptomKeywords: ["frobnicate widget"],
                               userFacingWorkaround: "Try turning it off and on again please.",
                               confidenceThreshold: 0.1)]
        let result = classifier.classify(userText: "completely unrelated sentence", knowledgeBase: kb(entries))
        XCTAssertEqual(result.decision, .escalate)
        XCTAssertNil(result.recognizedEntryId, "a genuine no-match must not fabricate a recognized entry")
    }

    func testEscalateAnyway_confidentMatch_escalatesWithRecognition() {
        // Two regions → would normally suggest. escalate_anyway forces a human
        // hand-off carrying the recognized id instead of a can't-self-serve card.
        let entries = [KBEntry(id: "KI-ANY", category: .other, status: .open,
                               symptomKeywords: ["alpha", "beta"],
                               userFacingWorkaround: "This one always needs a person to look at it.",
                               confidenceThreshold: 0.1, escalateAnyway: true)]
        let result = classifier.classify(userText: "alpha beta", knowledgeBase: kb(entries))
        XCTAssertEqual(result.decision, .escalate, "escalate_anyway must not produce a suggest")
        XCTAssertEqual(result.recognizedEntryId, "KI-ANY")
    }

    func testEscalateAnywayFalse_confidentMatch_stillSuggests() {
        // Guard the negative: the default (escalate_anyway == false) still suggests.
        let entries = [KBEntry(id: "KI-OK", category: .other, status: .open,
                               symptomKeywords: ["alpha", "beta"],
                               userFacingWorkaround: "Here is the self-serve fix to try.",
                               confidenceThreshold: 0.1)]
        let result = classifier.classify(userText: "alpha beta", knowledgeBase: kb(entries))
        XCTAssertEqual(result.decision, .suggest(entryId: "KI-OK"))
    }

    // MARK: - Reducer: recognized escalate asks the entry's follow-up

    private func drive(_ r: ConversationReducer, category: KBCategory, text: String) -> ConversationState {
        var (state, _) = r.reduce(state: ConversationState(), action: .start)
        (state, _) = r.reduce(state: state, action: .userTappedCategory(category))
        (state, _) = r.reduce(state: state, action: .inputChanged(text))
        return r.reduce(state: state, action: .userSubmittedDescription).0
    }

    func testEscalate_recognizedTopic_asksItsTargetedFollowUp() {
        let entries = [KBEntry(id: "KI-FU", category: .other, status: .open,
                               symptomKeywords: ["frobnicate widget"],
                               userFacingWorkaround: "Try turning it off and on again please.",
                               escalationFollowUp: KBEscalationFollowUp(prompt: "Which widget model is it?"),
                               confidenceThreshold: 0.1,
                               // escalate_anyway = recognized confidently, but no
                               // safe self-serve fix. The strong-recognition
                               // escalation, which is exactly when the targeted
                               // question is warranted.
                               escalateAnyway: true)]
        let state = drive(reducer(entries), category: .other, text: "my frobnicate widget is broken")

        guard case .awaitingEscalationFollowUp(let prompt, _) = state.step else {
            return XCTFail("recognized-but-escalated topic must ask its follow-up; got \(state.step)")
        }
        XCTAssertEqual(prompt, "Which widget model is it?")
    }

    func testEscalate_genuineNoMatch_draftsWithoutAFollowUp() {
        let entries = [KBEntry(id: "KI-FU", category: .other, status: .open,
                               symptomKeywords: ["frobnicate widget"],
                               userFacingWorkaround: "Try turning it off and on again please.",
                               escalationFollowUp: KBEscalationFollowUp(prompt: "Which widget model is it?"),
                               confidenceThreshold: 0.1)]
        let state = drive(reducer(entries), category: .other, text: "totally unrelated problem here")

        if case .awaitingEscalationFollowUp = state.step {
            XCTFail("a novel no-match must not borrow an unrelated entry's follow-up")
        }
        if case .drafting = state.step {} else {
            XCTFail("expected a direct draft for a novel issue, got \(state.step)")
        }
    }

    // MARK: - Reducer: trust level shapes how a suggestion is spoken

    private func hedgeText() -> String { "This might be what's going on — take a look:" }

    func testSuggest_signalTrustEntry_hedgesBeforeTheCard() {
        let entries = [KBEntry(id: "KI-SIG", category: .other, status: .open,
                               symptomKeywords: ["alpha", "beta"],
                               userFacingWorkaround: "Here's a possible explanation to consider.",
                               confidenceThreshold: 0.1, trustLevel: .signal)]
        let state = drive(reducer(entries), category: .other, text: "alpha beta")

        let hedgeIdx = state.messages.firstIndex { if case .text(let t) = $0.kind { return t == self.hedgeText() }; return false }
        let cardIdx = state.messages.firstIndex { if case .kbMatch(let id) = $0.kind { return id == "KI-SIG" }; return false }
        XCTAssertNotNil(hedgeIdx, "a signal-trust entry must be hedged")
        XCTAssertNotNil(cardIdx)
        if let h = hedgeIdx, let c = cardIdx { XCTAssertLessThan(h, c, "hedge must precede the card") }
    }

    func testSuggest_authoritativeEntry_isSpokenDirectly() {
        let entries = [KBEntry(id: "KI-AUTH", category: .other, status: .open,
                               symptomKeywords: ["alpha", "beta"],
                               userFacingWorkaround: "This is the confirmed fix — do this.",
                               confidenceThreshold: 0.1, trustLevel: .authoritative)]
        let state = drive(reducer(entries), category: .other, text: "alpha beta")

        let hasHedge = state.messages.contains { if case .text(let t) = $0.kind { return t == self.hedgeText() }; return false }
        XCTAssertFalse(hasHedge, "an authoritative entry must not be hedged")
    }
}
