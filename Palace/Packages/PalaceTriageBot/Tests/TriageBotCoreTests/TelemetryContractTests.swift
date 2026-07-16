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

    /// Drives the reducer through a param-rich flow, forwards every emitted
    /// telemetry event to a spy sink, and asserts NONE of them carry a
    /// non-enumerable (free-text) parameter key. If a caller adds
    /// `parameters: ["user_text": ...]` to any event on this path, or drops a
    /// case from `TelemetryParameterKey`, this fails.
    func testReducerEmittedParameterKeys_areAllEnumerable() {
        let reducer = makeReducer()
        let spy = SpyTelemetrySink()

        func run(_ state: ConversationState, _ action: ConversationAction) -> ConversationState {
            let (next, effects) = reducer.reduce(state: state, action: action)
            for case .emitTelemetry(let event) in effects { spy.emit(event) }
            return next
        }

        let context = ContextSnapshot(
            appVersion: "3.0.3",
            appBuild: "478",
            osVersion: "26.4.2",
            deviceModel: "iPhone17,2",
            distributor: "palace_marketplace"
        )

        var state = run(ConversationState(), .start)                       // triage_chat_opened
        state = run(state, .contextLoaded(context))
        state = run(state, .userTappedCategory(.audiobook))                // category
        state = run(state, .inputChanged("my audiobook keeps spinning and won't play the first time I open it"))
        state = run(state, .userSubmittedDescription)                      // entry_id + confidence
        guard case .matched(let entryId) = state.step else {
            return XCTFail("Expected .matched, got \(state.step)")
        }
        state = run(state, .userTappedNotifyMeOnFix(entryId: entryId))     // entry_id
        // Unconditional ticket-submitted emission → ticket_id.
        _ = run(state, .ticketSubmitted(TicketReceipt(ticketId: "HS-42", submittedAt: Date())))

        // We must have actually captured parameterized events, else the
        // invariant assertion below is vacuous.
        let keyUnion = Set(spy.events.flatMap { $0.parameters.keys })
        XCTAssertTrue(keyUnion.isSuperset(of: ["category", "entry_id", "confidence", "ticket_id"]),
                      "Expected the flow to exercise these keys; saw \(keyUnion.sorted())")

        for event in spy.events {
            XCTAssertEqual(
                TelemetryContract.nonEnumerableKeys(of: event), [],
                "Event \(event.name) emitted non-enumerable (free-text) keys"
            )
        }
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
