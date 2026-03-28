import Foundation

/// A recommended book with AI-generated reasoning and cross-library availability info.
struct DiscoveryRecommendation: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let authors: [String]
    let summary: String?
    let coverImageURL: URL?
    let reason: String
    let confidenceScore: Double
    let categories: [String]
    let availability: [LibraryAvailability]

    /// The best availability status across all libraries.
    var bestAvailability: AvailabilityStatus {
        availability.map(\.status).min() ?? .unavailable
    }

    /// The name of the library where this book is most readily available.
    var bestLibraryName: String? {
        availability
            .sorted { $0.status < $1.status }
            .first?.libraryName
    }
}

/// Availability information for a single library.
struct LibraryAvailability: Identifiable, Equatable, Sendable {
    var id: String { libraryId }
    let libraryId: String
    let libraryName: String
    let status: AvailabilityStatus
    let copiesAvailable: Int?
    let copiesTotal: Int?
    let holdPosition: Int?
    let estimatedWaitDays: Int?
    /// The OPDS entry identifier within this library, used for borrowing.
    let opdsIdentifier: String?
    /// The catalog URL to borrow from.
    let borrowURL: URL?
}

/// Availability tiers, ordered from best to worst (Comparable conformance).
enum AvailabilityStatus: Int, Comparable, Sendable, CaseIterable {
    case availableNow = 0
    case shortWait = 1
    case longWait = 2
    case unavailable = 3

    static func < (lhs: AvailabilityStatus, rhs: AvailabilityStatus) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var displayLabel: String {
        switch self {
        case .availableNow: return DiscoveryStrings.Discovery.availableNow
        case .shortWait: return DiscoveryStrings.Discovery.shortWait
        case .longWait: return DiscoveryStrings.Discovery.longWait
        case .unavailable: return DiscoveryStrings.Discovery.unavailable
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .availableNow: return DiscoveryStrings.Discovery.accessibilityAvailableNow
        case .shortWait: return DiscoveryStrings.Discovery.accessibilityShortWait
        case .longWait: return DiscoveryStrings.Discovery.accessibilityLongWait
        case .unavailable: return DiscoveryStrings.Discovery.accessibilityUnavailable
        }
    }
}

// MARK: - Localized Strings

/// Namespace for Discovery feature strings to avoid polluting the global namespace.
enum DiscoveryStrings {
    enum Discovery {
        static let availableNow = NSLocalizedString("Available Now", comment: "Book availability badge")
        static let shortWait = NSLocalizedString("Short Wait", comment: "Book availability badge")
        static let longWait = NSLocalizedString("Long Wait", comment: "Book availability badge")
        static let unavailable = NSLocalizedString("Unavailable", comment: "Book availability badge")
        static let accessibilityAvailableNow = NSLocalizedString("Available now for borrowing", comment: "VoiceOver availability")
        static let accessibilityShortWait = NSLocalizedString("Short wait, less than two weeks", comment: "VoiceOver availability")
        static let accessibilityLongWait = NSLocalizedString("Long wait, more than two weeks", comment: "VoiceOver availability")
        static let accessibilityUnavailable = NSLocalizedString("Currently unavailable", comment: "VoiceOver availability")
        static let searchPlaceholder = NSLocalizedString("Search across all your libraries...", comment: "Discovery search bar placeholder")
        static let surpriseMe = NSLocalizedString("Surprise Me", comment: "Button for AI random recommendation")
        static let recommendations = NSLocalizedString("Recommendations", comment: "Section header")
        static let searchResults = NSLocalizedString("Search Results", comment: "Section header")
        static let noResults = NSLocalizedString("No results found", comment: "Empty state")
        static let tryDifferentSearch = NSLocalizedString("Try a different search or pick a mood below.", comment: "Empty state subtitle")
        static let errorTitle = NSLocalizedString("Something went wrong", comment: "Error state title")
        static let retry = NSLocalizedString("Retry", comment: "Retry button")
        static let sortRelevance = NSLocalizedString("Relevance", comment: "Sort option")
        static let sortAvailability = NSLocalizedString("Availability", comment: "Sort option")
        static let sortDate = NSLocalizedString("Date", comment: "Sort option")
        static let filterAll = NSLocalizedString("All Libraries", comment: "Filter option")
        static let filterAvailableNow = NSLocalizedString("Available Now", comment: "Filter option")
        static let discover = NSLocalizedString("Discover", comment: "Tab bar title")
        static let availableAt = NSLocalizedString("Available at %@", comment: "Library name where book is available")
        static let holdAt = NSLocalizedString("Hold at %@", comment: "Library name where book can be held")
        static let aiPowered = NSLocalizedString("AI-Powered", comment: "Badge indicating AI recommendations")
        static let because = NSLocalizedString("Because %@", comment: "AI recommendation reason prefix")
    }
}
