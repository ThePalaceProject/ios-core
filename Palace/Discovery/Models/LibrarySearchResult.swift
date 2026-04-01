import Foundation

/// A search result from a single library, wrapping OPDS entry data with availability.
struct LibrarySearchResult: Identifiable, Equatable {
    /// Composite ID: libraryId + bookIdentifier.
    var id: String { "\(libraryId):\(bookIdentifier)" }

    let libraryId: String
    let libraryName: String
    let bookIdentifier: String
    let title: String
    let authors: [String]
    let summary: String?
    let categories: [String]
    let coverImageURL: URL?
    let thumbnailURL: URL?
    let availability: AvailabilityStatus
    let copiesAvailable: Int?
    let copiesTotal: Int?
    let holdPosition: Int?
    let published: Date?
    let publisher: String?
    let borrowURL: URL?
    let format: BookFormat

    /// The underlying TPPBook, if one was constructed from the OPDS entry.
    let book: TPPBook?
}

/// Supported book formats for filtering.
enum BookFormat: String, CaseIterable, Sendable {
    case epub = "EPUB"
    case pdf = "PDF"
    case audiobook = "Audiobook"
    case unknown = "Unknown"

    var displayName: String { rawValue }
}
