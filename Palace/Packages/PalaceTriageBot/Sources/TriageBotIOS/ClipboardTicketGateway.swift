#if canImport(UIKit)
import Foundation
import UIKit
import TriageBotCore

/// Demo-safe TicketGateway. Doesn't talk to HelpSpot — it serializes the
/// draft to pretty-printed JSON, writes it to UIPasteboard, and synthesizes
/// a local receipt. Used when `triage_bot_ticket_submission_enabled` is off
/// (default during the demo) so the conversation flow is fully exercisable
/// without poking the real ticketing system.
///
/// Replace with HelpSpotTicketGateway (production) once support has signed
/// off on rate limits + ticket-routing rules.
public struct ClipboardTicketGateway: TicketGateway {
    /// Where the serialized ticket is written. Defaults to the system
    /// pasteboard; injectable so the copy-path output can be asserted in a test
    /// without mutating global `UIPasteboard.general` state.
    private let write: @Sendable (String) async -> Void

    public init(write: @escaping @Sendable (String) async -> Void = { json in
        await MainActor.run { UIPasteboard.general.string = json }
    }) {
        self.write = write
    }

    public func submit(_ draft: TicketDraft) async throws -> TicketReceipt {
        // PP-4883: serialize the WIRE-READY draft via the shared
        // TicketWirePayload — the same serializer the email path uses — so the
        // patron's "don't include this" choices are honored on the copy path
        // too. Previously this encoded the raw draft and shipped fields the
        // patron had switched off (as-built gap 12).
        let json = TicketWirePayload.json(for: draft)
        await write(json)
        return TicketReceipt(
            ticketId: "DEMO-CLIPBOARD-\(Int(Date().timeIntervalSince1970))",
            submittedAt: Date()
        )
    }
}
#endif
