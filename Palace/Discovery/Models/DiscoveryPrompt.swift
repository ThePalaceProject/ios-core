import Foundation

/// A user's discovery query encapsulating free text, mood, and reading context.
struct DiscoveryPrompt: Equatable, Sendable {
    let freeText: String?
    let mood: ReadingMood?
    let genres: [String]
    let readingHistory: [ReadingHistoryItem]
    let maxResults: Int

    init(
        freeText: String? = nil,
        mood: ReadingMood? = nil,
        genres: [String] = [],
        readingHistory: [ReadingHistoryItem] = [],
        maxResults: Int = 20
    ) {
        self.freeText = freeText
        self.mood = mood
        self.genres = genres
        self.readingHistory = readingHistory
        self.maxResults = maxResults
    }

    /// Creates a "Surprise Me" prompt from reading history alone.
    static func surpriseMe(history: [ReadingHistoryItem]) -> DiscoveryPrompt {
        DiscoveryPrompt(
            freeText: nil,
            mood: nil,
            genres: [],
            readingHistory: history,
            maxResults: 10
        )
    }
}

/// Mood-based browsing options.
enum ReadingMood: String, CaseIterable, Identifiable, Sendable {
    case relaxing
    case thrilling
    case educational
    case inspiring
    case funny
    case shortReads
    case deepDive

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .relaxing: return NSLocalizedString("Relaxing", comment: "Reading mood")
        case .thrilling: return NSLocalizedString("Thrilling", comment: "Reading mood")
        case .educational: return NSLocalizedString("Educational", comment: "Reading mood")
        case .inspiring: return NSLocalizedString("Inspiring", comment: "Reading mood")
        case .funny: return NSLocalizedString("Funny", comment: "Reading mood")
        case .shortReads: return NSLocalizedString("Short Reads", comment: "Reading mood")
        case .deepDive: return NSLocalizedString("Deep Dive", comment: "Reading mood")
        }
    }

    var emoji: String {
        switch self {
        case .relaxing: return "calm"
        case .thrilling: return "suspenseful"
        case .educational: return "informative"
        case .inspiring: return "uplifting"
        case .funny: return "humorous"
        case .shortReads: return "short, under 200 pages"
        case .deepDive: return "long, immersive"
        }
    }

    var systemImageName: String {
        switch self {
        case .relaxing: return "leaf"
        case .thrilling: return "bolt"
        case .educational: return "graduationcap"
        case .inspiring: return "sun.max"
        case .funny: return "face.smiling"
        case .shortReads: return "clock"
        case .deepDive: return "book"
        }
    }
}

/// Minimal representation of a previously read book, used for AI context.
struct ReadingHistoryItem: Equatable, Codable, Sendable {
    let title: String
    let authors: [String]
    let categories: [String]

    init(title: String, authors: [String], categories: [String]) {
        self.title = title
        self.authors = authors
        self.categories = categories
    }

    init(book: TPPBook) {
        self.title = book.title
        self.authors = book.bookAuthors?.map(\.name) ?? []
        self.categories = (book.categoryStrings as? [String]) ?? []
    }
}
