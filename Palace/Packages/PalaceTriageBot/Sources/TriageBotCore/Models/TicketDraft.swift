import Foundation

/// A context field the patron can omit from the outgoing ticket via the preview
/// editor (PP-4807). Only optional / potentially-identifying fields are listed;
/// the description, category, app version, and device are always sent so the
/// ticket is actionable. Omission is enforced at serialization time
/// (`TicketDraft.sanitizedForSubmission`), not just hidden in the UI.
public enum TicketField: String, Codable, Sendable, CaseIterable, Equatable {
    case barcode
    case library
    case network
    case logs
    case distributor
    case authType
}

/// What the bot will send to HelpSpot when the user confirms a ticket. The
/// user sees this verbatim before send — no surprise fields, no background
/// telemetry attached after preview. Anything sensitive must be redacted
/// before it lands here.
public struct TicketDraft: Codable, Equatable, Sendable {
    public let userDescription: String
    public let category: KBCategory
    public let matchedEntryId: String?       // present even on escalate-anyway so support sees the bot's guess
    public let context: ContextSnapshot
    public let helpspotTags: [String]
    public let priority: Priority
    /// Present when the user worked through a guided troubleshooting flow
    /// before escalating. Lists every step attempted, the outcome of each,
    /// and the timing — gives support the difference between "couldn't fix
    /// it" and "tried steps 1, 2, 3 over 4 minutes, none worked."
    public let resolutionTrace: ResolutionTrace?
    /// Present when the bot asked an escalation follow-up question
    /// (e.g. "Which library are you trying to add?") and the user either
    /// answered or skipped. Support sees this in the email body so they
    /// don't have to ask for context that's already been collected.
    public let escalationFollowUp: EscalationFollowUpAnswer?
    /// Fields the patron chose to leave out of the ticket via the preview
    /// editor (PP-4807). Enforced by `sanitizedForSubmission()` — an omitted
    /// field is dropped from the email body AND absent from the JSON
    /// attachment, not merely hidden in the card.
    public let omittedFields: Set<TicketField>

    public enum Priority: String, Codable, Sendable {
        case low      // user accepted bot's match, filing for impact tracking only
        case normal   // standard support flow
        case high     // user explicitly escalated past a match or critical-path category
    }

    public init(
        userDescription: String,
        category: KBCategory,
        matchedEntryId: String? = nil,
        context: ContextSnapshot,
        helpspotTags: [String] = [],
        priority: Priority = .normal,
        resolutionTrace: ResolutionTrace? = nil,
        escalationFollowUp: EscalationFollowUpAnswer? = nil,
        omittedFields: Set<TicketField> = []
    ) {
        self.userDescription = userDescription
        self.category = category
        self.matchedEntryId = matchedEntryId
        self.context = context
        self.helpspotTags = helpspotTags
        self.priority = priority
        self.resolutionTrace = resolutionTrace
        self.escalationFollowUp = escalationFollowUp
        self.omittedFields = omittedFields
    }

    enum CodingKeys: String, CodingKey {
        case userDescription, category, matchedEntryId, context, helpspotTags
        case priority, resolutionTrace, escalationFollowUp, omittedFields
    }

