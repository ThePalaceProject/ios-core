import XCTest
@testable import TriageBotCore

/// PP-4847: the reducer owns a single "Before I file this —" preamble on the
/// escalation follow-up question. Corpus prompts must therefore be bare
/// questions — a prompt that carries its own preamble renders doubled
/// ("Before I file this — Before I send this to support — which title…").
final class EscalationPreambleTests: XCTestCase {

    /// Corpus lint: no follow-up prompt may carry its own "Before I file/send/
    /// escalate" preamble. Loads the real shipped catalog.
    func testCorpusFollowUpPrompts_carryNoOwnPreamble() throws {
        let entries = try BundledCatalogSource.loadCatalogSync().entries
        let banned = ["before i file", "before i send", "before i escalate"]
        var offenders: [String] = []
        for entry in entries {
            guard let prompt = entry.escalationFollowUp?.prompt else { continue }
            let lower = prompt.lowercased()
            if banned.contains(where: { lower.contains($0) }) {
                offenders.append("\(entry.id): \(prompt)")
            }
        }
        XCTAssertTrue(offenders.isEmpty,
            "these follow-up prompts carry their own preamble; the reducer adds one, so they render doubled: \(offenders)")
    }

    private func drive(_ r: ConversationReducer, category: KBCategory, text: String) -> ConversationState {
        var (state, _) = r.reduce(state: ConversationState(), action: .start)
        (state, _) = r.reduce(state: state, action: .userTappedCategory(category))
        (state, _) = r.reduce(state: state, action: .inputChanged(text))
        return r.reduce(state: state, action: .userSubmittedDescription).0
    }

    /// The reducer renders exactly one preamble, sitting directly in front of the
    /// bare-question prompt.
    func testReducer_followUpMessage_hasExactlyOnePreamble() {
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
        let r = ConversationReducer(knowledgeBase: KnowledgeBase(
            catalog: KBCatalog(version: "test", updatedAt: "2026-07-20", entries: entries)))
        let state = drive(r, category: .other, text: "my frobnicate widget is broken")

        let followUp = state.messages.compactMap { message -> String? in
            if case .text(let t) = message.kind, t.contains("Which widget model is it?") { return t }
            return nil
        }.first

        guard let text = followUp else {
            return XCTFail("expected a follow-up message containing the prompt; got \(state.messages)")
        }
        let preambleCount = text.components(separatedBy: "Before I file this —").count - 1
        XCTAssertEqual(preambleCount, 1, "expected exactly one preamble, got \(preambleCount): \(text)")
        XCTAssertTrue(text.contains("Before I file this — Which widget model is it?"),
                      "the single preamble must sit directly in front of the bare question: \(text)")
    }
}
