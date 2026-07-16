import XCTest
@testable import TriageBotCore

/// PP-4808 — never dead-end on a submit failure. Pins the pure error-message
/// mapping and the pending-draft persistence contract (both TriageBotCore, so
/// macOS-testable). The EmailGatewayError → SubmissionFailure mapping itself is
/// exercised in the iOS-gated tests (EmailGatewayError needs MessageUI).
final class SubmissionFailureTests: XCTestCase {

    // MARK: - UserFacingErrorMessage

    func testUserFacingMessage_transport_doesNotLeakRawDetail() {
        let raw = "URLSession error 503: internal-backend-stacktrace"
        let message = UserFacingErrorMessage.from(.transport(detail: raw))
        XCTAssertFalse(message.contains(raw), "The raw technical detail must not appear in the patron-facing message")
        XCTAssertFalse(message.isEmpty)
    }

    func testUserFacingMessage_distinguishesCancelFromTransport() {
        let cancel = UserFacingErrorMessage.from(.userCancelled)
        let transport = UserFacingErrorMessage.from(.transport(detail: "x"))
        XCTAssertNotEqual(cancel, transport, "Cancel and real failure must read differently")
    }

    // MARK: - PendingDraftCodec round-trip

    func testPendingDraftCodec_roundTripsFullyPopulatedDraft() {
        let context = ContextSnapshot(
            appVersion: "3.3.0", appBuild: "500", osVersion: "26.4.2", deviceModel: "iPhone17,2",
            libraryName: "Morton", distributor: "palace_marketplace", authType: "oauth",
            networkState: "wifi", recentLogLines: ["line a", "line b"],
            crashlyticsFingerprints: ["fp1"]
        )
        let trace = ResolutionTrace(
            entryId: "KI-1",
            attempts: [StepAttempt(stepId: "s1", outcome: .didNotResolve, timestamp: Date(timeIntervalSince1970: 10))],
            startedAt: Date(timeIntervalSince1970: 0),
            endedAt: Date(timeIntervalSince1970: 60),
            outcome: .escalatedAfterStepsExhausted
        )
        let draft = TicketDraft(
            userDescription: "won't play",
            category: .audiobook,
            matchedEntryId: "KI-1",
            context: context,
            helpspotTags: ["a", "b"],
            priority: .high,
            resolutionTrace: trace,
            escalationFollowUp: EscalationFollowUpAnswer(prompt: "Which title?", answer: "Dune")
        )

        guard let data = PendingDraftCodec.encode(draft) else {
            return XCTFail("Encoding a valid draft must succeed")
        }
        let decoded = PendingDraftCodec.decode(data)
        XCTAssertEqual(decoded, draft, "A persisted draft must decode back identically, including nested context / trace / follow-up")
    }

    func testPendingDraftCodec_decodeGarbage_returnsNil() {
        XCTAssertNil(PendingDraftCodec.decode(Data("not json".utf8)))
    }

    // MARK: - UserDefaultsPendingDraftStore

    private func makeIsolatedStore() -> UserDefaultsPendingDraftStore {
        let suite = UserDefaults(suiteName: "triagebot.test.\(UUID().uuidString)")!
        return UserDefaultsPendingDraftStore(defaults: suite, key: "pending")
    }

    func testStore_saveThenLoad_returnsDraft() {
        let store = makeIsolatedStore()
        let draft = TicketDraft(
            userDescription: "x", category: .other,
            context: ContextSnapshot(appVersion: "3", appBuild: "1", osVersion: "26", deviceModel: "d")
        )
        store.save(draft)
        XCTAssertEqual(store.load(), draft)
    }

    func testStore_saveNil_clearsSlot() {
        let store = makeIsolatedStore()
        let draft = TicketDraft(
            userDescription: "x", category: .other,
            context: ContextSnapshot(appVersion: "3", appBuild: "1", osVersion: "26", deviceModel: "d")
        )
        store.save(draft)
        store.save(nil)
        XCTAssertNil(store.load(), "Saving nil must clear the persisted draft")
    }
}
