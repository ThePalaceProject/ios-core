import XCTest
@testable import TriageBotCore

/// PP-4846: after Discard → pick a different category → type, the Send arrow
/// intermittently stayed disabled. The report is "repro-first" — it did not
/// reproduce deterministically in the regression pass.
///
/// This suite pins the **reducer** side of that flow, which is the source of
/// truth the Send button's `disabled` predicate reads
/// (`!isFollowUpStep && state.inputText.trimmed.isEmpty`). If the reducer ever
/// left `inputText` empty or the step wrong after Discard→re-category→type, the
/// button would be legitimately (not racily) stuck — this proves it does not, so
/// the intermittent field report is localized to the SwiftUI TextField binding,
/// not the state machine.
final class StuckSendReproTests: XCTestCase {

    private func reducer() -> ConversationReducer {
        // An entry with NO escalationFollowUp → an escalating match drafts a
        // ticket directly (reaching the .drafting/preview step we then Discard).
        let entry = KBEntry(id: "KI-DRAFT", category: .audiobook, status: .open,
                            symptomKeywords: ["glitchy audio"],
                            userFacingWorkaround: "Please try re-downloading the title.",
                            confidenceThreshold: 0.1)
        return ConversationReducer(knowledgeBase: KnowledgeBase(
            catalog: KBCatalog(version: "test", updatedAt: "2026-07-20", entries: [entry])))
    }

    /// Send-enabled == the UI predicate: a non-follow-up composition step with a
    /// non-empty trimmed input.
    private func sendWouldBeEnabled(_ state: ConversationState) -> Bool {
        let composing: Bool
        switch state.step {
        case .awaitingDescription, .awaitingCategory, .awaitingFollowUp: composing = true
        default: composing = false
        }
        return composing && !state.inputText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    func testDiscardThenNewCategoryThenType_leavesSendEnabled() {
        let r = reducer()

        // Drive to a ticket preview (drafting).
        var (s, _) = r.reduce(state: ConversationState(), action: .start)
        (s, _) = r.reduce(state: s, action: .userTappedCategory(.audiobook))
        (s, _) = r.reduce(state: s, action: .inputChanged("my glitchy audio problem"))
        (s, _) = r.reduce(state: s, action: .userSubmittedDescription)
        guard case .drafting = s.step else {
            return XCTFail("expected a ticket preview (.drafting); got \(s.step)")
        }

        // Discard the preview.
        (s, _) = r.reduce(state: s, action: .userCancelledTicketSubmit)
        XCTAssertEqual(s.step, .awaitingCategory, "Discard must return to the category chooser")
        XCTAssertTrue(s.inputText.isEmpty, "Discard must leave the composer empty")
        XCTAssertFalse(sendWouldBeEnabled(s), "no text yet → Send stays disabled (correct)")

        // Pick a DIFFERENT category.
        (s, _) = r.reduce(state: s, action: .userTappedCategory(.reader))
        guard case .awaitingDescription(let category) = s.step else {
            return XCTFail("re-selecting a category must open a fresh description step; got \(s.step)")
        }
        XCTAssertEqual(category, .reader, "the newly tapped category must win")

        // Type a new description — Send MUST re-enable.
        (s, _) = r.reduce(state: s, action: .inputChanged("a totally different reader issue"))
        XCTAssertEqual(s.inputText, "a totally different reader issue",
                       "typing after Discard→re-category must update inputText")
        XCTAssertTrue(sendWouldBeEnabled(s),
                      "PP-4846: after Discard→new category→type, Send must be enabled at the reducer level")
    }

    /// Also guard the Start-over reset path (the other way back to the chooser).
    func testStartOverThenCategoryThenType_leavesSendEnabled() {
        let r = reducer()
        var (s, _) = r.reduce(state: ConversationState(), action: .start)
        (s, _) = r.reduce(state: s, action: .userTappedCategory(.audiobook))
        (s, _) = r.reduce(state: s, action: .inputChanged("stale text that should be cleared"))
        (s, _) = r.reduce(state: s, action: .userTappedStartOver)
        XCTAssertEqual(s.step, .awaitingCategory)
        XCTAssertTrue(s.inputText.isEmpty, "Start-over must clear any half-typed input")

        (s, _) = r.reduce(state: s, action: .userTappedCategory(.signin))
        (s, _) = r.reduce(state: s, action: .inputChanged("new signin question"))
        XCTAssertTrue(sendWouldBeEnabled(s), "Send must re-enable after Start-over→category→type")
    }
}
