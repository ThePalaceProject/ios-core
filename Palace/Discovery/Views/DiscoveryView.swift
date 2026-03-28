import SwiftUI

/// Main discovery tab view with search, mood chips, and results.
struct DiscoveryView: View {
    @StateObject private var viewModel: DiscoveryViewModel
    @StateObject private var resultsViewModel = SearchResultsViewModel()
    @State private var showFilters = false

    init(viewModel: DiscoveryViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    searchBar
                    moodChips
                    content
                }
                .padding(.horizontal)
                .padding(.top, 8)
            }
            .navigationTitle(DiscoveryStrings.Discovery.discover)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !viewModel.searchResults.isEmpty {
                        Button {
                            showFilters.toggle()
                        } label: {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                                .accessibilityLabel(NSLocalizedString("Filter results", comment: "Button"))
                        }
                    }
                }
            }
            .sheet(isPresented: $showFilters) {
                filterSheet
            }
            .onChange(of: viewModel.searchResults) { results in
                resultsViewModel.updateResults(results, libraries: viewModel.searchedLibraries)
            }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 12) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField(DiscoveryStrings.Discovery.searchPlaceholder, text: Binding(
                    get: { viewModel.searchQuery },
                    set: { viewModel.updateSearchQuery($0) }
                ))
                .textFieldStyle(.plain)
                .submitLabel(.search)
                .onSubmit { viewModel.search() }
                .accessibilityLabel(DiscoveryStrings.Discovery.searchPlaceholder)

                if !viewModel.searchQuery.isEmpty {
                    Button {
                        viewModel.updateSearchQuery("")
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .accessibilityLabel(NSLocalizedString("Clear search", comment: "Button"))
                }
            }
            .padding(10)
            .background(Color(.systemGray6))
            .cornerRadius(10)

            if viewModel.isSearching {
                ProgressView()
                    .accessibilityLabel(NSLocalizedString("Searching", comment: "Loading indicator"))
            }
        }
    }

    // MARK: - Mood Chips

    private var moodChips: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    surpriseMeButton

                    ForEach(ReadingMood.allCases) { mood in
                        moodChip(mood)
                    }
                }
            }
        }
    }

    private var surpriseMeButton: some View {
        Button {
            viewModel.surpriseMe()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "sparkles")
                Text(DiscoveryStrings.Discovery.surpriseMe)
            }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.accentColor.opacity(0.15))
            .foregroundColor(.accentColor)
            .cornerRadius(20)
        }
        .accessibilityLabel(DiscoveryStrings.Discovery.surpriseMe)
        .accessibilityHint(NSLocalizedString("Get personalized book recommendations based on your reading history", comment: "Accessibility hint"))
    }

    private func moodChip(_ mood: ReadingMood) -> some View {
        Button {
            viewModel.selectMood(mood)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: mood.systemImageName)
                    .font(.caption)
                Text(mood.displayName)
            }
            .font(.subheadline)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(viewModel.selectedMood == mood ? Color.accentColor : Color(.systemGray5))
            .foregroundColor(viewModel.selectedMood == mood ? .white : .primary)
            .cornerRadius(20)
        }
        .accessibilityLabel(mood.displayName)
        .accessibilityAddTraits(viewModel.selectedMood == mood ? .isSelected : [])
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if viewModel.showError, let error = viewModel.errorMessage {
            errorView(error)
        } else if viewModel.isSearching || viewModel.isLoadingRecommendations {
            loadingView
        } else if !resultsViewModel.displayResults.isEmpty {
            searchResultsSection
        } else if !viewModel.recommendations.isEmpty {
            recommendationsSection
        } else if !viewModel.searchQuery.isEmpty {
            emptySearchView
        } else {
            welcomeView
        }
    }

    private var searchResultsSection: some View {
        LazyVStack(spacing: 12) {
            HStack {
                Text(DiscoveryStrings.Discovery.searchResults)
                    .font(.headline)
                Spacer()
                Text("\(resultsViewModel.displayResults.count)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .accessibilityElement(children: .combine)

            ForEach(resultsViewModel.displayResults) { result in
                RecommendationCard(mergedResult: result)
            }
        }
    }

    private var recommendationsSection: some View {
        LazyVStack(spacing: 12) {
            HStack {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                        .foregroundColor(.accentColor)
                    Text(DiscoveryStrings.Discovery.recommendations)
                        .font(.headline)
                }
                Spacer()
                if viewModel.isAIAvailable {
                    Text(DiscoveryStrings.Discovery.aiPowered)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color(.systemGray6))
                        .cornerRadius(8)
                }
            }
            .accessibilityElement(children: .combine)

            ForEach(viewModel.recommendations) { recommendation in
                RecommendationCard(recommendation: recommendation)
            }
        }
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)
            Text(NSLocalizedString("Searching your libraries...", comment: "Loading state"))
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(NSLocalizedString("Searching your libraries", comment: "Loading"))
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundColor(.orange)
            Text(DiscoveryStrings.Discovery.errorTitle)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button(DiscoveryStrings.Discovery.retry) {
                viewModel.search()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
        .accessibilityElement(children: .combine)
    }

    private var emptySearchView: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.largeTitle)
                .foregroundColor(.secondary)
            Text(DiscoveryStrings.Discovery.noResults)
                .font(.headline)
            Text(DiscoveryStrings.Discovery.tryDifferentSearch)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
        .accessibilityElement(children: .combine)
    }

    private var welcomeView: some View {
        VStack(spacing: 16) {
            Image(systemName: "books.vertical")
                .font(.system(size: 48))
                .foregroundColor(.accentColor.opacity(0.6))
            Text(NSLocalizedString("Discover your next great read", comment: "Welcome title"))
                .font(.title2.weight(.semibold))
            Text(NSLocalizedString("Search across all your libraries or pick a mood to get started.", comment: "Welcome subtitle"))
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Filter Sheet

    private var filterSheet: some View {
        NavigationView {
            List {
                Section(NSLocalizedString("Sort By", comment: "Filter section")) {
                    ForEach(SearchResultsViewModel.SortOption.allCases) { option in
                        Button {
                            resultsViewModel.sortOption = option
                        } label: {
                            HStack {
                                Text(option.displayName)
                                    .foregroundColor(.primary)
                                Spacer()
                                if resultsViewModel.sortOption == option {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.accentColor)
                                }
                            }
                        }
                        .accessibilityAddTraits(resultsViewModel.sortOption == option ? .isSelected : [])
                    }
                }

                Section(NSLocalizedString("Availability", comment: "Filter section")) {
                    ForEach(SearchResultsViewModel.AvailabilityFilter.allCases) { filter in
                        Button {
                            resultsViewModel.availabilityFilter = filter
                        } label: {
                            HStack {
                                Text(filter.displayName)
                                    .foregroundColor(.primary)
                                Spacer()
                                if resultsViewModel.availabilityFilter == filter {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.accentColor)
                                }
                            }
                        }
                        .accessibilityAddTraits(resultsViewModel.availabilityFilter == filter ? .isSelected : [])
                    }
                }

                if !resultsViewModel.availableLibraries.isEmpty {
                    Section(NSLocalizedString("Library", comment: "Filter section")) {
                        Button {
                            resultsViewModel.libraryFilter = nil
                        } label: {
                            HStack {
                                Text(DiscoveryStrings.Discovery.filterAll)
                                    .foregroundColor(.primary)
                                Spacer()
                                if resultsViewModel.libraryFilter == nil {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.accentColor)
                                }
                            }
                        }

                        ForEach(resultsViewModel.availableLibraries) { library in
                            Button {
                                resultsViewModel.libraryFilter = library.id
                            } label: {
                                HStack {
                                    Text(library.name)
                                        .foregroundColor(.primary)
                                    Spacer()
                                    if resultsViewModel.libraryFilter == library.id {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(.accentColor)
                                    }
                                }
                            }
                        }
                    }
                }

                Section(NSLocalizedString("Format", comment: "Filter section")) {
                    Button {
                        resultsViewModel.formatFilter = nil
                    } label: {
                        HStack {
                            Text(DiscoveryStrings.Discovery.filterAll)
                                .foregroundColor(.primary)
                            Spacer()
                            if resultsViewModel.formatFilter == nil {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.accentColor)
                            }
                        }
                    }

                    ForEach(BookFormat.allCases, id: \.rawValue) { format in
                        Button {
                            resultsViewModel.formatFilter = format
                        } label: {
                            HStack {
                                Text(format.displayName)
                                    .foregroundColor(.primary)
                                Spacer()
                                if resultsViewModel.formatFilter == format {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.accentColor)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(NSLocalizedString("Filters", comment: "Filter sheet title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(NSLocalizedString("Reset", comment: "Reset filters")) {
                        resultsViewModel.clearFilters()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(NSLocalizedString("Done", comment: "Close filter sheet")) {
                        showFilters = false
                    }
                }
            }
        }
    }
}
