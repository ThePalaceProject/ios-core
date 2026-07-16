import XCTest
@testable import TriageBotCore

/// Pins the "telemetry carries no free text" contract: every parameter key the
/// reducer emits is one of the enumerable ``TelemetryParameterKey`` cases (an
/// id / count / enum), and the enforcement filter drops anything that is not.
final class TelemetryContractTests: XCTestCase {

    /// Records every event handed to the sink, exactly as the production sink
    /// would receive it.
    private final class SpyTelemetrySink: TelemetrySink, @unchecked Sendable {
        private(set) var events: [TelemetryEvent] = []
        func emit(_ event: TelemetryEvent) { events.append(event) }
    }

    /// Single-entry audiobook KB — the confident-match path (entry_id +
    /// confidence) plus the category and ticket-submitted keys.
    private func makeReducer() -> ConversationReducer {
        let entries = [
            KBEntry(
                id: "KI-2026-001-audiobook-first-open-hang",
                category: .audiobook,
                status: .open,
                fixedInVersion: "3.2.0",
                symptomKeywords: ["audiobook", "won't play", "spinning", "first time", "hangs"],
                distributorFilter: ["palace_marketplace"],
                userFacingWorkaround: "Tap back, tap again.",
                confidenceThreshold: 0.4,
                helpspotTag: "known-issue-PP-4436"
            )
        ]
        let catalog = KBCatalog(version: "test", updatedAt: "2026-05-28", entries: entries)
        return ConversationReducer(knowledgeBase: KnowledgeBase(catalog: catalog))
    }

    /// Two same-category entries that tie on keyword score so the local
    /// classifier can neither confidently suggest nor escalate — it must
    /// disambiguate, which is the only emitter of `candidate_count`.
    private func makeDisambiguateReducer() -> ConversationReducer {
        let entries = [
            KBEntry(id: "KI-AMBIG-A", category: .audiobook, status: .open,
                    symptomKeywords: ["audio", "glitch"],
                    userFacingWorkaround: "A.", confidenceThreshold: 0.1),
            KBEntry(id: "KI-AMBIG-B", category: .audiobook, status: .open,
                    symptomKeywords: ["audio", "glitch"],
                    userFacingWorkaround: "B.", confidenceThreshold: 0.1)
        ]
        return ConversationReducer(knowledgeBase: KnowledgeBase(
            catalog: KBCatalog(version: "test", updatedAt: "x", entries: entries)))
    }

    /// An entry with a 3-step guided flow — drives step_count / step_id /
    /// steps_attempted / next_index and the exhaustion escalate
    /// (attempts_count / outcome).
    private func makeGuidedReducer() -> ConversationReducer {
        let entry = KBEntry(
            id: "KI-GUIDED",
            category: .audiobook,
            status: .open,
            symptomKeywords: ["test"],
            userFacingWorkaround: "Summary.",
            userFacingSteps: [
                KBStep(id: "step1", instruction: "Try X.", check: "Did X work?"),
                KBStep(id: "step2", instruction: "Try Y.", check: "Did Y work?"),
                KBStep(id: "step3", instruction: "Try Z.", check: "Did Z work?")
            ],
            confidenceThreshold: 0.1
        )
        return ConversationReducer(knowledgeBase: KnowledgeBase(
            catalog: KBCatalog(version: "test", updatedAt: "x", entries: [entry])))
    }

    private func makeContext() -> ContextSnapshot {
        ContextSnapshot(
            appVersion: "3.0.3", appBuild: "478",
            osVersion: "26.4.2", deviceModel: "iPhone17,2",
            distributor: "palace_marketplace"
        )
    }

    /// Threads `actions` through `reducer` starting at `state`, forwarding
    /// every `.emitTelemetry` effect into `sink` exactly as the host would.
    @discardableResult
    private func drive(
        _ reducer: ConversationReducer,
        from state: ConversationState,
        _ actions: [ConversationAction],
        into sink: SpyTelemetrySink
    ) -> ConversationState {
        var current = state
        for action in actions {
            let (next, effects) = reducer.reduce(state: current, action: action)
            for case .emitTelemetry(let event) in effects { sink.emit(event) }
            current = next
        }
        return current
    }

