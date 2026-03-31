import Foundation
import Combine

// MARK: - SearchView Model
@MainActor
class CatalogSearchViewModel: ObservableObject {
    @Published var searchQuery: String = ""
    @Published var filteredBooks: [TPPBook] = []
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var nextPageURL: URL?
    @Published var isLoadingMore: Bool = false

    /// Unique identifier that changes only when a new search is performed.
    /// Use this to trigger scroll-to-top behavior in the view.
    /// Does NOT change during pagination or registry updates.
    @Published private(set) var searchId: UUID = UUID()

    private var allBooks: [TPPBook] = []
    private let repository: CatalogRepositoryProtocol
    private let baseURL: () -> URL?
    private var searchTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private let debounceInterval: TimeInterval
    private let announcements: TPPAccessibilityAnnouncementCenter
    private let bookRegistry: TPPBookRegistryProvider

    init(
        repository: CatalogRepositoryProtocol,
        baseURL: @escaping () -> URL?,
        debounceInterval: TimeInterval = 0.1,
        announcements: TPPAccessibilityAnnouncementCenter = TPPAccessibilityAnnouncementCenter(),
        bookRegistry: TPPBookRegistryProvider = TPPBookRegistry.shared
    ) {
        self.repository = repository
        self.baseURL = baseURL
        self.debounceInterval = debounceInterval
        self.announcements = announcements
        self.bookRegistry = bookRegistry
    }

    deinit {
        debounceTask?.cancel()
        searchTask?.cancel()
    }

    func updateBooks(_ books: [TPPBook]) {
        allBooks = books
        if searchQuery.isEmpty {
            filteredBooks = books
        }
    }

    func updateSearchQuery(_ query: String) {
        searchQuery = query

        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(self.debounceInterval * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self.performSearch()
        }
    }

    func clearSearch() {
        searchQuery = ""
        debounceTask?.cancel()
        searchTask?.cancel()
        isLoading = false
        errorMessage = nil
        filteredBooks = allBooks
        nextPageURL = nil
        isLoadingMore = false
        // Generate new searchId to scroll to top of restored books
        searchId = UUID()
    }

    private func performSearch() {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)

        // Cancel any existing search task
        searchTask?.cancel()

        guard !query.isEmpty else {
            // Show preloaded books when no search query
            filteredBooks = allBooks
            nextPageURL = nil
            isLoading = false
            return
        }

        guard let url = baseURL() else {
            filteredBooks = []
            nextPageURL = nil
            isLoading = false
            return
        }

        // Clear pagination for new search
        nextPageURL = nil
        isLoadingMore = false
        isLoading = true

        // Generate new searchId for new search - triggers scroll to top
        searchId = UUID()

        searchTask = Task { [weak self] in
            // Ensure isLoading is cleared on all exit paths
            defer { self?.isLoading = false }

            do {
                guard let self, !Task.isCancelled else { return }

                let feed = try await self.repository.search(query: query, baseURL: url)

                guard !Task.isCancelled else { return }

                if let feed = feed {
                    // Extract books from search results and map through registry for correct button states
                    let feedObjc = feed.opdsFeed
                    var searchResults: [TPPBook] = []

                    if let opdsEntries = feedObjc.entries as? [TPPOPDSEntry] {
                        searchResults = opdsEntries.compactMap { CatalogViewModel.makeBook(from: $0) }
                    }

                    self.filteredBooks = searchResults
                    self.extractNextPageURL(from: feedObjc)

                    // PP-3673: Announce search results to VoiceOver without moving focus
                    self.announcements.announceSearchResults(query: query, count: searchResults.count)
                } else {
                    self.filteredBooks = []
                    self.nextPageURL = nil

                    // PP-3673: Announce no results
                    self.announcements.announceSearchResults(query: query, count: 0)
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.filteredBooks = []
                self?.nextPageURL = nil

                // PP-3673: Announce search failure
                self?.announcements.announceSearchFailed()
            }
        }
    }

    // MARK: - Pagination

    private func extractNextPageURL(from feed: TPPOPDSFeed) {
        guard let links = feed.links as? [TPPOPDSLink] else {
            nextPageURL = nil
            return
        }

        for link in links {
            if link.rel == "next" {
                nextPageURL = link.href
                return
            }
        }

        nextPageURL = nil
    }

    func loadNextPage() async {
        guard let nextURL = nextPageURL, !isLoadingMore else { return }

        isLoadingMore = true
        defer { isLoadingMore = false }

        do {
            guard let feed = try await repository.fetchFeed(at: nextURL) else {
                return
            }

            let feedObjc = feed.opdsFeed
            extractNextPageURL(from: feedObjc)

            if let entries = feedObjc.entries as? [TPPOPDSEntry] {
                let newBooks = entries.compactMap { CatalogViewModel.makeBook(from: $0) }
                filteredBooks.append(contentsOf: newBooks)

                // PP-3673: Announce additional results loaded
                announcements.announceAdditionalResultsLoaded(count: newBooks.count)
            }
        } catch {
            Log.error(#file, "Failed to load next page of search results: \(error.localizedDescription)")
        }
    }

    // MARK: - Registry Sync

    /// Refresh visible books with registry state (for downloaded/borrowed books).
    /// Works on a snapshot of the array to prevent issues if filteredBooks is
    /// mutated by a concurrent SwiftUI render cycle.
    func applyRegistryUpdates(changedIdentifier: String?) {
        let currentBooks = filteredBooks
        guard !currentBooks.isEmpty else { return }

        var books = currentBooks
        var anyChanged = false
        for idx in books.indices {
            let book = books[idx]
            if let changedIdentifier, book.identifier != changedIdentifier { continue }

            if let registryBook = bookRegistry.book(forIdentifier: book.identifier) {
                books[idx] = registryBook
                anyChanged = true
            } else {
                if let originalBook = allBooks.first(where: { $0.identifier == book.identifier }) {
                    books[idx] = originalBook
                }
                BookCellModelCache.shared.invalidate(for: book.identifier)
                anyChanged = true
            }
        }
        if anyChanged { filteredBooks = books }
    }
}
