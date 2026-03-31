import Foundation

/// Aggregated, deduplicated results across multiple libraries, sorted by availability.
struct CrossLibrarySearchResponse: Equatable {
    let query: String
    let results: [MergedSearchResult]
    let searchedLibraries: [SearchedLibrary]
    let timestamp: Date

    /// A single book that may appear in multiple libraries, merged and ranked.
    struct MergedSearchResult: Identifiable, Equatable {
        let id: String
        let title: String
        let authors: [String]
        let summary: String?
        let categories: [String]
        let coverImageURL: URL?
        let thumbnailURL: URL?
        let published: Date?
        let publisher: String?
        let format: BookFormat
        let libraryResults: [LibrarySearchResult]

        /// Best availability across all libraries.
        var bestAvailability: AvailabilityStatus {
            libraryResults.map(\.availability).min() ?? .unavailable
        }

        /// The library result with the best availability.
        var bestResult: LibrarySearchResult? {
            libraryResults.sorted { $0.availability < $1.availability }.first
        }

        /// Number of libraries that have this title.
        var libraryCount: Int { libraryResults.count }
    }

    struct SearchedLibrary: Identifiable, Equatable {
        let id: String
        let name: String
        let succeeded: Bool
        let resultCount: Int
    }

    /// Total number of unique titles found.
    var totalResults: Int { results.count }

    /// Results filtered to only those available now.
    var availableNow: [MergedSearchResult] {
        results.filter { $0.bestAvailability == .availableNow }
    }
}
