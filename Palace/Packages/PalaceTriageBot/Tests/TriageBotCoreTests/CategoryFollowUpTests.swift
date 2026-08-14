import XCTest
@testable import TriageBotCore

/// No ticket should be filed blind.
///
/// Measured on 318 real tickets, 69% of escalations recognized nothing and so
/// asked nothing — support received "a patron reports a problem" plus
/// diagnostics. Matching cannot close that gap: 8% of complaints are under a
/// dozen words, and the catalog covers a fraction of the causes behind the rest.
/// A per-category question makes no claim about the cause; it asks the thing that
/// most often splits that category's clusters, which is safe precisely when we
/// know least.
final class CategoryFollowUpTests: XCTestCase {

    private func drive(_ r: ConversationReducer, _ cat: KBCategory, _ text: String) -> ConversationState {
        var (s, _) = r.reduce(state: ConversationState(), action: .start)
        (s, _) = r.reduce(state: s, action: .userTappedCategory(cat))
        (s, _) = r.reduce(state: s, action: .inputChanged(text))
        return r.reduce(state: s, action: .userSubmittedDescription).0
    }

    private func shipped() throws -> ConversationReducer {
        ConversationReducer(knowledgeBase: KnowledgeBase(catalog: try BundledCatalogSource.loadCatalogSync()))
    }

    private func prompt(_ s: ConversationState) -> String? {
        if case .awaitingEscalationFollowUp(let p, _) = s.step { return p }
        return nil
    }

    /// The exact input class that no keyword can ever reach.
    ///
    /// The shape changed when remedy ladders shipped: such a complaint is now
    /// offered the category's ladder FIRST, and the catch-all question arrives
    /// when the ladder is exhausted. The invariant that matters is unchanged —
    /// this patron is never filed blind — so the test walks the whole path
    /// rather than asserting the first screen.
    func testUnrecognizableComplaint_isOfferedRemediesThenStillAsked() throws {
        let r = try shipped()
        var state = drive(r, .signin, "Cant sign in")

        guard case .matched(let offered) = state.step, offered.hasPrefix("GF-") else {
            return XCTFail("expected the sign-in remedy ladder; got \(state.step)")
        }
        state = r.reduce(state: state, action: .userTappedStartGuidedFlow(entryId: offered)).0
        guard case .guidedStep(_, _, _, _) = state.step else {
            return XCTFail("expected a rung; got \(state.step)")
        }
        // Exhaust every rung.
        var guard_ = 0
        while case .guidedStep(let e, let i, _, _) = state.step, guard_ < 5 {
            let stepId = r.knowledgeBase.entry(id: e)?.userFacingSteps?[i].id ?? ""
            state = r.reduce(state: state, action: .userConfirmedStepDidNotResolve(stepId: stepId)).0
            guard_ += 1
        }
        let asked = try XCTUnwrap(prompt(state), "a blank ticket is the worst outcome this bot can produce")
        XCTAssertTrue(asked.contains("library gave you") || asked.contains("created inside"),
                      "sign-in's catch-all must still split library-issued from app-created cards: \(asked)")
    }

    /// Every category has one, so no route to a ticket is blind.
    func testEveryCategoryHasACatchAllQuestion() throws {
        let kb = KnowledgeBase(catalog: try BundledCatalogSource.loadCatalogSync())
        for category in KBCategory.allCases {
            XCTAssertNotNil(kb.categoryFollowUp(for: category),
                            "\(category.rawValue) can still file a ticket with no question asked")
        }
    }

    /// A recognized entry's own question is more specific and must win.
    func testRecognizedEntry_prefersItsOwnQuestionOverTheCatchAll() {
        let entry = KBEntry(id: "K", category: .audiobook, status: .open,
                            symptomKeywords: ["alpha thing"],
                            userFacingWorkaround: "Fix it.",
                            escalationFollowUp: KBEscalationFollowUp(prompt: "Which title is doing this?"),
                            confidenceThreshold: 0.1, escalateAnyway: true)
        let kb = KBCatalog(version: "t", updatedAt: "x", entries: [entry],
                           categoryFollowUps: ["audiobook": KBEscalationFollowUp(prompt: "Generic question?")])
        let state = drive(ConversationReducer(knowledgeBase: KnowledgeBase(catalog: kb)),
                          .audiobook, "the alpha thing is broken")
        XCTAssertEqual(prompt(state), "Which title is doing this?")
    }

    /// The catch-all must NOT override the deliberate silence on weak recognition:
    /// a bug-presuming entry question is withheld there, and the category question
    /// — which presumes nothing — is the right thing to ask instead.
    /// Weak recognition is now also offered the ladder before any question. What
    /// must never happen is unchanged: the entry's bug-presuming question must
    /// not be asked off a lone generic word.
    func testWeakRecognition_isOfferedTheLadder_andNeverThePresumingQuestion() throws {
        let state = drive(try shipped(), .audiobook, "the app crashes when I open it")
        if case .matched(let id) = state.step {
            XCTAssertTrue(id.hasPrefix("GF-"), "weak recognition must not present a diagnosis: \(id)")
        }
        if let asked = prompt(state) {
            XCTAssertFalse(asked.lowercased().contains("car "),
                           "must not ask the CarPlay question off a weak match: \(asked)")
        }
    }
}
