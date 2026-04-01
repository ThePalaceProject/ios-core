import Foundation
import Combine

/// Main ViewModel for the Discovery tab.
@MainActor
final class DiscoveryViewModel: ObservableObject {
    // MARK: - Published State

    @Published var searchQuery: String = ""
    @Published var recommendations: [DiscoveryRecommendation] = []
    @Published var searchResults: [CrossLibrarySearchResponse.MergedSearchResult] = []
    @Published var searchedLibraries: [CrossLibrarySearchResponse.SearchedLibrary] = []
    @Published var isSearching: Bool = false
    @Published var isLoadingRecommendations: Bool = false
    @Published var selectedMood: ReadingMood? = nil
    @Published var errorMessage: String?
    @Published var showError: Bool = false

    /// Whether the AI discovery service is available.
    var isAIAvailable: Bool { discoveryService.isAvailable }

    // MARK: - Dependencies

    private let discoveryService: DiscoveryServiceProtocol
    private let searchService: CrossLibrarySearchService
    private let bookRegistry: TPPBookRegistryProvider

    // MARK: - Private State

    private var searchTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private let debounceInterval: TimeInterval
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    init(
        discoveryService: DiscoveryServiceProtocol,
        searchService: CrossLibrarySearchService,
        bookRegistry: TPPBookRegistryProvider = TPPBookRegistry.shared,
        debounceInterval: TimeInterval = 0.3
    ) {
        self.discoveryService = discoveryService
        self.searchService = searchService
        self.bookRegistry = bookRegistry
        self.debounceInterval = debounceInterval
    }

    deinit {
        searchTask?.cancel()
        debounceTask?.cancel()
    }

    // MARK: - Search

    func updateSearchQuery(_ query: String) {
        searchQuery = query
        errorMessage = nil
        showError = false

        debounceTask?.cancel()

        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            searchTask?.cancel()
            isSearching = false
            searchResults = []
            searchedLibraries = []
            return
        }

        debounceTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(self.debounceInterval * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self.performSearch()
        }
    }

    func search() {
        debounceTask?.cancel()
        Task { await performSearch() }
    }

    private func performSearch() async {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        searchTask?.cancel()

        searchTask = Task { [weak self] in
            guard let self else { return }
            self.isSearching = true
            defer { self.isSearching = false }

            do {
                let response = try await self.searchService.search(query: query)
                guard !Task.isCancelled else { return }
                self.searchResults = response.results
                self.searchedLibraries = response.searchedLibraries
                self.errorMessage = nil
                self.showError = false
            } catch is CancellationError {
                // Silently ignore cancellation
            } catch let error as DiscoveryError {
                guard !Task.isCancelled else { return }
                self.searchResults = []
                self.searchedLibraries = []
                self.errorMessage = error.localizedDescription
                self.showError = true
            } catch {
                guard !Task.isCancelled else { return }
                self.searchResults = []
                self.searchedLibraries = []
                self.errorMessage = error.localizedDescription
                self.showError = true
            }
        }

        await searchTask?.value
    }

    // MARK: - Recommendations

    func getRecommendations() {
        Task { await fetchRecommendations() }
    }

    func selectMood(_ mood: ReadingMood?) {
        if selectedMood == mood {
            selectedMood = nil
        } else {
            selectedMood = mood
        }
        getRecommendations()
    }

    func surpriseMe() {
        selectedMood = nil
        searchQuery = ""
        searchResults = []
        Task { await fetchSurpriseMeRecommendations() }
    }

    private func fetchRecommendations() async {
        isLoadingRecommendations = true
        defer { isLoadingRecommendations = false }

        let history = buildReadingHistory()
        let prompt = DiscoveryPrompt(
            freeText: searchQuery.isEmpty ? nil : searchQuery,
            mood: selectedMood,
            genres: [],
            readingHistory: history
        )

        do {
            var recs = try await discoveryService.getRecommendations(prompt: prompt)
            guard !Task.isCancelled else { return }

            // Enrich with availability data
            recs = await searchService.checkAvailability(for: recs)
            guard !Task.isCancelled else { return }

            recommendations = recs
            errorMessage = nil
            showError = false
        } catch is CancellationError {
            // Silently ignore
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func fetchSurpriseMeRecommendations() async {
        isLoadingRecommendations = true
        defer { isLoadingRecommendations = false }

        let history = buildReadingHistory()
        let prompt = DiscoveryPrompt.surpriseMe(history: history)

        do {
            var recs = try await discoveryService.getRecommendations(prompt: prompt)
            guard !Task.isCancelled else { return }

            recs = await searchService.checkAvailability(for: recs)
            guard !Task.isCancelled else { return }

            recommendations = recs
            errorMessage = nil
            showError = false
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    // MARK: - Borrow

    func borrowBook(_ result: LibrarySearchResult) {
        guard let book = result.book else {
            Log.warn(#file, "Cannot borrow: no TPPBook for result \(result.title)")
            return
        }

        // Add to registry and trigger download through existing infrastructure
        bookRegistry.addBook(
            book,
            location: nil,
            state: .downloadNeeded,
            fulfillmentId: nil,
            readiumBookmarks: nil,
            genericBookmarks: nil
        )

        if let borrowURL = result.borrowURL {
            // Use the existing network infrastructure to borrow
            TPPOPDSFeed.withURL(borrowURL, shouldResetCache: false, useTokenIfAvailable: true) { _, _ in
                // Borrow request sent; registry will update state via existing observers
            }
        }
    }

    // MARK: - Helpers

    private func buildReadingHistory() -> [ReadingHistoryItem] {
        var history: [ReadingHistoryItem] = []

        // Synchronously snapshot current registry contents via Combine's first()
        var cancellable: AnyCancellable?
        cancellable = bookRegistry.registryPublisher
            .first()
            .sink { records in
                for (_, record) in records {
                    history.append(ReadingHistoryItem(book: record.book))
                }
                cancellable?.cancel()
            }

        return Array(history.prefix(20))
    }
}
