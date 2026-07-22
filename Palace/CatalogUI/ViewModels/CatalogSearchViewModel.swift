import Foundation
import Combine
import PalaceLogging
import PalaceCatalog

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

    /// True once at least one search has finished (success, empty result, or error)
    /// for the current `searchQuery`. Reset by `clearSearch()` and by transitions
    /// back to an empty query. Used by the view to distinguish "no search yet"
    /// (render nothing / the unfiltered catalog) from "search returned zero results"
    /// (render the no-results empty state) — BUG-003.
    @Published private(set) var hasCompletedSearch: Bool = false

    /// Format entry points extracted from the groups feed (e.g. All, eBooks, Audiobooks).
    /// Empty when the current feed has no entry-point facets.
    @Published private(set) var formatEntries: [SearchFormatEntry] = []

    /// Index into `formatEntries` for the currently selected format.
    @Published private(set) var selectedFormatIndex: Int = 0

    private var allBooks: [TPPBook] = []
    private let repository: CatalogRepositoryProtocol
    private let baseURL: () -> URL?
    private var searchTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var entryPointLoadTask: Task<Void, Never>?
    private let debounceInterval: TimeInterval
    private let announcements: TPPAccessibilityAnnouncementCenter
    private let bookRegistry: TPPBookRegistryProvider
    private let bookCellModelCache: BookCellModelCache

    /// Cache mapping groupsFeedURL.absoluteString → OpenSearch descriptor URL.
    /// Avoids re-fetching the groups feed on repeated searches with the same format.
    private var searchDescriptorURLCache: [String: URL] = [:]

    /// Entry-point facet links extracted from the most recent search results.
    /// Keys are format titles (lowercased); values are direct search URLs with the query baked in.
    /// Cleared when the query changes, but preserved across format switches for the same query.
    private var postSearchFacets: [String: URL] = [:]

    /// The query string from the most recently executed search. Used to detect whether
    /// `performSearch()` is re-running for the same query (format switch) or a new one.
    private var lastSearchedQuery: String = ""

    init(
        repository: CatalogRepositoryProtocol,
        baseURL: @escaping () -> URL?,
        debounceInterval: TimeInterval = 0.4,
        announcements: TPPAccessibilityAnnouncementCenter = TPPAccessibilityAnnouncementCenter(),
        bookRegistry: TPPBookRegistryProvider = AppContainer.production().bookRegistry,
        bookCellModelCache: BookCellModelCache
    ) {
        self.repository = repository
        self.baseURL = baseURL
        self.debounceInterval = debounceInterval
        self.announcements = announcements
        self.bookRegistry = bookRegistry
        self.bookCellModelCache = bookCellModelCache
    }

    deinit {
        debounceTask?.cancel()
        searchTask?.cancel()
        entryPointLoadTask?.cancel()
    }

    /// True iff the view should render the "no results" empty state:
    /// a search has actually completed for a non-empty query, the request is
    /// not in flight, and the results list is empty. BUG-003.
    var shouldShowNoResultsState: Bool {
        hasCompletedSearch
            && !isLoading
            && filteredBooks.isEmpty
            && !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Test-only hook to flip `hasCompletedSearch` without driving a full
    /// repository round-trip. The view model is `@MainActor`, so this is
    /// inherently main-thread-only; we keep it `internal` and clearly named so
    /// production callers never reach for it.
    func markSearchCompletedForTesting() {
        hasCompletedSearch = true
    }

    /// Test-only deterministic JOIN over the view model's in-flight async work
    /// (debounce → search, entry-point loading). Awaiting this replaces the
    /// wall-clock `Task.sleep` / `fulfillment(timeout:)` polls the tests used to
    /// observe a fire-and-forget search: under parallel-CI sim clones a fixed
    /// deadline STARVES and fails, whereas awaiting the actual `Task` values is
    /// timing-independent.
    ///
    /// The chain is: `updateSearchQuery` spawns `debounceTask`, which sleeps then
    /// *synchronously* calls `performSearch()` at its tail — and `performSearch()`
    /// assigns `searchTask` synchronously. So awaiting `debounceTask.value` first
    /// guarantees `searchTask` is assigned before we read it; then awaiting
    /// `searchTask.value` joins the search + announce side effects. We re-snapshot
    /// in a loop because a completed search can enqueue no further debounce, but a
    /// format switch (`selectFormat`) cancels the debounce and calls
    /// `performSearch()` directly — awaiting whatever handles are live until they
    /// stop changing converges on "all observed async work done".
    ///
    /// The view model is `@MainActor`, so the property reads below are inherently
    /// main-thread-serialized — no lock needed. RELEASE behavior is byte-identical:
    /// production never calls this and the retained `Task` handles it awaits are
    /// the same ones the VM already stores for cancellation.
    func _awaitInFlightWorkForTesting() async {
        // `Task` is a value type whose `==` compares the underlying task identity,
        // so we track the last-awaited handle per slot and re-await only when a new
        // Task has replaced it (debounce cancel/replace, a fresh performSearch, etc.).
        var previousDebounce: Task<Void, Never>?
        var previousSearch: Task<Void, Never>?
        var previousEntryPoint: Task<Void, Never>?
        while true {
            let debounce = debounceTask
            if debounce != previousDebounce {
                previousDebounce = debounce
                _ = await debounce?.value
                continue
            }
            // debounceTask has settled → performSearch() has run and assigned
            // searchTask (if a search was warranted).
            let search = searchTask
            if search != previousSearch {
                previousSearch = search
                _ = await search?.value
                continue
            }
            let entryPoint = entryPointLoadTask
            if entryPoint != previousEntryPoint {
                previousEntryPoint = entryPoint
                _ = await entryPoint?.value
                continue
            }
            break
        }
    }

    func updateBooks(_ books: [TPPBook]) {
        allBooks = books
        if searchQuery.isEmpty {
            filteredBooks = filterBooks(books, forEntryAt: selectedFormatIndex)
        }
    }

    func updateSearchQuery(_ query: String) {
        searchQuery = query

        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(self.debounceInterval * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self.performSearch()
        }
    }

    func clearSearch() {
        searchQuery = ""
        debounceTask?.cancel()
        searchTask?.cancel()
        isLoading = false
        errorMessage = nil
        filteredBooks = filterBooks(allBooks, forEntryAt: selectedFormatIndex)
        nextPageURL = nil
        isLoadingMore = false
        postSearchFacets.removeAll()
        lastSearchedQuery = ""
        // Reset completion flag so the empty state doesn't flash while the
        // user re-types — the catalog grid is showing the unfiltered books now.
        hasCompletedSearch = false
        // Generate new searchId to scroll to top of restored books
        searchId = UUID()
    }

    // MARK: - Format Entry Points

    /// Fetch format entry points from the groups feed and populate `formatEntries`.
    /// Called when the search screen appears. Safe to call multiple times.
    func loadFormatEntryPoints() {
        guard let url = baseURL() else { return }
        entryPointLoadTask?.cancel()
        entryPointLoadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let entries = try await self.repository.fetchSearchEntryPoints(from: url)
                guard !Task.isCancelled else { return }
                self.formatEntries = entries
                if let activeIdx = entries.firstIndex(where: { $0.isActive }) {
                    self.selectedFormatIndex = activeIdx
                }
                // Re-filter the displayed books now that we know the active format.
                // Only applies when no search is active; search results are unaffected.
                if self.searchQuery.isEmpty {
                    self.filteredBooks = self.filterBooks(self.allBooks, forEntryAt: self.selectedFormatIndex)
                }
                // Pre-populate the cache for entries that already have a descriptor URL
                for entry in entries {
                    if let descriptorURL = entry.searchDescriptorURL {
                        self.searchDescriptorURLCache[entry.groupsFeedURL.absoluteString] = descriptorURL
                    }
                }
            } catch {
                Log.warn(#file, "Could not load search format entry points: \(error.localizedDescription)")
            }
        }
    }

    /// Select a format filter at the given index.
    /// Triggers a new search if a query is already active.
    func selectFormat(at index: Int) {
        guard index < formatEntries.count, index != selectedFormatIndex else { return }
        selectedFormatIndex = index

        // Prefetch the search descriptor URL for the new format in background so future
        // searches with this format are fast (skip the groups feed fetch).
        let selectedEntry = formatEntries[index]
        let cacheKey = selectedEntry.groupsFeedURL.absoluteString
        if searchDescriptorURLCache[cacheKey] == nil {
            Task { [weak self] in
                guard let self else { return }
                do {
                    let entries = try await self.repository.fetchSearchEntryPoints(from: selectedEntry.groupsFeedURL)
                    if let active = entries.first(where: { $0.isActive }),
                       let descriptorURL = active.searchDescriptorURL {
                        self.searchDescriptorURLCache[cacheKey] = descriptorURL
                    }
                } catch {
                    // Silently fail; search falls back to fetching the groups feed
                }
            }
        }

        if !searchQuery.isEmpty {
            debounceTask?.cancel()
            performSearch()
        } else {
            filteredBooks = filterBooks(allBooks, forEntryAt: index)
        }
    }

    // MARK: - Format Filtering (no-query state)

    /// Filter a list of books by the entry-point format at the given index.
    /// Used when no search query is active — selecting a facet immediately narrows
    /// the displayed books to match that format using the book's content type.
    ///
    /// Title-based detection handles the common Palace formats:
    ///   "all" prefix/suffix → show everything
    ///   contains "audio"   → audiobooks only
    ///   anything else      → non-audiobook titles (eBooks, PDF, etc.)
    private func filterBooks(_ books: [TPPBook], forEntryAt index: Int) -> [TPPBook] {
        guard !formatEntries.isEmpty, index < formatEntries.count else { return books }
        let title = formatEntries[index].title.lowercased()

        if title == "all" || title.hasPrefix("all ") || title.hasSuffix(" all") {
            return books
        } else if title.contains("audio") {
            return books.filter { $0.isAudiobook }
        } else {
            return books.filter { !$0.isAudiobook }
        }
    }

    // MARK: - Search Execution

    private enum SearchTarget {
        case baseURL(URL)
        case searchDescriptorURL(URL)
        /// Direct URL with the query already embedded (from post-search facet links).
        case directURL(URL)
    }

    /// Determine the search target for `query` based on the selected format.
    private func resolveSearchTarget(for query: String) -> SearchTarget? {
        if !formatEntries.isEmpty, selectedFormatIndex < formatEntries.count {
            let selectedEntry = formatEntries[selectedFormatIndex]

            // Post-search facets carry the current query in the URL — use them for fast
            // format switching without going through the OpenSearch descriptor flow again.
            // Keys are normalized to lowercase to handle backend title casing differences.
            if let directURL = postSearchFacets[selectedEntry.title.lowercased()] {
                return .directURL(directURL)
            }

            // Cached descriptor URL: skip the groups feed fetch.
            let cacheKey = selectedEntry.groupsFeedURL.absoluteString
            if let descriptorURL = searchDescriptorURLCache[cacheKey] {
                return .searchDescriptorURL(descriptorURL)
            }

            // Fallback: fetch the format's groups feed to discover its search descriptor URL.
            return .baseURL(selectedEntry.groupsFeedURL)
        }

        guard let url = baseURL() else { return nil }
        return .baseURL(url)
    }

    private func performSearch() {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)

        searchTask?.cancel()

        guard !query.isEmpty else {
            filteredBooks = filterBooks(allBooks, forEntryAt: selectedFormatIndex)
            nextPageURL = nil
            isLoading = false
            lastSearchedQuery = ""
            // No active query → the unfiltered grid is what's on screen, not
            // a "no results for ..." surface. Suppress the empty state.
            hasCompletedSearch = false
            return
        }

        // Post-search facets are keyed to the active query. Clear them when the query itself
        // changes so stale direct URLs from a previous query aren't used. For format switches
        // on the same query, preserve them so resolveSearchTarget can take the fast directURL path.
        let isNewQuery = query != lastSearchedQuery
        if isNewQuery {
            postSearchFacets.removeAll()
        }

        guard let searchTarget = resolveSearchTarget(for: query) else {
            postSearchFacets.removeAll()
            filteredBooks = []
            nextPageURL = nil
            isLoading = false
            // We attempted a search for a real query and couldn't even resolve
            // a target URL — that's still a "completed, zero results" outcome
            // from the user's vantage. Flip the flag so the empty state shows.
            hasCompletedSearch = true
            return
        }

        // Clear facets after resolving so fresh ones from the new results replace them.
        postSearchFacets.removeAll()

        nextPageURL = nil
        isLoadingMore = false
        isLoading = true
        // While the request is in flight we are NOT in a "no results" state —
        // suppress the empty surface in favor of the spinner.
        hasCompletedSearch = false
        // Only scroll to top for genuinely new queries; format switches filter in place.
        if isNewQuery {
            searchId = UUID()
        }
        lastSearchedQuery = query

        searchTask = Task { [weak self] in
            defer {
                // Only the still-active task's outcome should drive UI state. A
                // cancelled task whose successor has already set isLoading=true /
                // hasCompletedSearch=false must not stomp those values back.
                if !Task.isCancelled {
                    self?.isLoading = false
                    // Whatever the outcome — success, nil-feed, or thrown error —
                    // the search has completed and the view should now decide between
                    // results grid and no-results empty state.
                    self?.hasCompletedSearch = true
                }
            }

            do {
                guard let self, !Task.isCancelled else { return }

                let feed: CatalogFeed?
                switch searchTarget {
                case .baseURL(let url):
                    feed = try await self.repository.search(query: query, baseURL: url)
                case .searchDescriptorURL(let url):
                    feed = try await self.repository.search(query: query, searchDescriptorURL: url)
                case .directURL(let url):
                    feed = try await self.repository.fetchFeed(at: url)
                }

                guard !Task.isCancelled else { return }

                if let feed = feed {
                    var searchResults: [TPPBook] = []
                    if let opds2 = feed.opds2Feed {
                        // OPDS 2 path
                        let pubs = opds2.publications ?? opds2.groups?.flatMap { $0.publications ?? [] } ?? []
                        searchResults = pubs.compactMap { $0.toBook() }
                        self.nextPageURL = opds2.nextPageURL
                        // Extract post-search facets from OPDS2
                        if let facets = opds2.facets {
                            for group in facets {
                                for link in group.links {
                                    if let url = link.hrefURL {
                                        self.postSearchFacets[link.title.lowercased()] = url
                                    }
                                }
                            }
                        }
                    } else {
                        // OPDS 1 path
                        let feedObjc = feed.opdsFeed
                        if let opdsEntries = feedObjc.entries as? [TPPOPDSEntry] {
                            searchResults = opdsEntries.compactMap { CatalogViewModel.makeBook(from: $0, bookRegistry: self.bookRegistry) }
                        }
                        self.extractNextPageURL(from: feedObjc)
                        self.extractPostSearchFacets(from: feedObjc)
                    }
                    self.filteredBooks = searchResults
                    self.announcements.announceSearchResults(query: query, count: searchResults.count)
                } else {
                    self.filteredBooks = []
                    self.nextPageURL = nil
                    self.announcements.announceSearchResults(query: query, count: 0)
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.filteredBooks = []
                self?.nextPageURL = nil
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

            var newBooks: [TPPBook] = []
            if let opds2 = feed.opds2Feed {
                let pubs = opds2.publications ?? opds2.groups?.flatMap { $0.publications ?? [] } ?? []
                newBooks = pubs.compactMap { $0.toBook() }
                nextPageURL = opds2.nextPageURL
            } else {
                let feedObjc = feed.opdsFeed
                extractNextPageURL(from: feedObjc)
                if let entries = feedObjc.entries as? [TPPOPDSEntry] {
                    newBooks = entries.compactMap { CatalogViewModel.makeBook(from: $0, bookRegistry: self.bookRegistry) }
                }
            }
            filteredBooks.append(contentsOf: newBooks)
            announcements.announceAdditionalResultsLoaded(count: newBooks.count)
        } catch {
            Log.error(#file, "Failed to load next page of search results: \(error.localizedDescription)")
        }
    }

    // MARK: - Post-Search Facet Extraction

    /// Extract entry-point facet links from search results for fast format switching.
    /// These links have the current query baked into their URL, letting us switch
    /// format without re-executing the OpenSearch descriptor flow.
    private func extractPostSearchFacets(from feed: TPPOPDSFeed) {
        postSearchFacets.removeAll()
        guard let links = feed.links as? [TPPOPDSLink] else { return }
        for link in links {
            guard link.rel == TPPOPDSRelationFacet,
                  let title = link.title else { continue }
            let href = link.href
            var isEntryPoint = false
            for (key, _) in link.attributes {
                if let keyStr = key as? String, TPPOPDSAttributeKeyStringIsFacetGroupType(keyStr) {
                    isEntryPoint = true
                    break
                }
            }
            if isEntryPoint {
                // Lowercase key so lookups are case-insensitive across different backends
                postSearchFacets[title.lowercased()] = href
            }
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
                bookCellModelCache.invalidate(for: book.identifier)
                anyChanged = true
            }
        }
        if anyChanged { filteredBooks = books }
    }
}