    /// Drives the reducer through EVERY parameterized emission path (confident
    /// match, disambiguate, all four guided-troubleshooting emitters, the
    /// exhaustion escalate, the AI-fallback match, ticket-submit-requested and
    /// ticket-submitted) and enforces two things the docstring on
    /// ``TelemetryParameterKey`` promises:
    ///
    ///  1. Per event: NO emitted parameter key is non-enumerable (free text) —
    ///     if a caller adds `parameters: ["user_text": ...]` anywhere, it fails.
    ///  2. Across all flows: the UNION of observed keys equals the full
    ///     `TelemetryParameterKey.allCases` set. A new case added to the enum
    ///     without a driven emission fails (superset direction); a key emitted
    ///     by the reducer that isn't in the enum fails via #1 (subset direction).
    ///     Together the two directions pin the enum to what the reducer emits.
    func testReducerEmittedParameterKeys_coverAndAreConfinedTo_theEnumerableContract() {
        let spy = SpyTelemetrySink()
        let context = makeContext()
        let startedAt = Date(timeIntervalSince1970: 0)

        // Confident local match → category, entry_id, confidence, ticket_id.
        drive(makeReducer(), from: ConversationState(), [
            .start,
            .contextLoaded(context),
            .userTappedCategory(.audiobook),
            .inputChanged("my audiobook keeps spinning and won't play the first time I open it"),
            .userSubmittedDescription,
            .ticketSubmitted(TicketReceipt(ticketId: "HS-42", submittedAt: Date()))
        ], into: spy)

        // Ambiguous local match → candidate_count.
        drive(makeDisambiguateReducer(), from: ConversationState(), [
            .userTappedCategory(.audiobook),
            .inputChanged("audio glitch"),
            .userSubmittedDescription
        ], into: spy)

        let guided = makeGuidedReducer()

        // Guided flow started → entry_id, step_count.
        drive(guided, from: ConversationState(step: .matched(entryId: "KI-GUIDED")),
              [.userTappedStartGuidedFlow(entryId: "KI-GUIDED")], into: spy)

        // Step resolved → entry_id, step_id, steps_attempted.
        drive(guided, from: ConversationState(step: .guidedStep(
            entryId: "KI-GUIDED", stepIndex: 0, startedAt: startedAt, attempts: [])),
              [.userConfirmedStepResolved(stepId: "step1")], into: spy)

        // Step did-not-resolve, more steps remain → entry_id, step_id, next_index.
        drive(guided, from: ConversationState(step: .guidedStep(
            entryId: "KI-GUIDED", stepIndex: 0, startedAt: startedAt, attempts: [])),
              [.userConfirmedStepDidNotResolve(stepId: "step1")], into: spy)

        // Final step did-not-resolve → escalate-with-trace → entry_id,
        // attempts_count, outcome.
        let priorAttempts = [
            StepAttempt(stepId: "step1", outcome: .didNotResolve, timestamp: startedAt),
            StepAttempt(stepId: "step2", outcome: .didNotResolve, timestamp: startedAt)
        ]
        drive(guided, from: ConversationState(
            step: .guidedStep(entryId: "KI-GUIDED", stepIndex: 2, startedAt: startedAt, attempts: priorAttempts),
            context: context),
              [.userConfirmedStepDidNotResolve(stepId: "step3")], into: spy)

        // AI fallback match → entry_id, confidence (the AI path, distinct from
        // the local kb_match emitter).
        let aiReducer = ConversationReducer(
            knowledgeBase: guided.knowledgeBase, aiFallbackEnabled: true)
        drive(aiReducer, from: ConversationState(
            step: .awaitingAIClassification(userText: "x", category: .audiobook)),
              [.aiFallbackResolved(ClassificationResult(
                decision: .suggest(entryId: "KI-GUIDED"), confidence: 0.91))], into: spy)

        // Ticket submit requested → priority.
        let draft = TicketDraft(
            userDescription: "d", category: .audiobook, context: context, priority: .high)
        drive(makeReducer(), from: ConversationState(step: .drafting(ticket: draft)),
              [.userConfirmedTicketSubmit], into: spy)

        // --- Direction 1: every emitted key is enumerable (no free text). ---
        for event in spy.events {
            XCTAssertEqual(
                TelemetryContract.nonEnumerableKeys(of: event), [],
                "Event \(event.name) emitted non-enumerable (free-text) keys"
            )
        }

        // --- Direction 2: the driven flows cover EVERY enumerable key. ---
        let observedKeys = Set(spy.events.flatMap { $0.parameters.keys })
        let allContractKeys = Set(TelemetryParameterKey.allCases.map { $0.rawValue })
        XCTAssertEqual(
            observedKeys, allContractKeys,
            """
            The union of parameter keys emitted across all driven reducer flows \
            must exactly equal TelemetryParameterKey.allCases. \
            Missing from the flows (enum case with no driven emission): \
            \(allContractKeys.subtracting(observedKeys).sorted()). \
            Emitted but not in the enum (should be impossible — caught above): \
            \(observedKeys.subtracting(allContractKeys).sorted()).
            """
        )
    }

    /// The enforcement filter keeps enumerable keys and drops everything else —
    /// this is the byte-level guarantee the Firebase sink relies on.
    func testEnumerableParameters_dropsFreeTextKeys_keepsEnumerableOnes() {
        let event = TelemetryEvent(
            name: "triage_kb_match",
            parameters: [
                "entry_id": "KI-2026-001",
                "confidence": "0.91",
                "user_text": "my barcode is 21221012345678 and my pin is 1234"
            ]
        )

        let filtered = TelemetryContract.enumerableParameters(of: event)

        XCTAssertEqual(filtered, ["entry_id": "KI-2026-001", "confidence": "0.91"])
        XCTAssertNil(filtered["user_text"], "free-text key must not survive the filter")
    }

    func testNonEnumerableKeys_flagsAFreeTextKey() {
        let event = TelemetryEvent(name: "x", parameters: ["entry_id": "KI-1", "note": "free text"])
        XCTAssertEqual(TelemetryContract.nonEnumerableKeys(of: event), ["note"])
    }
}
