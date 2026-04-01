import Foundation
import Combine

/// ViewModel for the detailed search results view with filtering and sorting.
@MainActor
final class SearchResultsViewModel: ObservableObject {
    // MARK: - Published State

    @Published var sortOption: SortOption = .relevance
    @Published var availabilityFilter: AvailabilityFilter = .all
    @Published var libraryFilter: String? = nil
    @Published var formatFilter: BookFormat? = nil

    /// The filtered and sorted results to display.
    @Published private(set) var displayResults: [CrossLibrarySearchResponse.MergedSearchResult] = []

    // MARK: - Types

    enum SortOption: String, CaseIterable, Identifiable {
        case relevance
        case availability
        case date
        case title

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .relevance: return DiscoveryStrings.Discovery.sortRelevance
            case .availability: return DiscoveryStrings.Discovery.sortAvailability
            case .date: return NSLocalizedString("Date", comment: "Sort by date")
            case .title: return NSLocalizedString("Title", comment: "Sort by title")
            }
        }
    }

    enum AvailabilityFilter: String, CaseIterable, Identifiable {
        case all
        case availableNow
        case shortWait

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .all: return DiscoveryStrings.Discovery.filterAll
            case .availableNow: return DiscoveryStrings.Discovery.filterAvailableNow
            case .shortWait: return DiscoveryStrings.Discovery.shortWait
            }
        }
    }

    // MARK: - Private

    private var allResults: [CrossLibrarySearchResponse.MergedSearchResult] = []
    private var allLibraries: [CrossLibrarySearchResponse.SearchedLibrary] = []
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    init() {
        // Observe filter/sort changes and recompute display results
        Publishers.CombineLatest4(
            $sortOption,
            $availabilityFilter,
            $libraryFilter,
            $formatFilter
        )
        .debounce(for: .milliseconds(50), scheduler: DispatchQueue.main)
        .sink { [weak self] _, _, _, _ in
            self?.applyFiltersAndSort()
        }
        .store(in: &cancellables)
    }

    // MARK: - Input

    func updateResults(
        _ results: [CrossLibrarySearchResponse.MergedSearchResult],
        libraries: [CrossLibrarySearchResponse.SearchedLibrary]
    ) {
        allResults = results
        allLibraries = libraries
        applyFiltersAndSort()
    }

    /// Available libraries for the filter picker.
    var availableLibraries: [CrossLibrarySearchResponse.SearchedLibrary] {
        allLibraries.filter(\.succeeded)
    }

    // MARK: - Filtering & Sorting

    private func applyFiltersAndSort() {
        var filtered = allResults

        // Apply availability filter
        switch availabilityFilter {
        case .all:
            break
        case .availableNow:
            filtered = filtered.filter { $0.bestAvailability == .availableNow }
        case .shortWait:
            filtered = filtered.filter { $0.bestAvailability <= .shortWait }
        }

        // Apply library filter
        if let libraryId = libraryFilter {
            filtered = filtered.filter { result in
                result.libraryResults.contains { $0.libraryId == libraryId }
            }
        }

        // Apply format filter
        if let format = formatFilter {
            filtered = filtered.filter { $0.format == format }
        }

        // Apply sort
        switch sortOption {
        case .relevance:
            // Default order from search (already ranked by relevance + availability)
            break
        case .availability:
            filtered.sort { $0.bestAvailability < $1.bestAvailability }
        case .date:
            filtered.sort { a, b in
                let dateA = a.published ?? .distantPast
                let dateB = b.published ?? .distantPast
                return dateA > dateB
            }
        case .title:
            filtered.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }

        displayResults = filtered
    }

    func clearFilters() {
        sortOption = .relevance
        availabilityFilter = .all
        libraryFilter = nil
        formatFilter = nil
    }
}
