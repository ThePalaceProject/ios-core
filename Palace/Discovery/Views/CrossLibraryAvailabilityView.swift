import SwiftUI

/// Shows which libraries have a book and each one's availability status.
struct CrossLibraryAvailabilityView: View {
    let results: [LibrarySearchResult]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(NSLocalizedString("Available at", comment: "Section header for library availability"))
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
                .accessibilityAddTraits(.isHeader)

            ForEach(sortedResults, id: \.id) { result in
                libraryRow(result)
            }
        }
    }

    private var sortedResults: [LibrarySearchResult] {
        results.sorted { $0.availability < $1.availability }
    }

    private func libraryRow(_ result: LibrarySearchResult) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(colorForAvailability(result.availability))
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)

            Text(result.libraryName)
                .font(.caption)
                .lineLimit(1)

            Spacer()

            availabilityDetail(result)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription(for: result))
    }

    @ViewBuilder
    private func availabilityDetail(_ result: LibrarySearchResult) -> some View {
        switch result.availability {
        case .availableNow:
            if let copies = result.copiesAvailable {
                Text(String(format: NSLocalizedString("%d available", comment: "Copies available count"), copies))
                    .font(.caption)
                    .foregroundColor(.green)
            } else {
                Text(DiscoveryStrings.Discovery.availableNow)
                    .font(.caption)
                    .foregroundColor(.green)
            }

        case .shortWait:
            if let position = result.holdPosition {
                Text(String(format: NSLocalizedString("Hold #%d", comment: "Hold queue position"), position))
                    .font(.caption)
                    .foregroundColor(.orange)
            } else {
                Text(DiscoveryStrings.Discovery.shortWait)
                    .font(.caption)
                    .foregroundColor(.orange)
            }

        case .longWait:
            if let position = result.holdPosition {
                Text(String(format: NSLocalizedString("Hold #%d", comment: "Hold queue position"), position))
                    .font(.caption)
                    .foregroundColor(.gray)
            } else {
                Text(DiscoveryStrings.Discovery.longWait)
                    .font(.caption)
                    .foregroundColor(.gray)
            }

        case .unavailable:
            Text(DiscoveryStrings.Discovery.unavailable)
                .font(.caption)
                .foregroundColor(.gray)
        }
    }

    private func colorForAvailability(_ status: AvailabilityStatus) -> Color {
        switch status {
        case .availableNow: return .green
        case .shortWait: return .orange
        case .longWait: return .gray
        case .unavailable: return .gray.opacity(0.5)
        }
    }

    private func accessibilityDescription(for result: LibrarySearchResult) -> String {
        var parts = [result.libraryName]
        parts.append(result.availability.accessibilityLabel)
        if let copies = result.copiesAvailable, result.availability == .availableNow {
            parts.append("\(copies) copies available")
        }
        if let position = result.holdPosition {
            parts.append("hold position \(position)")
        }
        return parts.joined(separator: ", ")
    }
}
