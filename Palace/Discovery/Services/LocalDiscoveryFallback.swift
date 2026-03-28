import Foundation

/// Offline keyword search across cached catalog data and reading history.
/// Used as a fallback when the Claude API is unavailable.
final class LocalDiscoveryFallback: DiscoveryServiceProtocol, @unchecked Sendable {
    private let bookRegistry: TPPBookRegistryProvider

    var isAvailable: Bool { true }

    init(bookRegistry: TPPBookRegistryProvider = TPPBookRegistry.shared) {
        self.bookRegistry = bookRegistry
    }

    func getRecommendations(prompt: DiscoveryPrompt) async throws -> [DiscoveryRecommendation] {
        // Build recommendations from reading history and mood
        var recommendations: [DiscoveryRecommendation] = []

        // If there's a mood, generate category-based suggestions
        if let mood = prompt.mood {
            let moodRecs = recommendationsForMood(mood, history: prompt.readingHistory)
            recommendations.append(contentsOf: moodRecs)
        }

        // If there are genres, suggest based on those
        if !prompt.genres.isEmpty {
            let genreRecs = recommendationsForGenres(prompt.genres, history: prompt.readingHistory)
            recommendations.append(contentsOf: genreRecs)
        }

        // If there's free text, match against history categories
        if let text = prompt.freeText, !text.isEmpty {
            let textRecs = recommendationsForText(text, history: prompt.readingHistory)
            recommendations.append(contentsOf: textRecs)
        }

        // If nothing specific, use history to suggest "more like this"
        if recommendations.isEmpty && !prompt.readingHistory.isEmpty {
            let historyRecs = recommendationsFromHistory(prompt.readingHistory)
            recommendations.append(contentsOf: historyRecs)
        }

        // Deduplicate by ID and limit
        var seen = Set<String>()
        recommendations = recommendations.filter { rec in
            guard !seen.contains(rec.id) else { return false }
            seen.insert(rec.id)
            return true
        }

        return Array(recommendations.prefix(prompt.maxResults))
    }

    // MARK: - Local Recommendation Strategies

    private func recommendationsForMood(_ mood: ReadingMood, history: [ReadingHistoryItem]) -> [DiscoveryRecommendation] {
        let categoriesForMood = moodToCategoryMapping(mood)
        let historyCategories = Set(history.flatMap(\.categories))

        // Recommend categories that match the mood but aren't already heavily read
        return categoriesForMood.enumerated().map { index, category in
            let isNew = !historyCategories.contains(category)
            return DiscoveryRecommendation(
                id: "local-mood-\(mood.rawValue)-\(index)",
                title: "Explore \(category)",
                authors: [],
                summary: "Browse \(category.lowercased()) books matching your \(mood.displayName.lowercased()) mood.",
                coverImageURL: nil,
                reason: isNew
                    ? "A fresh genre to match your \(mood.displayName.lowercased()) mood"
                    : "More from a genre you enjoy, perfect for \(mood.displayName.lowercased()) reading",
                confidenceScore: isNew ? 0.6 : 0.8,
                categories: [category],
                availability: []
            )
        }
    }

    private func recommendationsForGenres(_ genres: [String], history: [ReadingHistoryItem]) -> [DiscoveryRecommendation] {
        genres.enumerated().map { index, genre in
            DiscoveryRecommendation(
                id: "local-genre-\(index)",
                title: "More \(genre)",
                authors: [],
                summary: "Discover more books in \(genre).",
                coverImageURL: nil,
                reason: "Based on your interest in \(genre)",
                confidenceScore: 0.7,
                categories: [genre],
                availability: []
            )
        }
    }

    private func recommendationsForText(_ text: String, history: [ReadingHistoryItem]) -> [DiscoveryRecommendation] {
        let lowered = text.lowercased()

        // Match against history items
        let matches = history.filter { item in
            item.title.lowercased().contains(lowered) ||
            item.authors.contains { $0.lowercased().contains(lowered) } ||
            item.categories.contains { $0.lowercased().contains(lowered) }
        }

        return matches.enumerated().map { index, item in
            DiscoveryRecommendation(
                id: "local-text-\(index)",
                title: "More like \"\(item.title)\"",
                authors: item.authors,
                summary: "Based on your search for \"\(text)\".",
                coverImageURL: nil,
                reason: "Similar to \"\(item.title)\" which you've read",
                confidenceScore: 0.5,
                categories: item.categories,
                availability: []
            )
        }
    }

    private func recommendationsFromHistory(_ history: [ReadingHistoryItem]) -> [DiscoveryRecommendation] {
        // Aggregate categories from history and suggest the most common
        var categoryFrequency: [String: Int] = [:]
        for item in history {
            for category in item.categories {
                categoryFrequency[category, default: 0] += 1
            }
        }

        let topCategories = categoryFrequency
            .sorted { $0.value > $1.value }
            .prefix(5)
            .map(\.key)

        return topCategories.enumerated().map { index, category in
            DiscoveryRecommendation(
                id: "local-history-\(index)",
                title: "More \(category)",
                authors: [],
                summary: "You've read \(categoryFrequency[category] ?? 0) books in this category.",
                coverImageURL: nil,
                reason: "One of your most-read categories",
                confidenceScore: 0.7,
                categories: [category],
                availability: []
            )
        }
    }

    private func moodToCategoryMapping(_ mood: ReadingMood) -> [String] {
        switch mood {
        case .relaxing:
            return ["Romance", "Cozy Mystery", "Poetry", "Humor", "Gardening"]
        case .thrilling:
            return ["Thriller", "Mystery", "Horror", "Suspense", "Crime Fiction"]
        case .educational:
            return ["Science", "History", "Technology", "Philosophy", "Biography"]
        case .inspiring:
            return ["Self-Help", "Memoir", "Spirituality", "Leadership", "Creativity"]
        case .funny:
            return ["Humor", "Comedy", "Satire", "Comic Fiction", "Essays"]
        case .shortReads:
            return ["Short Stories", "Novellas", "Essays", "Poetry", "Flash Fiction"]
        case .deepDive:
            return ["Literary Fiction", "Historical Fiction", "Epic Fantasy", "Nonfiction", "Philosophy"]
        }
    }
}
