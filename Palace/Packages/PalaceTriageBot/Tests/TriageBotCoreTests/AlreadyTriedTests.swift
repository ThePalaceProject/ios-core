import XCTest
@testable import TriageBotCore

/// 10% of real tickets open by listing what the patron already did — "They've
/// reinstalled the app, rebooted their phone", "I have uninstalled and
/// redownloaded several times". Walking that patron into a flow whose first step
/// is "reinstall the app" is how the bot loses their trust in one move.
final class AlreadyTriedTests: XCTestCase {

    private let detector = RemedyDetector()

    // MARK: - Detection

    func testDetectsRemediesFromRealTicketWording() {
        // Verbatim shapes from the mined corpus.
        XCTAssertEqual(detector.alreadyTried(in: "They've reinstalled the app, rebooted their phone, and it's not working."),
                       [.reinstall, .restartDevice])
        XCTAssertEqual(detector.alreadyTried(in: "I have gone on and off wifi, I have logged out of the app"),
                       [.toggleNetwork])
        XCTAssertEqual(detector.alreadyTried(in: "I've tried on different devices. I've turned it in and checked it back out."),
                       [.otherDevice])
    }

    /// Conservative by design: a false positive SKIPS a step the patron may need,
    /// which costs them the fix. Mentioning a remedy is not claiming to have done
    /// it.
    func testMentioningARemedyIsNotHavingTriedIt() {
        XCTAssertTrue(detector.alreadyTried(in: "should I reinstall the app?").isEmpty)
        XCTAssertTrue(detector.alreadyTried(in: "do I need to sign out and back in").isEmpty)
        XCTAssertTrue(detector.alreadyTried(in: "my audiobook won't play").isEmpty)
    }

    /// The two remedies a generic ladder would offer that the detector could not
    /// see. Without these, a patron who wrote "I pulled down to refresh and
    /// nothing happened" would be told to pull down to refresh — the exact
    /// not-listening defect this work exists to remove, reintroduced on the new
    /// surface.
    func testDetectsTheRemediesAGenericLadderWouldOffer() {
        XCTAssertTrue(detector.alreadyTried(in: "I pulled down to refresh and nothing changed").contains(.pullToRefresh))
        XCTAssertTrue(detector.alreadyTried(in: "I switched to my other library and it is the same").contains(.switchLibrary))
    }

    /// Cost tiers are what let the ladder put destructive remedies last. Asserted
    /// through behaviour that depends on them, not as a constant echo: the two
    /// remedies that destroy downloaded content must not sit in the free tier.
    func testDestructiveRemediesAreNotClassifiedAsFree() {
        XCTAssertEqual(Remedy.reinstall.costTier, .destructive,
                       "reinstall deletes every downloaded book")
        XCTAssertEqual(Remedy.signOutIn.costTier, .destructive,
                       "signing out removes that library's downloaded content, and a patron who cannot sign back in is stranded")
        XCTAssertEqual(Remedy.pullToRefresh.costTier, .free)
    }

    /// A blanket claim is real information for support but cannot skip anything —
    /// skipping every step on "tried everything" strands the patron.
    func testBlanketClaimIsReportedButSkipsNothing() {
        XCTAssertTrue(detector.claimsExhaustedEffort(in: "I have done everything I can to get these books to play"))
        XCTAssertTrue(detector.alreadyTried(in: "I have done everything I can to get these books to play").isEmpty)
    }

    // MARK: - Guided flow

    private func drive(_ text: String) -> ConversationState {
        let entry = KBEntry(
            id: "K", category: .audiobook, status: .open,
            symptomKeywords: ["alpha thing"],
            userFacingWorkaround: "Fix it.",
            // Destructive rungs may not come first, in any entry kind — so the
            // free step leads and the reinstall follows. The test still turns on
            // whether an already-tried rung is skipped.
            userFacingSteps: [
                KBStep(id: "s1", instruction: "Tap the title again.", check: "Better?", remedy: .reopenTitle),
                KBStep(id: "s2", instruction: "Delete and reinstall Palace.", check: "Better?", remedy: .reinstall),
            ],
            confidenceThreshold: 0.1)
        let r = ConversationReducer(knowledgeBase: KnowledgeBase(
            catalog: KBCatalog(version: "t", updatedAt: "x", entries: [entry])))
        var (s, _) = r.reduce(state: ConversationState(), action: .start)
        (s, _) = r.reduce(state: s, action: .userTappedCategory(.audiobook))
        (s, _) = r.reduce(state: s, action: .inputChanged(text))
        (s, _) = r.reduce(state: s, action: .userSubmittedDescription)
        return r.reduce(state: s, action: .userTappedStartGuidedFlow(entryId: "K")).0
    }

    private func texts(_ s: ConversationState) -> [String] {
        s.messages.compactMap { if case .text(let t) = $0.kind { return t }; return nil }
    }

