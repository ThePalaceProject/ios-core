import SwiftUI

/// Card showing a book recommendation with cover, metadata, AI reason, and availability.
struct RecommendationCard: View {
    private let title: String
    private let authors: [String]
    private let summary: String?
    private let reason: String?
    private let coverImageURL: URL?
    private let availability: AvailabilityStatus
    private let libraryName: String?
    private let libraryResults: [LibrarySearchResult]?

    /// Initialize from an AI recommendation.
    init(recommendation: DiscoveryRecommendation) {
        self.title = recommendation.title
        self.authors = recommendation.authors
        self.summary = recommendation.summary
        self.reason = recommendation.reason
        self.coverImageURL = recommendation.coverImageURL
        self.availability = recommendation.bestAvailability
        self.libraryName = recommendation.bestLibraryName
        self.libraryResults = nil
    }

    /// Initialize from a merged cross-library search result.
    init(mergedResult: CrossLibrarySearchResponse.MergedSearchResult) {
        self.title = mergedResult.title
        self.authors = mergedResult.authors
        self.summary = mergedResult.summary
        self.reason = nil
        self.coverImageURL = mergedResult.thumbnailURL ?? mergedResult.coverImageURL
        self.availability = mergedResult.bestAvailability
        self.libraryName = mergedResult.bestResult?.libraryName
        self.libraryResults = mergedResult.libraryResults
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                coverView
                metadataView
            }
            .padding(12)

            if let libraryResults, libraryResults.count > 1 {
                Divider()
                    .padding(.horizontal, 12)
                CrossLibraryAvailabilityView(results: libraryResults)
                    .padding(12)
            }
        }
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.08), radius: 4, x: 0, y: 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    // MARK: - Subviews

    private var coverView: some View {
        Group {
            if let url = coverImageURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    case .failure:
                        placeholderCover
                    case .empty:
                        ProgressView()
                            .frame(width: 80, height: 120)
                    @unknown default:
                        placeholderCover
                    }
                }
            } else {
                placeholderCover
            }
        }
        .frame(width: 80, height: 120)
        .cornerRadius(6)
        .clipped()
        .accessibilityHidden(true)
    }

    private var placeholderCover: some View {
        ZStack {
            Rectangle()
                .fill(Color(.systemGray4))
            Image(systemName: "book.closed")
                .font(.title2)
                .foregroundColor(.secondary)
        }
        .frame(width: 80, height: 120)
    }

    private var metadataView: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                Text(title)
                    .font(.headline)
                    .lineLimit(2)

                Spacer()

                availabilityBadge
            }

            if !authors.isEmpty {
                Text(authors.joined(separator: ", "))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            if let reason {
                Text(reason)
                    .font(.caption)
                    .foregroundColor(.accentColor)
                    .lineLimit(2)
                    .padding(.top, 2)
            }

            if let summary {
                Text(summary)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(3)
                    .padding(.top, 2)
            }

            if let libraryName {
                HStack(spacing: 4) {
                    Image(systemName: "building.columns")
                        .font(.caption2)
                    Text(libraryName)
                        .font(.caption)
                }
                .foregroundColor(.secondary)
                .padding(.top, 4)
            }
        }
    }

    private var availabilityBadge: some View {
        Text(availability.displayLabel)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(availabilityColor.opacity(0.15))
            .foregroundColor(availabilityColor)
            .cornerRadius(8)
            .accessibilityLabel(availability.accessibilityLabel)
    }

    private var availabilityColor: Color {
        switch availability {
        case .availableNow: return .green
        case .shortWait: return .orange
        case .longWait: return .gray
        case .unavailable: return .gray
        }
    }

    // MARK: - Accessibility

    private var accessibilityDescription: String {
        var parts = [title]
        if !authors.isEmpty {
            parts.append("by \(authors.joined(separator: ", "))")
        }
        parts.append(availability.accessibilityLabel)
        if let reason {
            parts.append(reason)
        }
        if let libraryName {
            parts.append("at \(libraryName)")
        }
        return parts.joined(separator: ". ")
    }
}
