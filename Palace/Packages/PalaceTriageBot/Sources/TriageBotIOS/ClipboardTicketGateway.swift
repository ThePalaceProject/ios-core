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
    public init() {}

    public func submit(_ draft: TicketDraft) async throws -> TicketReceipt {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(draft)
        let json = String(data: data, encoding: .utf8) ?? "{}"
        await MainActor.run {
            UIPasteboard.general.string = json
        }
        return TicketReceipt(
            ticketId: "DEMO-CLIPBOARD-\(Int(Date().timeIntervalSince1970))",
            submittedAt: Date()
        )
    }
}
#endif
