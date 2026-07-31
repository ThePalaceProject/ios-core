import Foundation

/// The single owner of ticket serialization for every path that puts a ticket
/// on the wire — the email `palace-diagnostics.json` attachment, the clipboard
/// copy path, and any future gateway (a HelpSpot POST, an Android sink).
///
/// It always encodes the WIRE-READY draft (`sanitizedForSubmission()`), so a
/// field the patron switched off in the preview is absent from the bytes on
/// every path — not merely hidden in the UI. Before PP-4883 the clipboard
/// gateway JSON-encoded the *raw* draft and honored no omissions (as-built gap
/// 12); routing all paths through here is what keeps them from drifting apart.
///
/// Lives in TriageBotCore (not TriageBotIOS) so it is unit-tested under macOS
/// `swift test` — the same fast gate that already guards the email path — even
/// though the gateways that call it are UIKit-gated.
public enum TicketWirePayload {

    /// Pretty-printed, deterministically-keyed JSON of the sanitized draft.
    /// Falls back to `"{}"` only if encoding fails (it does not, for a
    /// well-formed draft) so callers writing to a sink never crash.
    public static func json(for rawDraft: TicketDraft) -> String {
        guard let data = try? jsonData(for: rawDraft),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    /// The raw JSON bytes, for callers (the email attachment) that need `Data`.
    public static func jsonData(for rawDraft: TicketDraft) throws -> Data {
        let draft = rawDraft.sanitizedForSubmission()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(draft)
    }
}
