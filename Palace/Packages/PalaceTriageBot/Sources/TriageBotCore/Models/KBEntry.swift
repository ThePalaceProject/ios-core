import Foundation

/// Status of a known-issue entry. Drives what the bot says to the user.
public enum KBStatus: String, Codable, Sendable {
    case open
    case fixedIn = "fixed_in"
    case wontfix
    case duplicateOf = "duplicate_of"
    case userError = "user_error"
}

/// How much the bot trusts an entry. Authoritative entries are quoted verbatim;
/// signal entries are used for detection but hedged; context entries only seed
/// clarifying questions, never spoken as truth. See plan §"Trust levels".
public enum KBTrustLevel: String, Codable, Sendable {
    case authoritative
    case signal
    case context
}

/// Whether an entry's workaround text may surface to end users.
public enum KBVisibility: String, Codable, Sendable {
    case userFacing = "user_facing"
    case internalOnly = "internal_only"
}

public enum KBCategory: String, Codable, Sendable, CaseIterable {
    case audiobook
    case reader
    case signin
    case download
    case library
    case other
}

public struct KBInternalReference: Codable, Equatable, Sendable {
    public let jira: String?
    public let wallFailure: String?
    public let helpspot: [Int]?

    enum CodingKeys: String, CodingKey {
        case jira
        case wallFailure = "wall_failure"
        case helpspot
    }
}

/// A known-issue entry. JSON-shaped on purpose — the same schema lives in the
/// Kotlin port when the KMP path opens up. Fields stay snake_case in JSON
/// (matches the plan's YAML frontmatter) and camelCase in Swift via CodingKeys.
public struct KBEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let category: KBCategory
    public let status: KBStatus
    public let fixedInVersion: String?
    public let symptomKeywords: [String]
    public let distributorFilter: [String]?
    public let authTypeFilter: [String]?
    public let iosVersionFilter: [String]?
    public let userFacingWorkaround: String
    /// Optional ordered list of troubleshooting steps. When present, the
    /// bot offers a "Walk me through this" path that drives the user
    /// through them one at a time, asking "did that work?" after each.
    /// Entries without steps render the legacy single-card behavior. See
    /// KBStep + ResolutionTrace.
    public let userFacingSteps: [KBStep]?
    /// Optional structured question asked right before the bot files an
    /// escalation ticket for this entry. Gives support a specific piece
    /// of context up front ("which library?", "which book title?") so
    /// triage doesn't start with a "couldn't find my library" ticket.
    public let escalationFollowUp: KBEscalationFollowUp?
    public let internalReference: KBInternalReference?
    public let confidenceThreshold: Double
    public let escalateAnyway: Bool
    public let helpspotTag: String?
    public let trustLevel: KBTrustLevel
    public let visibility: KBVisibility

    enum CodingKeys: String, CodingKey {
        case id
        case category
        case status
        case fixedInVersion = "fixed_in_version"
        case symptomKeywords = "symptom_keywords"
        case distributorFilter = "distributor_filter"
        case authTypeFilter = "auth_type_filter"
        case iosVersionFilter = "ios_version_filter"
        case userFacingWorkaround = "user_facing_workaround"
        case userFacingSteps = "user_facing_steps"
        case escalationFollowUp = "escalation_follow_up"
        case internalReference = "internal_reference"
        case confidenceThreshold = "confidence_threshold"
        case escalateAnyway = "escalate_anyway"
        case helpspotTag = "helpspot_tag"
        case trustLevel = "trust_level"
        case visibility = "visibility"
    }

    public init(
        id: String,
        category: KBCategory,
        status: KBStatus,
        fixedInVersion: String? = nil,
        symptomKeywords: [String],
        distributorFilter: [String]? = nil,
        authTypeFilter: [String]? = nil,
        iosVersionFilter: [String]? = nil,
        userFacingWorkaround: String,
        userFacingSteps: [KBStep]? = nil,
        escalationFollowUp: KBEscalationFollowUp? = nil,
        internalReference: KBInternalReference? = nil,
        confidenceThreshold: Double = 0.6,
        escalateAnyway: Bool = false,
        helpspotTag: String? = nil,
        trustLevel: KBTrustLevel = .authoritative,
        visibility: KBVisibility = .userFacing
    ) {
        self.id = id
        self.category = category
        self.status = status
        self.fixedInVersion = fixedInVersion
        self.symptomKeywords = symptomKeywords
        self.distributorFilter = distributorFilter
        self.authTypeFilter = authTypeFilter
        self.iosVersionFilter = iosVersionFilter
        self.userFacingWorkaround = userFacingWorkaround
        self.userFacingSteps = userFacingSteps
        self.escalationFollowUp = escalationFollowUp
        self.internalReference = internalReference
        self.confidenceThreshold = confidenceThreshold
        self.escalateAnyway = escalateAnyway
        self.helpspotTag = helpspotTag
        self.trustLevel = trustLevel
        self.visibility = visibility
    }
}

/// Top-level catalog shape. JSON file bundled in the package; server can ship
/// the identical shape from a CDN-backed endpoint for hot updates without an
/// App Store release.
public struct KBCatalog: Codable, Equatable, Sendable {
    public let version: String
    public let updatedAt: String
    public let entries: [KBEntry]

    enum CodingKeys: String, CodingKey {
        case version
        case updatedAt = "updated_at"
        case entries
    }
}
