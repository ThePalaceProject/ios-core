import SwiftUI

/// Full search results view with sort and filter controls.
struct SearchResultsView: View {
    @ObservedObject var viewModel: SearchResultsViewModel
    let onBorrow: (LibrarySearchResult) -> Void

    var body: some View {
        VStack(spacing: 0) {
            sortBar
            Divider()

            if viewModel.displayResults.isEmpty {
                emptyState
            } else {
                resultsList
            }
        }
    }

    // MARK: - Sort Bar

    private var sortBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(SearchResultsViewModel.SortOption.allCases) { option in
                    Button {
                        viewModel.sortOption = option
                    } label: {
                        Text(option.displayName)
                            .font(.caption.weight(viewModel.sortOption == option ? .semibold : .regular))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(viewModel.sortOption == option ? Color.accentColor.opacity(0.15) : Color(.systemGray6))
                            .foregroundColor(viewModel.sortOption == option ? .accentColor : .primary)
                            .cornerRadius(16)
                    }
                    .accessibilityLabel("\(NSLocalizedString("Sort by", comment: "")) \(option.displayName)")
                    .accessibilityAddTraits(viewModel.sortOption == option ? .isSelected : [])
                }

                Divider()
                    .frame(height: 20)

                ForEach(SearchResultsViewModel.AvailabilityFilter.allCases) { filter in
                    Button {
                        viewModel.availabilityFilter = filter
                    } label: {
                        Text(filter.displayName)
                            .font(.caption.weight(viewModel.availabilityFilter == filter ? .semibold : .regular))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(viewModel.availabilityFilter == filter ? Color.accentColor.opacity(0.15) : Color(.systemGray6))
                            .foregroundColor(viewModel.availabilityFilter == filter ? .accentColor : .primary)
                            .cornerRadius(16)
                    }
                    .accessibilityLabel("\(NSLocalizedString("Filter", comment: "")) \(filter.displayName)")
                    .accessibilityAddTraits(viewModel.availabilityFilter == filter ? .isSelected : [])
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Results List

    private var resultsList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(viewModel.displayResults) { result in
                    RecommendationCard(mergedResult: result)
                }
            }
            .padding()
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.largeTitle)
                .foregroundColor(.secondary)
            Text(NSLocalizedString("No results match your filters", comment: "Empty filter state"))
                .font(.headline)
            Button(NSLocalizedString("Clear Filters", comment: "Button")) {
                viewModel.clearFilters()
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 60)
        .accessibilityElement(children: .combine)
    }
}