    func testGuidedFlow_startsAfterTheStepTheyAlreadyDid() {
        let state = drive("the alpha thing is broken, I already closed and reopened it")
        guard case .guidedStep(_, let index, _, _) = state.step else {
            return XCTFail("expected a guided step; got \(state.step)")
        }
        XCTAssertEqual(index, 1, "must start at the step they have NOT tried")
        XCTAssertTrue(texts(state).contains { $0.contains("already tried reopening the title") },
                      "skipping silently looks like steps going missing: \(texts(state))")
    }

    func testGuidedFlow_withoutThatClaim_startsAtTheBeginning() {
        let state = drive("the alpha thing is broken")
        guard case .guidedStep(_, let index, _, _) = state.step else {
            return XCTFail("expected a guided step; got \(state.step)")
        }
        XCTAssertEqual(index, 0)
    }

    /// Found by dogfooding: when every step is skipped the patron attempted
    /// nothing, so the escalation must not open by telling them their attempt
    /// failed. The reducer tests assert state rather than prose, which is exactly
    /// why this survived them.
    func testAllStepsSkipped_doesNotClaimAnAttemptFailed() {
        let entry = KBEntry(
            id: "K", category: .audiobook, status: .open,
            symptomKeywords: ["alpha thing"],
            userFacingWorkaround: "Fix it.",
            userFacingSteps: [
                KBStep(id: "s1", instruction: "Tap the title again.", check: "Better?", remedy: .reopenTitle),
            ],
            escalationFollowUp: KBEscalationFollowUp(prompt: "Which title is doing this?"),
            confidenceThreshold: 0.1)
        let r = ConversationReducer(knowledgeBase: KnowledgeBase(
            catalog: KBCatalog(version: "t", updatedAt: "x", entries: [entry])))
        var (s, _) = r.reduce(state: ConversationState(), action: .start)
        (s, _) = r.reduce(state: s, action: .userTappedCategory(.audiobook))
        (s, _) = r.reduce(state: s, action: .inputChanged("the alpha thing is broken, I already closed and reopened it"))
        (s, _) = r.reduce(state: s, action: .userSubmittedDescription)
        (s, _) = r.reduce(state: s, action: .userTappedStartGuidedFlow(entryId: "K"))

        let said = s.messages.compactMap { if case .text(let t) = $0.kind { return t }; return nil }
        XCTAssertFalse(said.contains { $0.contains("That didn't resolve it") },
                       "nothing was attempted — do not assert a failed attempt: \(said)")
        XCTAssertTrue(said.contains { $0.contains("Which title is doing this?") },
                      "the entry's question should still be asked: \(said)")
    }

    /// Skipping must apply while ADVANCING too, not only when the flow opens.
    /// A mutant that ignored already-tried on advance survived the first version
    /// of this suite — every step boundary is a place to re-check, not just the
    /// first.
    func testGuidedFlow_skipsAnAlreadyTriedStepMidFlow() {
        let entry = KBEntry(
            id: "K", category: .audiobook, status: .open,
            symptomKeywords: ["alpha thing"],
            userFacingWorkaround: "Fix it.",
            userFacingSteps: [
                KBStep(id: "s1", instruction: "Tap the title again.", check: "Better?", remedy: .reopenTitle),
                KBStep(id: "s2", instruction: "Delete and reinstall Palace.", check: "Better?", remedy: .reinstall),
                KBStep(id: "s3", instruction: "Sign out and back in.", check: "Better?", remedy: .signOutIn),
            ],
            confidenceThreshold: 0.1)
        let r = ConversationReducer(knowledgeBase: KnowledgeBase(
            catalog: KBCatalog(version: "t", updatedAt: "x", entries: [entry])))
        var (s, _) = r.reduce(state: ConversationState(), action: .start)
        (s, _) = r.reduce(state: s, action: .userTappedCategory(.audiobook))
        // Claims the MIDDLE rung, so the flow opens at 0 and must jump over 1.
        (s, _) = r.reduce(state: s, action: .inputChanged("the alpha thing is broken, I already reinstalled the app"))
        (s, _) = r.reduce(state: s, action: .userSubmittedDescription)
        (s, _) = r.reduce(state: s, action: .userTappedStartGuidedFlow(entryId: "K"))
        guard case .guidedStep(_, let first, _, _) = s.step, first == 0 else {
            return XCTFail("expected to open at step 0; got \(s.step)")
        }
        (s, _) = r.reduce(state: s, action: .userConfirmedStepDidNotResolve(stepId: "s1"))
        guard case .guidedStep(_, let next, _, _) = s.step else {
            return XCTFail("expected another step; got \(s.step)")
        }
        XCTAssertEqual(next, 2, "must jump over the reinstall step they already did")
    }

    /// If they have done everything the entry would suggest, opening an empty
    /// flow wastes their time — escalate with the trace instead.
    func testGuidedFlow_whenEveryStepIsAlreadyTried_escalatesInstead() {
        let state = drive("the alpha thing is broken. I closed and reopened it and I reinstalled the app.")
        if case .guidedStep = state.step {
            XCTFail("opened a flow with nothing left to try")
        }
    }
}
