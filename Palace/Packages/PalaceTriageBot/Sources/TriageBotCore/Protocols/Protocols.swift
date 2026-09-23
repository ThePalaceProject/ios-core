import Foundation

/// Snapshots the user's environment when chat opens. iOS impl lives in
/// TriageBotIOS; Android impl lives in the Kotlin port. The contract — what
/// fields ship — is the same across both, which is why ContextSnapshot is
/// pure-Codable in TriageBotCore.
public protocol ContextProvider: Sendable {
    func captureSnapshot() async -> ContextSnapshot
}

/// Submits a TicketDraft to the support system. iOS impl wraps HelpSpot's
/// HTTP API (or, for demo, copies the JSON to the pasteboard). Failure modes
/// surface via the throwing init — the reducer maps thrown errors to
/// `ticketSubmissionFailed` actions.
///
/// Serialization contract (PP-4883): any implementation that writes the draft
/// to an external sink (email attachment, pasteboard, network body) MUST
/// serialize `draft.sanitizedForSubmission()` — in practice, route through
/// `TicketWirePayload` — never the raw draft. The patron reviews the ticket
/// field-by-field and can switch fields off; a gateway that encodes the raw
/// draft ships fields the patron omitted (as-built gap 12).
public protocol TicketGateway: Sendable {
    func submit(_ draft: TicketDraft) async throws -> TicketReceipt
}

/// Fire-and-forget telemetry. iOS impl emits Firebase Analytics events.
/// Stays a protocol so tests can assert on the spy without touching SDKs.
public protocol TelemetrySink: Sendable {
    func emit(_ event: TelemetryEvent)
}

public struct TelemetryEvent: Equatable, Sendable {
    public let name: String
    public let parameters: [String: String]

    public init(name: String, parameters: [String: String] = [:]) {
        self.name = name
        self.parameters = parameters
    }
}

/// Whether the bot is enabled at all. Backed by Firebase Remote Config on
/// iOS — the Settings entry, the chat surface, and the ticket submission
/// are each gated independently so support can dial back without a release.
public protocol FeatureFlagProvider: Sendable {
    /// Master kill-switch. If false, the bot is invisible — no Settings row,
    /// no entry points, no surface area.
    var isTriageBotEnabled: Bool { get }
    /// Whether the bot may post real HelpSpot tickets. When false, the bot
    /// still drafts the ticket and shows the preview, but the confirm action
    /// copies-to-clipboard instead of submitting.
    var isTicketSubmissionEnabled: Bool { get }
}

/// Source of KB entries. The bundled JSON catalog implements this; a future
/// server-backed source (CDN-hosted catalog, hot-updatable) implements the
/// same protocol and the rest of the system doesn't notice.
public protocol KnowledgeBaseSource: Sendable {
    func loadCatalog() async throws -> KBCatalog
}
