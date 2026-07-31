import XCTest
@testable import TriageBotCore

/// PP-4883: the ticket the patron reviews field-by-field must go on the wire
/// exactly as previewed — every "don't include this" choice honored — on EVERY
/// send path, not just email. `TicketWirePayload` is the single owner of ticket
/// serialization; both `ClipboardTicketGateway` and the email diagnostics
/// attachment route through it, so the two paths cannot drift apart.
///
/// These run in the fast, UIKit-free `swift test` gate (the gateway itself is
/// UIKit-gated and can't run there), so a regression that stops honoring
/// omissions on the copy path fails the same gate that already guards email.
final class TicketWirePayloadTests: XCTestCase {

    private func makeContext(recentLogs: [String] = ["[I] launched", "[I] opened book"]) -> ContextSnapshot {
        ContextSnapshot(
            appVersion: "3.3.0",
            appBuild: "487",
            osVersion: "26.4.2",
            deviceModel: "iPhone17,2",
            libraryName: "Sample Library",
            libraryUUID: "anon-deadbeef",
            distributor: "palace_marketplace",
            authType: "basic",
            networkState: "wifi",
            freeStorageBytes: 8_500_000_000,
            recentLogLines: recentLogs,
            crashlyticsFingerprints: ["0x8a3f2b1c4"],
            capturedAt: Date(timeIntervalSince1970: 1_716_900_000),
            audioOutputRoute: nil,
            lowPowerModeEnabled: nil,
            appUptimeSeconds: nil,
            buildChannel: "testflight",
            availableMemoryMB: nil,
            libraryBarcode: "sha256:abc123hashedbarcode"
        )
    }

    private func makeDraft(omitting omitted: Set<TicketField>) -> TicketDraft {
        TicketDraft(
            userDescription: "my audiobook just sits there spinning",
            category: .audiobook,
            matchedEntryId: nil,
            context: makeContext(),
            helpspotTags: ["triage-bot-escalate-novel"],
            priority: .normal,
            omittedFields: omitted
        )
    }

    private func decode(_ json: String) throws -> TicketDraft {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TicketDraft.self, from: Data(json.utf8))
    }

    // MARK: - The copy path honors omissions

    func testJSON_stripsEveryOmittedField() throws {
        let draft = makeDraft(omitting: [.barcode, .library, .network, .logs])
        let decoded = try decode(TicketWirePayload.json(for: draft))

        // The patron switched these off — they must be ABSENT from the bytes.
        XCTAssertNil(decoded.context.libraryBarcode, "omitted barcode must not be serialized")
        XCTAssertNil(decoded.context.libraryName, "omitted library must not be serialized")
        XCTAssertNil(decoded.context.libraryUUID, "omitted library UUID must not be serialized")
        XCTAssertNil(decoded.context.networkState, "omitted network must not be serialized")
        XCTAssertEqual(decoded.context.recentLogLines, [], "omitted logs must not be serialized")

        // A field the patron did NOT switch off still ships — sanitize strips
        // only what was omitted, it doesn't nuke everything.
        XCTAssertEqual(decoded.context.distributor, "palace_marketplace")
        XCTAssertEqual(decoded.context.authType, "basic")
        XCTAssertEqual(decoded.userDescription, draft.userDescription)

        // The payload carries no residual omit list to leak which fields were
        // stripped — sanitizedForSubmission() clears it.
        XCTAssertTrue(decoded.omittedFields.isEmpty, "wire payload must not advertise the omitted-field list")
    }

    func testJSON_keepsEverything_whenNothingOmitted() throws {
        let decoded = try decode(TicketWirePayload.json(for: makeDraft(omitting: [])))

        XCTAssertEqual(decoded.context.libraryBarcode, "sha256:abc123hashedbarcode")
        XCTAssertEqual(decoded.context.libraryName, "Sample Library")
        XCTAssertEqual(decoded.context.networkState, "wifi")
        XCTAssertEqual(decoded.context.recentLogLines, ["[I] launched", "[I] opened book"])
    }

    // MARK: - Email and copy paths cannot drift apart

    func testJSON_isByteIdenticalToEmailDiagnosticsAttachment() throws {
        // Both the clipboard copy and the email's palace-diagnostics.json must
        // encode the exact same sanitized bytes. Pinning byte-equality here is
        // what keeps a future third send path from re-introducing gap 12.
        let draft = makeDraft(omitting: [.barcode, .logs])
        let copyBytes = Data(TicketWirePayload.json(for: draft).utf8)
        let emailAttachment = try XCTUnwrap(
            TicketEmailComposition.attachments(for: draft)
                .first { $0.fileName == "palace-diagnostics.json" }?.data
        )
        XCTAssertEqual(copyBytes, emailAttachment, "copy payload and email attachment must be byte-identical")
    }
}
