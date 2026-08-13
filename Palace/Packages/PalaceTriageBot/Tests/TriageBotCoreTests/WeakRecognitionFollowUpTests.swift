import XCTest
@testable import TriageBotCore

/// Escalation asks the recognized entry's targeted follow-up before filing. That
/// question is only a good question when we actually recognized the problem.
///
/// Every targeted follow-up in the catalog PRESUMES its entry's bug — "What car
/// model + year are you using, and is it wired CarPlay or wireless?", "Which
/// library are you trying to add?". Asked off a strong match those are excellent
/// triage. Asked off a lone generic word they are baffling: a patron who wrote
/// "the app crashes when I open it" and has never opened CarPlay gets interrogated
/// about their car.
///
/// So recognition is split by strength:
///   - ticket SCOPING happens on any recognition, strong or weak. It is support-
///     facing metadata the patron never sees, and a hint costs a triager nothing.
///   - the targeted QUESTION is asked only on strong recognition. On weak-only
///     evidence the bot files the scoped ticket without pretending to know which
///     bug this is.
final class WeakRecognitionFollowUpTests: XCTestCase {

    private func drive(_ r: ConversationReducer, category: KBCategory, text: String) -> ConversationState {
        var (state, _) = r.reduce(state: ConversationState(), action: .start)
        (state, _) = r.reduce(state: state, action: .userTappedCategory(category))
        (state, _) = r.reduce(state: state, action: .inputChanged(text))
        return r.reduce(state: state, action: .userSubmittedDescription).0
    }

    private func shippedReducer() throws -> ConversationReducer {
        ConversationReducer(knowledgeBase: KnowledgeBase(catalog: try BundledCatalogSource.loadCatalogSync()))
    }

    /// The defect, against the real shipped catalog: a generic crash report must
    /// not be asked a CarPlay-specific question.
    func testGenericCrash_isNotAskedTheCarPlayQuestion() throws {
        let state = drive(try shippedReducer(), category: .audiobook, text: "the app crashes when I open it")

        if case .awaitingEscalationFollowUp(let prompt, _) = state.step {
            XCTFail("""
                a lone weak-keyword match must not ask a bug-specific question; \
                patron said "the app crashes when I open it" and was asked: "\(prompt)"
                """)
        }
    }

    /// Same shape, different entry: "my bookshelf looks empty" overlaps KI-004
    /// only on the weak word "bookshelf" and must not be asked which library the
    /// patron is trying to add — they never said they were adding one.
    func testGenericEmptyShelf_isNotAskedWhichLibraryToAdd() throws {
        let state = drive(try shippedReducer(), category: .library, text: "my bookshelf looks empty")

        if case .awaitingEscalationFollowUp(let prompt, _) = state.step {
            XCTFail("""
                a lone weak-keyword match must not ask a bug-specific question; \
                patron said "my bookshelf looks empty" and was asked: "\(prompt)"
                """)
        }
    }

    /// The other side of the contract — this must NOT regress into silence. A
    /// STRONG match that still escalates (an `escalate_anyway` entry, or a
    /// low-confidence-but-strong hit) is exactly when the targeted question earns
    /// its place, so it must still be asked.
    func testStrongRecognition_stillAsksItsTargetedFollowUp() {
        let entry = KBEntry(
            id: "KI-STRONG", category: .other, status: .open,
            symptomKeywords: ["frobnicate widget"],
            userFacingWorkaround: "Try turning it off and on again please.",
            escalationFollowUp: KBEscalationFollowUp(prompt: "Which widget model is it?"),
            confidenceThreshold: 0.1,
            // escalate_anyway: recognized AND confident, but no safe self-serve fix.
            // The canonical strong-recognition escalation.
            escalateAnyway: true
        )
        let reducer = ConversationReducer(knowledgeBase: KnowledgeBase(
            catalog: KBCatalog(version: "test", updatedAt: "2026-07-20", entries: [entry])))

        let state = drive(reducer, category: .other, text: "my frobnicate widget is broken")

        guard case .awaitingEscalationFollowUp(let prompt, _) = state.step else {
            return XCTFail("a strong recognition must still ask its targeted follow-up; got \(state.step)")
        }
        XCTAssertTrue(prompt.contains("Which widget model is it?"), "got: \(prompt)")
    }

    /// Weak recognition still SCOPES the ticket even though it asks nothing —
    /// that is the "triage whenever possible" half. Support gets a hint; the
    /// patron gets no baffling question.
    func testWeakRecognition_stillScopesTheTicketForSupport() throws {
        let result = LocalClassifier().classify(
            userText: "the app crashes when I open it",
            category: .audiobook,
            context: nil,
            knowledgeBase: KnowledgeBase(catalog: try BundledCatalogSource.loadCatalogSync())
        )
        XCTAssertEqual(result.decision, .escalate)
        XCTAssertEqual(result.recognizedEntryId, "KI-2026-005-carplay-sigabrt",
                       "weak evidence must still tag the ticket so support gets the hint")
        XCTAssertFalse(result.recognitionIsStrong,
                       "…but it must be marked weak so the reducer withholds the targeted question")
    }
}
