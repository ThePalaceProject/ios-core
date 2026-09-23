import XCTest
@testable import TriageBotCore

/// What a filed ticket tells support.
///
/// The bot's job is to resolve the problem OR hand support a better-identified
/// one than the patron would have emailed unaided. The second half is measurable:
/// a ticket is better identified when it carries something the raw email would
/// not have — the entry we recognised, the question we asked, or the remedies the
/// patron had already tried.
///
/// Two of those were being computed and then dropped on the floor.
final class TicketIdentificationTests: XCTestCase {

    private func kb() -> KnowledgeBase {
        let weak = KBEntry(
            id: "KI-WEAK", category: .download, status: .open,
            symptomKeywords: ["a phrase nobody types"],
            corroboratingKeywords: ["download"],
            userFacingWorkaround: "Check your connection.",
            confidenceThreshold: 0.1)
        let ladder = KBEntry(
            id: "GF-download", category: .download, kind: .genericFlow,
            symptomKeywords: [],
            userFacingWorkaround: "A few things to try.",
            userFacingSteps: [KBStep(id: "g1", instruction: "Try it.", check: "Any change?",
                                     remedy: .pullToRefresh)])
        return KnowledgeBase(catalog: KBCatalog(version: "t", updatedAt: "x", entries: [weak, ladder]))
    }

    private func drive(_ text: String, then action: ConversationAction?) -> ConversationState {
        let r = ConversationReducer(knowledgeBase: kb())
        var (s, _) = r.reduce(state: ConversationState(), action: .start)
        (s, _) = r.reduce(state: s, action: .userTappedCategory(.download))
        (s, _) = r.reduce(state: s, action: .inputChanged(text))
        (s, _) = r.reduce(state: s, action: .userSubmittedDescription)
        if let action { (s, _) = r.reduce(state: s, action: action) }
        return s
    }

    private func draft(_ s: ConversationState) -> TicketDraft? {
        switch s.step {
        case .drafting(let d): return d
        case .awaitingEscalationFollowUp(_, let d): return d
        default: return nil
        }
    }

    /// Declining the ladder is the third exit from it, and the only one that was
    /// not scoping the ticket. A patron who taps "just file a ticket" got
    /// `GF-download` — which tells a triager the bot had no idea, something the
    /// absence of an answer already tells them — while the weak recognition sat
    /// unused in `lastClassification`.
    func testFileAnywayFromLadder_scopesToTheRecognizedEntry() throws {
        let state = drive("my download is stuck", then: .userTappedFileTicketAnyway)
        let d = try XCTUnwrap(draft(state), "expected a draft; got \(state.step)")
        XCTAssertEqual(d.matchedEntryId, "KI-WEAK",
                       "the recognised entry must survive all three ladder exits, not two")
        XCTAssertFalse(d.helpspotTags.contains("triage-bot-known-issue"),
                       "a generic ladder is not a known issue and must not be tagged as one")
    }

    /// The detector reads "I already reinstalled" to skip a step, and then the
    /// fact is discarded. Support re-reads the free text to learn something the
    /// bot had already parsed.
    func testTicketCarriesTheRemediesThePatronSaidTheyTried() throws {
        let state = drive("my download is stuck, I deleted the app and reinstalled it twice",
                          then: .userTappedFileTicketAnyway)
        let d = try XCTUnwrap(draft(state))
        XCTAssertTrue(d.alreadyTried.contains(.reinstall),
                      "support should not have to re-read what the bot already parsed")
    }

    /// A blanket "tried everything" suppresses the ladder. That decision is worth
    /// telling support, because it says the patron has already spent effort.
    func testTicketRecordsABlanketExhaustedEffortClaim() throws {
        let state = drive("my download is stuck and I have tried everything, nothing works",
                          then: .userTappedFileTicketAnyway)
        let d = try XCTUnwrap(draft(state))
        XCTAssertTrue(d.claimsExhaustedEffort)
    }
}
