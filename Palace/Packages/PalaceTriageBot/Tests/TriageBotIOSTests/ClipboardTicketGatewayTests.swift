import XCTest
@testable import TriageBotCore

// The gateway is UIKit-gated, so on macOS `swift test` this file compiles away
// and these assertions run only on an iOS simulator (via the app build).
// The load-bearing, gate-run coverage of the copy-path serialization lives in
// TriageBotCoreTests/TicketWirePayloadTests; this pins the GATEWAY itself —
// that it routes the draft through the sanitizing serializer before writing.
#if canImport(UIKit)
@testable import TriageBotIOS

final class ClipboardTicketGatewayTests: XCTestCase {

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

    /// PP-4883: the payload the gateway writes to the pasteboard must honor the
    /// patron's omissions — the exact bug the ticket fixes. Capturing the write
    /// via the injected sink keeps the assertion off global UIPasteboard state.
    func testSubmit_writesSanitizedPayload_honoringOmissions() async throws {
        let box = CapturedWrite()
        let gateway = ClipboardTicketGateway(write: { await box.set($0) })

        _ = try await gateway.submit(draftOmitting([.barcode, .logs, .library]))

        let json = try XCTUnwrap(await box.value)
        let decoded = try JSONDecoder.iso8601.decode(TicketDraft.self, from: Data(json.utf8))
        XCTAssertNil(decoded.context.libraryBarcode, "omitted barcode must not reach the pasteboard")
        XCTAssertEqual(decoded.context.recentLogLines, [], "omitted logs must not reach the pasteboard")
        XCTAssertNil(decoded.context.libraryName, "omitted library must not reach the pasteboard")
        // Non-omitted fields still ship.
        XCTAssertEqual(decoded.context.networkState, "wifi")
        XCTAssertTrue(decoded.omittedFields.isEmpty)
    }

    private actor CapturedWrite {
        private(set) var value: String?
        func set(_ v: String) { value = v }
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
#endif
