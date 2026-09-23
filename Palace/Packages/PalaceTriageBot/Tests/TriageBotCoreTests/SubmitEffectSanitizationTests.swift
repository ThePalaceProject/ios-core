import XCTest
@testable import TriageBotCore

/// PP-4883, CI-guard for the copy-path leak. The draft the reducer hands to the
/// `submitTicket` EFFECT must already have the patron's omitted fields stripped,
/// so the guarantee holds no matter which gateway the host runs — email,
/// clipboard, or a future POST. This is the pure-Core chokepoint, exercised in
/// the fast `swift test` gate.
///
/// Why this test and not only the gateway test: `ClipboardTicketGatewayTests`
/// is UIKit-gated and runs in neither CI job (macOS `swift test` compiles it
/// away; the Palace xcodebuild scheme runs only PalaceTests/TenPrintCoverTests,
/// not the package's IOS target). Reverting the reducer sanitize here — or a
/// gateway back to encoding the raw draft — is caught by this test, which does
/// run.
final class SubmitEffectSanitizationTests: XCTestCase {

    private func makeReducer() -> ConversationReducer {
        ConversationReducer(
            knowledgeBase: KnowledgeBase(catalog: KBCatalog(version: "t", updatedAt: "2026-07-29", entries: [])),
            aiFallbackEnabled: false
        )
    }

    private func draftOmitting(_ omitted: Set<TicketField>) -> TicketDraft {
        let context = ContextSnapshot(
            appVersion: "3.3.0",
            appBuild: "487",
            osVersion: "26.4.2",
            deviceModel: "iPhone17,2",
            libraryName: "Sample Library",
            libraryUUID: "anon-deadbeef",
            distributor: "palace_marketplace",
            authType: "basic",
            networkState: "wifi",
            freeStorageBytes: nil,
            recentLogLines: ["[I] launched"],
            crashlyticsFingerprints: [],
            capturedAt: Date(timeIntervalSince1970: 1_716_900_000),
            audioOutputRoute: nil,
            lowPowerModeEnabled: nil,
            appUptimeSeconds: nil,
            buildChannel: "testflight",
            availableMemoryMB: nil,
            libraryBarcode: "sha256:abc123hashedbarcode"
        )
        return TicketDraft(
            userDescription: "audiobook spins forever",
            category: .audiobook,
            context: context,
            omittedFields: omitted
        )
    }

    private func submittedDraft(in effects: [ConversationEffect]) throws -> TicketDraft {
        let draft = effects.compactMap { effect -> TicketDraft? in
            if case .submitTicket(let d) = effect { return d }
            return nil
        }.first
        return try XCTUnwrap(draft, "reducer must emit a submitTicket effect")
    }

    /// Confirming the send emits a submitTicket effect whose draft has the
    /// omitted fields stripped and the omit-list cleared.
    func testConfirmSubmit_effectDraftIsWireReady() throws {
        let reducer = makeReducer()
        let draft = draftOmitting([.barcode, .logs, .library, .network])
        // A directly-constructed drafting state defaults to an un-armed consent
        // gate, so the confirm proceeds (see reducer .userConfirmedTicketSubmit).
        let state = ConversationState(step: .drafting(ticket: draft))

        let (_, effects) = reducer.reduce(state: state, action: .userConfirmedTicketSubmit)
        let sent = try submittedDraft(in: effects)

        XCTAssertNil(sent.context.libraryBarcode, "omitted barcode must not reach the gateway")
        XCTAssertEqual(sent.context.recentLogLines, [], "omitted logs must not reach the gateway")
        XCTAssertNil(sent.context.libraryName, "omitted library must not reach the gateway")
        XCTAssertNil(sent.context.networkState, "omitted network must not reach the gateway")
        // Non-omitted fields still ship.
        XCTAssertEqual(sent.context.distributor, "palace_marketplace")
        XCTAssertTrue(sent.omittedFields.isEmpty, "wire draft must not carry the omit list")
    }

    /// The failure/retry path must sanitize too — a patron who omitted a field
    /// and then retried after a transport failure still has it honored.
    func testRetrySubmit_effectDraftIsWireReady() throws {
        let reducer = makeReducer()
        let draft = draftOmitting([.barcode, .logs])
        let state = ConversationState(step: .error(message: "Network failed", failedDraft: draft))

        let (_, effects) = reducer.reduce(state: state, action: .userTappedRetrySubmission)
        let sent = try submittedDraft(in: effects)

        XCTAssertNil(sent.context.libraryBarcode, "retry must not resend an omitted barcode")
        XCTAssertEqual(sent.context.recentLogLines, [], "retry must not resend omitted logs")
        XCTAssertTrue(sent.omittedFields.isEmpty)
    }

    /// Nothing omitted → the full draft ships (sanitize strips only what was
    /// switched off).
    func testConfirmSubmit_keepsEverything_whenNothingOmitted() throws {
        let reducer = makeReducer()
        let draft = draftOmitting([])
        let state = ConversationState(step: .drafting(ticket: draft))

        let (_, effects) = reducer.reduce(state: state, action: .userConfirmedTicketSubmit)
        let sent = try submittedDraft(in: effects)

        XCTAssertEqual(sent.context.libraryBarcode, "sha256:abc123hashedbarcode")
        XCTAssertEqual(sent.context.networkState, "wifi")
        XCTAssertEqual(sent.context.recentLogLines, ["[I] launched"])
    }
}
