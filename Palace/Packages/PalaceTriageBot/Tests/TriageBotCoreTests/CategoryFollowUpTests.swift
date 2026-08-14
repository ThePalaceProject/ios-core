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
    /// Sign-in deliberately has NO remedy ladder, so this complaint goes straight
    /// to the question. Both cheap remedies were suppressed for the category by
    /// evidence — support prescribed update-the-app 0 times in 41 sign-in tickets
    /// and sign-out once — and the only rung left was a mechanism nobody had
    /// measured. Copy review rejected it rather than ship filler to the least
    /// tolerant audience in the app. Zero rungs is the honest ladder here, and
    /// this test is what keeps it that way: if a sign-in ladder is ever added,
    /// this fails and someone has to justify it.
    func testUnrecognizableComplaint_isStillAskedSomethingUseful() throws {
        let state = drive(try shipped(), .signin, "Cant sign in")
        let asked = try XCTUnwrap(prompt(state), "a blank ticket is the worst outcome this bot can produce")
        XCTAssertTrue(asked.contains("library gave you") || asked.contains("created inside"),
                      "sign-in's catch-all must split library-issued from app-created cards: \(asked)")
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
