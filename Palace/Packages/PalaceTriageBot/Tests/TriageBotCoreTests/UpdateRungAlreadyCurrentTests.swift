import XCTest
@testable import TriageBotCore

/// A patron already on the newest build has no honest answer to "check the App
/// Store for an update — did that fix it?". The only available button is "No
/// change", and the trace then records that updating the app was tried and
/// failed. It was not tried at all.
///
/// That matters more than tidiness. `ResolutionTrace` is the input to the
/// pre-registered re-ranking rule for rung ordering (Wilson lower bound of a
/// rung's resolution rate, once it has 50 recorded attempts). Every
/// already-current patron pushed through the "no change" branch deflates
/// `updateApp`'s measured rate with an attempt that never happened, so the first
/// time that rule runs it will demote the rung for the wrong reason.
///
/// The version gate (`latest_known_app_version`) skips the rung for patrons at
/// or past the newest known version, which handles the common case. This is the
/// backstop for when that gate is stale — the design deliberately lets it decay
/// to "offer the rung", and this makes that decay non-corrupting.
final class UpdateRungAlreadyCurrentTests: XCTestCase {

    private func ladder(alreadyCurrentOutcome: KBStepResponse.Outcome?) -> KBEntry {
        var responses: [KBStepResponse] = [
            .init(label: "It plays now", outcome: .resolved, diagnostic: "t.resolved"),
            .init(label: "No change", outcome: .advance, diagnostic: "t.no_change"),
        ]
        if let outcome = alreadyCurrentOutcome {
            responses.append(.init(label: "Already up to date",
                                   outcome: outcome,
                                   diagnostic: "t.already_current"))
        }
        return KBEntry(
            id: "GF-t", category: .audiobook, kind: .genericFlow,
            symptomKeywords: [],
            userFacingWorkaround: "Let's try a couple of things.",
            userFacingSteps: [
                KBStep(id: "s1", instruction: "Check the App Store for a Palace update.",
                       check: "Does it play now?", responses: responses,
                       diagnostic: "t.s1", remedy: .updateApp),
                KBStep(id: "s2", instruction: "Go back to My Books and tap Listen again.",
                       check: "Any better?", diagnostic: "t.s2", remedy: .reopenTitle),
            ],
            confidenceThreshold: 0.1)
    }

    /// Drives to the update rung and answers it. `responseIndex` indexes the
    /// step's `responses`.
    private func answerFirstRung(_ entry: KBEntry, responseIndex: Int) -> ConversationState {
        let r = ConversationReducer(knowledgeBase: KnowledgeBase(
            catalog: KBCatalog(version: "t", updatedAt: "x", entries: [entry])))
        var (s, _) = r.reduce(state: ConversationState(), action: .start)
        // No app version in context, so the version gate cannot skip the rung —
        // "unknown offers the rung" is the documented conservative behaviour.
        (s, _) = r.reduce(state: s, action: .userTappedCategory(.audiobook))
        (s, _) = r.reduce(state: s, action: .userTappedStartGuidedFlow(entryId: "GF-t"))
        guard case .guidedStep(_, let i, _, _) = s.step, i == 0 else { return s }
        return r.reduce(state: s,
                        action: .userSelectedStepResponse(stepId: "s1", responseIndex: responseIndex)).0
    }

    private func attempts(_ s: ConversationState) -> [StepAttempt] {
        if case .guidedStep(_, _, _, let a) = s.step { return a }
        return []
    }

    // MARK: - The defect

    /// The whole point: it must still ADVANCE (the patron's problem is unsolved,
    /// so keep helping) while NOT recording a failed attempt.
    func testAlreadyCurrent_advancesWithoutRecordingAFailedAttempt() {
        let state = answerFirstRung(ladder(alreadyCurrentOutcome: .notApplicable), responseIndex: 2)

        guard case .guidedStep(_, let index, _, _) = state.step else {
            return XCTFail("must keep helping — the problem is not solved: \(state.step)")
        }
        XCTAssertEqual(index, 1, "should move on to the next rung")

        let recorded = attempts(state).filter { $0.stepId == "s1" }
        XCTAssertEqual(recorded.map(\.outcome), [.notApplicable],
                       "the patron never updated — recording didNotResolve would deflate the "
                       + "rung's resolution rate with an attempt that did not happen")
    }

    /// The contrast case, and the guard against "fixing" this by making every
    /// advance not-applicable. A patron who genuinely updated and saw no change
    /// HAS tried the remedy, and that must still count against it.
    func testGenuineNoChange_stillRecordsAFailedAttempt() {
        let state = answerFirstRung(ladder(alreadyCurrentOutcome: .notApplicable), responseIndex: 1)

        let recorded = attempts(state).filter { $0.stepId == "s1" }
        XCTAssertEqual(recorded.map(\.outcome), [.didNotResolve],
                       "they updated and it did not help — that is a real failed attempt")
    }

    /// `notApplicable` must not leak into the resolved path either: it is an
    /// absence of an attempt, not a success.
    func testAlreadyCurrent_isNotCountedAsAResolution() {
        let state = answerFirstRung(ladder(alreadyCurrentOutcome: .notApplicable), responseIndex: 2)
        XCTAssertFalse(attempts(state).contains { $0.outcome == .resolved },
                       "not-applicable is neither a success nor a failure")
    }

    // MARK: - The catalog actually has to offer it

    /// The behaviour above is unreachable if no shipped rung offers the button.
    /// This is the half that was missing when the mechanism was first described:
    /// the reducer change is inert without catalog copy, exactly like the
    /// version gate that shipped without `latest_known_app_version` authored.
    func testEveryUpdateRungInAGenericFlowOffersAnAlreadyCurrentEscape() throws {
        let catalog = try BundledCatalogSource.loadCatalogSync()
        var missing: [String] = []
        for entry in catalog.entries where (entry.kind ?? .knownIssue) == .genericFlow {
            for step in entry.userFacingSteps ?? [] where step.remedy == .updateApp {
                let hasEscape = (step.responses ?? []).contains { $0.outcome == .notApplicable }
                if !hasEscape { missing.append("\(entry.id)/\(step.id)") }
            }
        }
        XCTAssertTrue(missing.isEmpty,
                      "these update rungs force an already-current patron to answer "
                      + "\"no change\", which the trace records as a failed attempt: \(missing)")
    }

    /// Anti-vacuity: if ladders stop tagging rungs with `updateApp`, the test
    /// above passes over an empty set and silently stops guarding anything.
    func testTheCatalogStillHasUpdateRungsToGuard() throws {
        let catalog = try BundledCatalogSource.loadCatalogSync()
        let rungs = catalog.entries
            .filter { ($0.kind ?? .knownIssue) == .genericFlow }
            .flatMap { $0.userFacingSteps ?? [] }
            .filter { $0.remedy == .updateApp }
        XCTAssertGreaterThanOrEqual(rungs.count, 3,
                                    "the guarantee above is vacuous without update rungs to check")
    }
}
