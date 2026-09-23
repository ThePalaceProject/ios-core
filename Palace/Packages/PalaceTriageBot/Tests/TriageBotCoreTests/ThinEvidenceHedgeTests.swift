import XCTest
@testable import TriageBotCore

/// A suggestion built on ONE matched concept is offered as a question; one built
/// on two or more is stated. The near-miss corpus shows single-concept matches
/// are where real misroutes live, so the cost of being wrong there should be a
/// tap, not a patron following instructions for a bug they do not have.
final class ThinEvidenceHedgeTests: XCTestCase {

    private func drive(_ r: ConversationReducer, _ cat: KBCategory, _ text: String) -> ConversationState {
        var (s, _) = r.reduce(state: ConversationState(), action: .start)
        (s, _) = r.reduce(state: s, action: .userTappedCategory(cat))
        (s, _) = r.reduce(state: s, action: .inputChanged(text))
        return r.reduce(state: s, action: .userSubmittedDescription).0
    }

    private func reducer(_ entries: [KBEntry]) -> ConversationReducer {
        ConversationReducer(knowledgeBase: KnowledgeBase(
            catalog: KBCatalog(version: "t", updatedAt: "2026-07-20", entries: entries)))
    }

    private var entry: KBEntry {
        KBEntry(id: "K", category: .other, status: .open,
                symptomKeywords: ["alpha thing", "beta thing"],
                userFacingWorkaround: "Do the fix.", confidenceThreshold: 0.1)
    }

    private func hedgeText(_ state: ConversationState) -> String? {
        state.messages.compactMap { m -> String? in
            if case .text(let t) = m.kind, t.contains("does that match what you're seeing?") { return t }
            return nil
        }.first
    }

    func testOneMatchedConcept_isOfferedAsAQuestion() {
        let state = drive(reducer([entry]), .other, "I have the alpha thing")
        XCTAssertEqual(state.step, .matched(entryId: "K"), "one strong concept still suggests")
        XCTAssertNotNil(hedgeText(state), "a one-concept match must be hedged, not asserted")
    }

    func testTwoMatchedConcepts_areStatedPlainly() {
        let state = drive(reducer([entry]), .other, "I have the alpha thing and also the beta thing")
        XCTAssertEqual(state.step, .matched(entryId: "K"))
        XCTAssertNil(hedgeText(state), "two distinct concepts is not a guess — do not hedge")
    }

    /// The hedge must not silently replace the workaround: the patron still gets
    /// the KB card, just introduced as a question.
    func testHedgedMatch_stillShowsTheWorkaroundCard() {
        let state = drive(reducer([entry]), .other, "I have the alpha thing")
        let hasCard = state.messages.contains { if case .kbMatch(let id) = $0.kind { return id == "K" }; return false }
        XCTAssertTrue(hasCard, "hedging changes the framing, not whether help is offered")
    }
}
