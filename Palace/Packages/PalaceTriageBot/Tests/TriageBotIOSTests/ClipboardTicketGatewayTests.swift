import XCTest
@testable import TriageBotCore

// The gateway is UIKit-gated, so on macOS `swift test` this file compiles away,
// and the Palace xcodebuild scheme runs only PalaceTests/TenPrintCoverTests —
// so this file runs in NO CI job today. It is a local/sim supplement and an
// API-compile check, not the regression guard.
//
// The load-bearing, CI-gate-run guarantee that the patron's omit choices are
// honored on the wire lives in TriageBotCoreTests/SubmitEffectSanitizationTests
// (the pure reducer sanitizes the submitTicket effect for every gateway) and
// TriageBotCoreTests/TicketWirePayloadTests (the serializer). This file pins the
// GATEWAY wiring itself for anyone who later adds TriageBotIOSTests to the
// scheme's TestAction.
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
