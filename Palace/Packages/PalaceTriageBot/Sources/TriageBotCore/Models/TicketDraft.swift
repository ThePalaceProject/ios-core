import Foundation

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
        priority: Priority = .normal
    ) {
        self.userDescription = userDescription
        self.category = category
        self.matchedEntryId = matchedEntryId
        self.context = context
        self.helpspotTags = helpspotTags
        self.priority = priority
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