    // Decode-tolerant: a draft persisted by an older build (or the sanitized
    // attachment) may lack `omittedFields`; default it to empty rather than
    // failing the whole decode.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userDescription = try c.decode(String.self, forKey: .userDescription)
        category = try c.decode(KBCategory.self, forKey: .category)
        matchedEntryId = try c.decodeIfPresent(String.self, forKey: .matchedEntryId)
        context = try c.decode(ContextSnapshot.self, forKey: .context)
        helpspotTags = try c.decodeIfPresent([String].self, forKey: .helpspotTags) ?? []
        priority = try c.decode(Priority.self, forKey: .priority)
        resolutionTrace = try c.decodeIfPresent(ResolutionTrace.self, forKey: .resolutionTrace)
        escalationFollowUp = try c.decodeIfPresent(EscalationFollowUpAnswer.self, forKey: .escalationFollowUp)
        omittedFields = try c.decodeIfPresent(Set<TicketField>.self, forKey: .omittedFields) ?? []
    }

    // MARK: - Preview editor helpers (PP-4807)

    /// A copy with the given omitted-field set. Used by the reducer as the
    /// user toggles per-row include/omit switches in the preview.
    public func withOmittedFields(_ fields: Set<TicketField>) -> TicketDraft {
        TicketDraft(
            userDescription: userDescription, category: category, matchedEntryId: matchedEntryId,
            context: context, helpspotTags: helpspotTags, priority: priority,
            resolutionTrace: resolutionTrace, escalationFollowUp: escalationFollowUp,
            omittedFields: fields
        )
    }

    /// A copy with a new context. Used to late-bind the real environment into a
    /// draft that was assembled before context finished loading (PP-4811).
    public func withContext(_ newContext: ContextSnapshot) -> TicketDraft {
        TicketDraft(
            userDescription: userDescription, category: category, matchedEntryId: matchedEntryId,
            context: newContext, helpspotTags: helpspotTags, priority: priority,
            resolutionTrace: resolutionTrace, escalationFollowUp: escalationFollowUp,
            omittedFields: omittedFields
        )
    }

    /// A copy with an edited description. Callers redact the text first.
    public func withUserDescription(_ text: String) -> TicketDraft {
        TicketDraft(
            userDescription: text, category: category, matchedEntryId: matchedEntryId,
            context: context, helpspotTags: helpspotTags, priority: priority,
            resolutionTrace: resolutionTrace, escalationFollowUp: escalationFollowUp,
            omittedFields: omittedFields
        )
    }

    /// The draft that actually goes on the wire: every omitted field is
    /// stripped from the context so it is ABSENT from the email body and the
    /// JSON attachment (PP-4807). The library barcode is already a hash (the
    /// redactor hashed it) — this only decides whether that hash is sent.
    public func sanitizedForSubmission() -> TicketDraft {
        let c = context
        let sanitizedContext = ContextSnapshot(
            appVersion: c.appVersion,
            appBuild: c.appBuild,
            platform: c.platform,
            osVersion: c.osVersion,
            deviceModel: c.deviceModel,
            libraryName: omittedFields.contains(.library) ? nil : c.libraryName,
            libraryUUID: omittedFields.contains(.library) ? nil : c.libraryUUID,
            distributor: omittedFields.contains(.distributor) ? nil : c.distributor,
            authType: omittedFields.contains(.authType) ? nil : c.authType,
            networkState: omittedFields.contains(.network) ? nil : c.networkState,
            freeStorageBytes: c.freeStorageBytes,
            recentLogLines: omittedFields.contains(.logs) ? [] : c.recentLogLines,
            crashlyticsFingerprints: c.crashlyticsFingerprints,
            capturedAt: c.capturedAt,
            audioOutputRoute: c.audioOutputRoute,
            lowPowerModeEnabled: c.lowPowerModeEnabled,
            appUptimeSeconds: c.appUptimeSeconds,
            buildChannel: c.buildChannel,
            availableMemoryMB: c.availableMemoryMB,
            libraryBarcode: omittedFields.contains(.barcode) ? nil : c.libraryBarcode
        )
        return TicketDraft(
            userDescription: userDescription, category: category, matchedEntryId: matchedEntryId,
            context: sanitizedContext, helpspotTags: helpspotTags, priority: priority,
            resolutionTrace: resolutionTrace, escalationFollowUp: escalationFollowUp,
            omittedFields: []
        )
    }
}

/// Reference returned by the ticket gateway after a successful submission.
public struct TicketReceipt: Equatable, Sendable {
    public let ticketId: String
    public let submittedAt: Date

    public init(ticketId: String, submittedAt: Date = Date()) {
        self.ticketId = ticketId
        self.submittedAt = submittedAt
    }
}
