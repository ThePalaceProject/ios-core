//
//  CatalogSearchViewModelTests.swift
//  PalaceTests
//
//  Comprehensive unit tests for CatalogSearchViewModel.
//  Tests cover initialization, search operations, debouncing, cancellation,
//  and state management following Test_Patterns.md conventions.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import Combine
import PalaceCatalog
@testable import Palace
import PalaceBookModel

// MARK: - Mock Repository for Search Tests

@MainActor
final class CatalogRepositoryMock: @preconcurrency CatalogRepositoryProtocol {

    // MARK: - Configuration

    var loadTopLevelCatalogResult: CatalogFeed?
    var loadTopLevelCatalogError: Error?
    var searchResult: CatalogFeed?
    var searchError: Error?
    var searchWithDescriptorResult: CatalogFeed?
    var searchWithDescriptorError: Error?
    var fetchSearchEntryPointsResult: [SearchFormatEntry] = []
    var fetchSearchEntryPointsError: Error?
    var simulatedDelay: TimeInterval = 0

    /// When true, `loadTopLevelCatalog(at:)` models the real repository's
    /// stale-while-revalidate cache: a URL is fetched from the "network" only
    /// on the FIRST load (a cache miss). Subsequent loads of the same URL are
    /// served from the in-memory cache and do NOT increment the per-URL
    /// network-fetch counter. `invalidateCache(for:)` evicts the URL so the
    /// next load re-fetches. Lets the SWR / de-triple-fire tests observe the
    /// account-switch cache behavior the production repository owns.
    var simulatesCache = false

    // MARK: - Call Tracking

    private(set) var loadTopLevelCatalogCallCount = 0
    private(set) var searchCallCount = 0
    private(set) var searchWithDescriptorCallCount = 0
    private(set) var fetchSearchEntryPointsCallCount = 0
    /// Number of times `invalidateCache(for:)` was called (SWR contract).
    private(set) var invalidateCacheCallCount = 0
    /// Last URL passed to `invalidateCache(for:)`.
    private(set) var lastInvalidatedURL: URL?
    private(set) var lastSearchQuery: String?
    private(set) var lastSearchURL: URL?
    private(set) var lastSearchDescriptorURL: URL?
    private(set) var lastFetchSearchEntryPointsURL: URL?
    private(set) var lastLoadURL: URL?
    /// Every URL passed to `loadTopLevelCatalog(at:)`, in order.
    private(set) var loadHistory: [URL] = []
    private(set) var searchHistory: [(query: String, url: URL)] = []

    /// Per-URL count of simulated NETWORK fetches (cache misses). Only tracked
    /// when `simulatesCache` is true.
    private(set) var networkFetchCountByURL: [URL: Int] = [:]
    /// URLs currently warm in the simulated cache.
    private var liveCacheURLs: Set<URL> = []

    func networkFetchCount(for url: URL) -> Int {
        networkFetchCountByURL[url] ?? 0
    }

    /// Callback fired after each search — use with XCTestExpectation for deterministic waits
    var onSearchCalled: (() -> Void)?

    // MARK: - CatalogRepositoryProtocol

    func loadTopLevelCatalog(at url: URL) async throws -> CatalogFeed? {
        loadTopLevelCatalogCallCount += 1
        lastLoadURL = url
        loadHistory.append(url)

        if simulatedDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(simulatedDelay * 1_000_000_000))
        }

        if let error = loadTopLevelCatalogError {
            throw error
        }

        if simulatesCache, !liveCacheURLs.contains(url) {
            // Cache miss — count a network fetch and warm the cache.
            networkFetchCountByURL[url, default: 0] += 1
            liveCacheURLs.insert(url)
        }

        return loadTopLevelCatalogResult
    }

    func search(query: String, baseURL: URL) async throws -> CatalogFeed? {
        searchCallCount += 1
        lastSearchQuery = query
        lastSearchURL = baseURL
        searchHistory.append((query, baseURL))

        if simulatedDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(simulatedDelay * 1_000_000_000))
        }

        if let error = searchError {
            onSearchCalled?()
            throw error
        }

        onSearchCalled?()
        return searchResult
    }

    func search(query: String, searchDescriptorURL: URL) async throws -> CatalogFeed? {
        searchWithDescriptorCallCount += 1
        lastSearchQuery = query
        lastSearchDescriptorURL = searchDescriptorURL

        if simulatedDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(simulatedDelay * 1_000_000_000))
        }

        if let error = searchWithDescriptorError ?? searchError {
            throw error
        }

        return searchWithDescriptorResult ?? searchResult
    }

    func fetchSearchEntryPoints(from url: URL) async throws -> [SearchFormatEntry] {
        fetchSearchEntryPointsCallCount += 1
        lastFetchSearchEntryPointsURL = url

        if simulatedDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(simulatedDelay * 1_000_000_000))
        }

        if let error = fetchSearchEntryPointsError {
            throw error
        }

        return fetchSearchEntryPointsResult
    }

    func fetchFeed(at url: URL) async throws -> CatalogFeed? {
        return try await loadTopLevelCatalog(at: url)
    }

    // `CatalogRepositoryProtocol` is a nonisolated `Sendable` protocol. Its
    // `async` requirements are satisfied by this `@MainActor` mock's async
    // methods (the caller hops), but the two *synchronous* requirements below
    // must be `nonisolated` witnesses or the conformance "crosses into main
    // actor-isolated code" (Swift 6). Both are stateless, so `nonisolated` is
    // sound and behavior is unchanged.
    func invalidateCache(for url: URL) {
        invalidateCacheCallCount += 1
        lastInvalidatedURL = url
        liveCacheURLs.remove(url)
    }

    func cachedFeed(for url: URL) -> CatalogFeed? { nil }

    // MARK: - Test Helpers

    func reset() {
        loadTopLevelCatalogResult = nil
        loadTopLevelCatalogError = nil
        searchResult = nil
        searchError = nil
        searchWithDescriptorResult = nil
        searchWithDescriptorError = nil
        fetchSearchEntryPointsResult = []
        fetchSearchEntryPointsError = nil
        simulatedDelay = 0
        simulatesCache = false
        loadTopLevelCatalogCallCount = 0
        searchCallCount = 0
        searchWithDescriptorCallCount = 0
        fetchSearchEntryPointsCallCount = 0
        invalidateCacheCallCount = 0
        lastInvalidatedURL = nil
        lastSearchQuery = nil
        lastSearchURL = nil
        lastSearchDescriptorURL = nil
        lastFetchSearchEntryPointsURL = nil
        lastLoadURL = nil
        loadHistory.removeAll()
        searchHistory.removeAll()
        networkFetchCountByURL.removeAll()
        liveCacheURLs.removeAll()
    }
}

// MARK: - Test Error

enum TestError: Error {
    case networkError
    case parsingError
    case timeout
}

// MARK: - CatalogSearchViewModelTests

@MainActor
final class CatalogSearchViewModelTests: XCTestCase {

    // MARK: - Properties

    private var mockRepository: CatalogRepositoryMock!
    private var cancellables: Set<AnyCancellable>!
    private var testBaseURL: URL!

    // MARK: - Setup/Teardown

    override func setUp() {
        super.setUp()
        mockRepository = CatalogRepositoryMock()
        cancellables = Set<AnyCancellable>()
        testBaseURL = URL(string: "https://example.com/catalog")!
    }

    override func tearDown() {
        mockRepository?.reset()
        mockRepository = nil
        cancellables = nil
        testBaseURL = nil
        super.tearDown()
    }

    // MARK: - Helper Methods

    /// Captures VoiceOver announcements posted through the injected announcement center.
    private class AnnouncementCapture {
        var items: [String] = []
        var onAnnouncement: (() -> Void)?
    }

    private final class _AnnouncementOneShot { var done = false }

    /// Deterministically await the next announcement `capture` records, driven by
    /// `trigger`. `TPPAccessibilityAnnouncementCenter` posts via
    /// `DispatchQueue.main.async`/`asyncAfter` (an internal VoiceOver debounce),
    /// so the announcement lands a delayed main hop AFTER the search task —
    /// joining `searchTask` enqueues it but is not sufficient. Resuming on the
    /// capture's own callback is timing-independent: it fires exactly when the
    /// announcement lands, so it cannot starve on a fixed 5s deadline under
    /// parallel-CI sim clones (a real never-fires bug surfaces as the 120s XCTest
    /// allowance instead). The callback is installed BEFORE `trigger` runs, so the
    /// signal can't be missed.
    @MainActor
    private func awaitNextAnnouncement(_ capture: AnnouncementCapture,
                                       trigger: () -> Void) async {
        let oneShot = _AnnouncementOneShot()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            capture.onAnnouncement = {
                guard !oneShot.done else { return }
                oneShot.done = true
                cont.resume()
            }
            trigger()
        }
    }

    /// Creates a `TPPAccessibilityAnnouncementCenter` that records every
    /// announcement synchronously in `capture.items` and optionally fires a callback.
    private func makeCapturingAnnouncer(capture: AnnouncementCapture) -> TPPAccessibilityAnnouncementCenter {
        TPPAccessibilityAnnouncementCenter(
            postHandler: { _, message in
                capture.items.append(message)
                capture.onAnnouncement?()
            },
            isVoiceOverRunning: { true },
            deduplicationInterval: 0
        )
    }

    private func createViewModel(
        baseURL: URL? = nil,
        debounceInterval: TimeInterval = 0.05, // Short debounce for faster tests
        announcements: TPPAccessibilityAnnouncementCenter? = nil
    ) -> CatalogSearchViewModel {
        let urlToUse = baseURL ?? testBaseURL
        let cache = AppContainer.production().bookCellModelCache
        if let announcements {
            return CatalogSearchViewModel(
                repository: mockRepository,
                baseURL: { urlToUse },
                debounceInterval: debounceInterval,
                announcements: announcements,
                bookCellModelCache: cache
            )
        }
        return CatalogSearchViewModel(
            repository: mockRepository,
            baseURL: { urlToUse },
            debounceInterval: debounceInterval,
            bookCellModelCache: cache
        )
    }

    private func createViewModelWithNilURL(
        debounceInterval: TimeInterval = 0.05
    ) -> CatalogSearchViewModel {
        return CatalogSearchViewModel(
            repository: mockRepository,
            baseURL: { nil },
            debounceInterval: debounceInterval,
            bookCellModelCache: AppContainer.production().bookCellModelCache
        )
    }

    private func createTestBook() -> TPPBook {
        return TPPBookMocker.mockBook(distributorType: .EpubZip)
    }

    /// Helper: wait for `loadFormatEntryPoints()` to finish by JOINING the retained
    /// entry-point load Task (deterministic) instead of polling `$formatEntries`
    /// against a wall-clock deadline. The `entryPointLoadTask` assigns
    /// `formatEntries` before it returns, so awaiting it guarantees the count is
    /// settled — no clock, no starvation under parallel CI clones.
    private func waitForFormatEntries(on viewModel: CatalogSearchViewModel, count: Int) async {
        await viewModel._awaitInFlightWorkForTesting()
    }

    /// Helper: wait for `loadFormatEntryPoints()` to finish (any outcome, including
    /// an empty result or a thrown error). Joins the retained load Task rather than
    /// observing the publisher on a timeout — see `waitForFormatEntries` rationale.
    private func waitForFormatEntriesLoaded(on viewModel: CatalogSearchViewModel) async {
        await viewModel._awaitInFlightWorkForTesting()
    }

    // MARK: - Initialization Tests

    func testInit_HasCorrectDefaults() {
        let viewModel = createViewModel()

        // Verify all @Published properties have correct defaults
        XCTAssertEqual(viewModel.searchQuery, "", "searchQuery should be empty string")
        XCTAssertTrue(viewModel.filteredBooks.isEmpty, "filteredBooks should be empty")
        XCTAssertFalse(viewModel.isLoading, "isLoading should be false")
        XCTAssertNil(viewModel.errorMessage, "errorMessage should be nil")
        XCTAssertNil(viewModel.nextPageURL, "nextPageURL should be nil")
        XCTAssertFalse(viewModel.isLoadingMore, "isLoadingMore should be false")
        XCTAssertNotNil(viewModel.searchId, "searchId should have initial value")
    }

    // MARK: - Search With Empty Query Tests

    func testSearch_WithEmptyQuery_DoesNotCallRepository() async {
        let viewModel = createViewModel()

        // Trigger search with empty query
        viewModel.updateSearchQuery("")

        // JOIN the debounce Task: it runs performSearch(), which short-circuits on
        // the empty-query guard without calling the repository. Awaiting the Task
        // is strictly stronger than a fixed sleep — it guarantees the debounce
        // actually executed before we assert the non-call, and never starves.
        await viewModel._awaitInFlightWorkForTesting()

        // Repository should not be called for empty query
        XCTAssertEqual(mockRepository.searchCallCount, 0, "Repository search should not be called for empty query")
    }

    func testSearch_WithWhitespaceOnlyQuery_DoesNotCallRepository() async {
        let viewModel = createViewModel()

        // Trigger search with whitespace-only query
        viewModel.updateSearchQuery("   ")

        // JOIN the debounce Task: performSearch() trims to empty and short-circuits
        // without calling the repository. Awaiting guarantees it ran; no clock.
        await viewModel._awaitInFlightWorkForTesting()

        // Repository should not be called (whitespace is trimmed, becomes empty)
        XCTAssertEqual(mockRepository.searchCallCount, 0, "Repository search should not be called for whitespace-only query")
    }

    func testSearch_WithEmptyQuery_ShowsAllBooks() async {
        let viewModel = createViewModel()
        let books = [createTestBook(), createTestBook()]

        // Pre-populate with books
        viewModel.updateBooks(books)

        // Clear to empty state
        viewModel.filteredBooks = []

        // Trigger search with empty query
        viewModel.updateSearchQuery("")

        // JOIN the debounce Task: performSearch() takes the empty-query branch that
        // restores filteredBooks from allBooks. Awaiting the Task guarantees that
        // restore ran before we assert — deterministic, no clock.
        await viewModel._awaitInFlightWorkForTesting()

        // Should restore all books
        XCTAssertEqual(viewModel.filteredBooks.count, 2, "Empty query should restore all books")
    }

    // MARK: - Search With Valid Query Tests

    func testSearch_WithValidQuery_CallsRepository() async {
        let viewModel = createViewModel()

        // Trigger search with valid query
        viewModel.updateSearchQuery("Harry Potter")

        await viewModel._awaitInFlightWorkForTesting()

        // Repository should be called
        XCTAssertEqual(mockRepository.searchCallCount, 1, "Repository search should be called once")
        XCTAssertEqual(mockRepository.lastSearchQuery, "Harry Potter", "Search query should match")
        XCTAssertEqual(mockRepository.lastSearchURL, testBaseURL, "Search base URL should match")
    }

    func testSearch_WithValidQuery_SetsIsSearching() async {
        let viewModel = createViewModel()

        // Add delay to mock to ensure we can observe isLoading
        mockRepository.simulatedDelay = 0.2

        let expectation = XCTestExpectation(description: "isLoading becomes true")

        viewModel.$isLoading
            .dropFirst()
            .sink { isLoading in
                if isLoading {
                    expectation.fulfill()
                }
            }
            .store(in: &cancellables)

        // Trigger search
        viewModel.updateSearchQuery("test")

        await fulfillment(of: [expectation], timeout: 1.0)
        XCTAssertTrue(viewModel.isLoading, "isLoading should be true during search")
    }

    func testSearch_WithValidQuery_ClearsIsLoadingAfterCompletion() async {
        let viewModel = createViewModel()

        // Trigger search
        viewModel.updateSearchQuery("test")

        await viewModel._awaitInFlightWorkForTesting()

        XCTAssertFalse(viewModel.isLoading, "isLoading should be false after search completes")
    }

    // MARK: - Search Results Tests

    func testSearch_WithResults_UpdatesResults() async {
        let viewModel = createViewModel()

        // Configure mock to return a feed
        // Note: We can't easily create a full CatalogFeed, but we can verify the search was called
        // and the state management is correct
        mockRepository.searchResult = nil // Will result in empty results

        // Trigger search
        viewModel.updateSearchQuery("test query")

        await viewModel._awaitInFlightWorkForTesting()

        // Verify search was called
        XCTAssertEqual(mockRepository.searchCallCount, 1)
        XCTAssertFalse(viewModel.isLoading, "isLoading should be false after search")
    }

    func testSearch_WithNilResult_SetsEmptyResults() async {
        let viewModel = createViewModel()

        // Pre-populate with books
        let books = [createTestBook()]
        viewModel.updateBooks(books)

        // Configure mock to return nil
        mockRepository.searchResult = nil

        // Trigger search
        viewModel.updateSearchQuery("nonexistent")

        await viewModel._awaitInFlightWorkForTesting()

        // Filtered books should be empty
        XCTAssertTrue(viewModel.filteredBooks.isEmpty, "filteredBooks should be empty when search returns nil")
    }

    // MARK: - Search Error Tests

    func testSearch_WithError_SetsErrorMessage() async {
        let viewModel = createViewModel()

        // Configure mock to throw error
        mockRepository.searchError = TestError.networkError

        // Trigger search
        viewModel.updateSearchQuery("test")

        await viewModel._awaitInFlightWorkForTesting()

        // Verify error handling - filteredBooks should be cleared
        XCTAssertTrue(viewModel.filteredBooks.isEmpty, "filteredBooks should be empty on error")
        XCTAssertFalse(viewModel.isLoading, "isLoading should be false after error")
    }

    func testSearch_WithError_ClearsNextPageURL() async {
        let viewModel = createViewModel()

        // Set up initial state with next page URL
        viewModel.nextPageURL = URL(string: "https://example.com/page2")

        // Configure mock to throw error
        mockRepository.searchError = TestError.networkError

        // Trigger search
        viewModel.updateSearchQuery("test")

        await viewModel._awaitInFlightWorkForTesting()

        XCTAssertNil(viewModel.nextPageURL, "nextPageURL should be nil after error")
    }

    // MARK: - Debouncing Tests

    func testSearch_Debounces_MultipleQueries() async {
        let viewModel = createViewModel(debounceInterval: 0.1)

        // Rapidly fire multiple search queries
        viewModel.updateSearchQuery("H")
        viewModel.updateSearchQuery("Ha")
        viewModel.updateSearchQuery("Har")
        viewModel.updateSearchQuery("Harr")
        viewModel.updateSearchQuery("Harry")

        // JOIN the surviving debounce→search chain. Each updateSearchQuery
        // cancels + replaces debounceTask; the seam awaits the latest handle,
        // and the cancelled predecessors resolve immediately (guard on
        // Task.isCancelled), so only the final "Harry" search runs to completion.
        await viewModel._awaitInFlightWorkForTesting()

        // Should only call repository once with final query
        XCTAssertEqual(mockRepository.searchCallCount, 1, "Repository should only be called once after debounce")
        XCTAssertEqual(mockRepository.lastSearchQuery, "Harry", "Should use final query value")
    }

    func testSearch_Debounces_DoesNotSearchDuringDebounceWindow() async {
        // Use a 1s debounce so the mid-window check has a wide enough margin to be
        // reliable on slow CI machines (Task.sleep can overshoot significantly under load).
        let viewModel = createViewModel(debounceInterval: 1.0)

        viewModel.updateSearchQuery("test")

        // Immediately after triggering — debounce has not fired.
        XCTAssertEqual(mockRepository.searchCallCount, 0, "Should not search immediately")

        // 300ms into a 1s debounce window — still should not have fired.
        // We cannot observe a non-event; use a brief sleep that is well within the
        // debounce window. This sleep asserts a NON-event mid-window; it is NOT a
        // completion deadline and is bounded far inside the 1s debounce, so parallel
        // CI clones cannot starve it into a false pass.
        await Task.yield()
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(mockRepository.searchCallCount, 0, "Should not search during debounce window")

        // JOIN the debounce→search chain deterministically (replaces the fixed
        // fulfillment deadline that starved under parallel CI clones).
        await viewModel._awaitInFlightWorkForTesting()
        XCTAssertEqual(mockRepository.searchCallCount, 1, "Should search after debounce completes")
    }

    // MARK: - Cancellation Tests

    func testSearch_CancelsInFlight_OnNewQuery() async {
        let viewModel = createViewModel(debounceInterval: 0.05)

        // Add delay to mock so first search is still in progress
        mockRepository.simulatedDelay = 0.3

        // Start first search
        viewModel.updateSearchQuery("first")

        // Position the first search as in-flight: 100ms is past the 50ms debounce
        // but well inside the 300ms simulatedDelay, so the first search Task is
        // mid-await when we fire the second query. This is a positioning sleep to
        // establish the cancel-in-flight precondition, not a completion deadline.
        await Task.yield()
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Start second search (should cancel the in-flight first)
        mockRepository.simulatedDelay = 0.05 // Make second search faster
        viewModel.updateSearchQuery("second")

        // JOIN the second search chain deterministically. Replacing debounceTask
        // cancels the first search (its Task.isCancelled guards make it a no-op),
        // and the seam awaits the "second" chain to completion — no clock.
        await viewModel._awaitInFlightWorkForTesting()

        // Verify last search query was "second"
        XCTAssertEqual(mockRepository.lastSearchQuery, "second", "Last search should be 'second'")
    }

    func testSearch_CancelsDebounce_OnNewQuery() async {
        // 1s debounce gives a wide margin for CI: 300ms is safely inside the window
        // even on a machine under load.
        let viewModel = createViewModel(debounceInterval: 1.0)

        viewModel.updateSearchQuery("first")

        // 300ms into the 1s debounce — "first" has not fired yet. This positioning
        // sleep is bounded far inside the debounce window (not a completion
        // deadline). Trigger "second" while "first"'s debounce is still pending.
        await Task.yield()
        try? await Task.sleep(nanoseconds: 300_000_000)
        viewModel.updateSearchQuery("second")

        // JOIN "second"'s debounce→search chain deterministically. The "first"
        // debounce Task was cancelled by the replacement and never calls the
        // repository. No clock.
        await viewModel._awaitInFlightWorkForTesting()

        // Only "second" should have been searched (first debounce was cancelled).
        XCTAssertEqual(mockRepository.searchCallCount, 1, "Should only search once")
        XCTAssertEqual(mockRepository.lastSearchQuery, "second", "Should search for 'second'")
    }

    // MARK: - Clear Search Tests

    func testClearSearch_ResetsState() {
        let viewModel = createViewModel()
        let books = [createTestBook()]

        // Set up various states
        viewModel.updateBooks(books)
        viewModel.searchQuery = "test"
        viewModel.isLoading = true
        viewModel.errorMessage = "Error"
        viewModel.nextPageURL = URL(string: "https://example.com/page2")
        viewModel.isLoadingMore = true

        // Clear search
        viewModel.clearSearch()

        // Verify all state is reset
        XCTAssertEqual(viewModel.searchQuery, "", "searchQuery should be empty")
        XCTAssertFalse(viewModel.isLoading, "isLoading should be false")
        XCTAssertNil(viewModel.errorMessage, "errorMessage should be nil")
        XCTAssertNil(viewModel.nextPageURL, "nextPageURL should be nil")
        XCTAssertFalse(viewModel.isLoadingMore, "isLoadingMore should be false")
        XCTAssertEqual(viewModel.filteredBooks.count, 1, "filteredBooks should be restored to allBooks")
    }

    func testClearSearch_RestoresAllBooks() {
        let viewModel = createViewModel()
        let books = [createTestBook(), createTestBook(), createTestBook()]

        viewModel.updateBooks(books)
        viewModel.filteredBooks = [] // Simulate search with no results

        viewModel.clearSearch()

        XCTAssertEqual(viewModel.filteredBooks.count, 3, "Should restore all books")
    }

    func testClearSearch_ChangesSearchId() {
        let viewModel = createViewModel()
        let initialSearchId = viewModel.searchId

        viewModel.clearSearch()

        XCTAssertNotEqual(viewModel.searchId, initialSearchId, "searchId should change on clear")
        // Clearing again must produce yet another distinct searchId
        let afterFirstClear = viewModel.searchId
        viewModel.clearSearch()
        XCTAssertNotEqual(viewModel.searchId, afterFirstClear, "Each clearSearch must produce a new unique searchId")
    }

    func testClearSearch_CancelsPendingOperations() async {
        let viewModel = createViewModel(debounceInterval: 0.2)

        // Start a search
        viewModel.updateSearchQuery("test")

        // Clear before debounce completes
        viewModel.clearSearch()

        // JOIN the (now-cancelled) debounce Task: clearSearch cancelled it, so its
        // Task.isCancelled guard returns before performSearch() ever calls the
        // repository. Awaiting the handle deterministically confirms it resolved
        // without searching — no fixed sleep, no starvation.
        await viewModel._awaitInFlightWorkForTesting()

        // Search should not have been called
        XCTAssertEqual(mockRepository.searchCallCount, 0, "Search should be cancelled by clearSearch")
    }

    // MARK: - Nil Base URL Tests

    func testSearch_WithNilBaseURL_DoesNotSearch() async {
        let viewModel = createViewModelWithNilURL()

        // Trigger search
        viewModel.updateSearchQuery("test")

        // JOIN the debounce Task: performSearch()'s resolveSearchTarget returns nil
        // for a nil baseURL and short-circuits before any repository call. Awaiting
        // guarantees that branch executed — deterministic, no clock.
        await viewModel._awaitInFlightWorkForTesting()

        // Repository should not be called when baseURL is nil
        XCTAssertEqual(mockRepository.searchCallCount, 0, "Should not call repository when baseURL is nil")
        XCTAssertTrue(viewModel.filteredBooks.isEmpty, "filteredBooks should be empty")
        XCTAssertFalse(viewModel.isLoading, "isLoading should be false")
    }

    func testSearch_WithNilBaseURL_ClearsNextPageURL() async {
        let viewModel = createViewModelWithNilURL()

        // Set up initial state
        viewModel.nextPageURL = URL(string: "https://example.com/page2")

        // Trigger search
        viewModel.updateSearchQuery("test")

        // JOIN the debounce Task: the nil-target branch of performSearch() clears
        // nextPageURL before returning. Awaiting guarantees it ran; no clock.
        await viewModel._awaitInFlightWorkForTesting()

        XCTAssertNil(viewModel.nextPageURL, "nextPageURL should be cleared when baseURL is nil")
    }

    // MARK: - Search ID Tests (PP-3605 Regression)

    func testSearch_NewSearch_ChangesSearchId() async {
        let viewModel = createViewModel()
        let initialSearchId = viewModel.searchId

        // Perform a search
        viewModel.updateSearchQuery("test")

        await viewModel._awaitInFlightWorkForTesting()

        XCTAssertNotEqual(viewModel.searchId, initialSearchId, "searchId should change for new search")
    }

    func testSearch_DifferentQueries_HaveDifferentSearchIds() async {
        let viewModel = createViewModel()

        // First search
        viewModel.updateSearchQuery("first")
        await viewModel._awaitInFlightWorkForTesting()
        let firstSearchId = viewModel.searchId

        // Second search
        viewModel.updateSearchQuery("second")
        await viewModel._awaitInFlightWorkForTesting()
        let secondSearchId = viewModel.searchId

        XCTAssertNotEqual(firstSearchId, secondSearchId, "Different searches should have different searchIds")
    }

    // MARK: - Update Books Tests

    func testUpdateBooks_SetsFilteredBooks_WhenQueryEmpty() {
        let viewModel = createViewModel()
        let books = [createTestBook(), createTestBook()]
        XCTAssertTrue(viewModel.filteredBooks.isEmpty, "filteredBooks must start empty")

        viewModel.updateBooks(books)

        XCTAssertEqual(viewModel.filteredBooks.count, 2)
        XCTAssertEqual(viewModel.searchQuery, "", "Empty query must remain empty after updateBooks")
    }

    func testUpdateBooks_DoesNotChangeFilteredBooks_WhenQueryNotEmpty() {
        let viewModel = createViewModel()
        let books = [createTestBook(), createTestBook()]

        // Set a non-empty query first
        viewModel.searchQuery = "test"
        viewModel.filteredBooks = []

        // Update books
        viewModel.updateBooks(books)

        // filteredBooks should remain empty (not updated when query is non-empty)
        XCTAssertTrue(viewModel.filteredBooks.isEmpty, "filteredBooks should not change when query is non-empty")
    }

    // MARK: - Load Next Page Tests

    func testLoadNextPage_WithNoNextURL_DoesNothing() async {
        let viewModel = createViewModel()
        viewModel.nextPageURL = nil

        await viewModel.loadNextPage()

        XCTAssertEqual(mockRepository.loadTopLevelCatalogCallCount, 0)
        XCTAssertFalse(viewModel.isLoadingMore)
    }

    func testLoadNextPage_WhenAlreadyLoading_DoesNothing() async {
        let viewModel = createViewModel()
        viewModel.nextPageURL = URL(string: "https://example.com/page2")
        viewModel.isLoadingMore = true

        await viewModel.loadNextPage()

        // Should not make additional call
        XCTAssertEqual(mockRepository.loadTopLevelCatalogCallCount, 0)
    }

    func testLoadNextPage_SetsIsLoadingMore() async {
        let viewModel = createViewModel()
        viewModel.nextPageURL = URL(string: "https://example.com/page2")

        // Add delay to observe loading state
        mockRepository.simulatedDelay = 0.2

        let expectation = XCTestExpectation(description: "isLoadingMore becomes true")

        viewModel.$isLoadingMore
            .dropFirst()
            .sink { isLoadingMore in
                if isLoadingMore {
                    expectation.fulfill()
                }
            }
            .store(in: &cancellables)

        Task {
            await viewModel.loadNextPage()
        }

        await fulfillment(of: [expectation], timeout: 1.0)
        // isLoadingMore must have been true at some point during loading
        XCTAssertNotNil(viewModel.nextPageURL != nil || viewModel.isLoadingMore == false,
                        "After loadNextPage completes, isLoadingMore must eventually return to false")
    }

    func testLoadNextPage_DoesNotChangeSearchId() async {
        let viewModel = createViewModel()
        let initialSearchId = viewModel.searchId
        viewModel.nextPageURL = URL(string: "https://example.com/page2")

        await viewModel.loadNextPage()

        XCTAssertEqual(viewModel.searchId, initialSearchId, "searchId should not change during pagination")
    }

    // MARK: - Apply Registry Updates Tests

    func testApplyRegistryUpdates_DoesNotChangeSearchId() {
        let viewModel = createViewModel()
        let books = [createTestBook()]
        viewModel.updateBooks(books)
        viewModel.filteredBooks = books

        let initialSearchId = viewModel.searchId

        viewModel.applyRegistryUpdates(changedIdentifier: nil)

        XCTAssertEqual(viewModel.searchId, initialSearchId, "searchId should not change during registry updates")
    }

    func testApplyRegistryUpdates_WithEmptyFilteredBooks_DoesNothing() {
        let viewModel = createViewModel()
        viewModel.filteredBooks = []
        let initialSearchId = viewModel.searchId

        // Should not crash or throw
        viewModel.applyRegistryUpdates(changedIdentifier: nil)

        XCTAssertTrue(viewModel.filteredBooks.isEmpty)
        XCTAssertEqual(viewModel.searchId, initialSearchId, "searchId must not change during registry updates on empty books")
    }

    // MARK: - Edge Case Tests

    func testSearch_SpecialCharacters_DoesNotCrash() async {
        let viewModel = createViewModel()

        viewModel.updateSearchQuery("Harry's Book & Other Stories (Volume 1)")

        await viewModel._awaitInFlightWorkForTesting()

        // Should not crash and query should be stored
        XCTAssertEqual(mockRepository.lastSearchQuery, "Harry's Book & Other Stories (Volume 1)")
    }

    func testSearch_UnicodeCharacters_Works() async {
        let viewModel = createViewModel()
        viewModel.updateSearchQuery("日本語の本")

        await viewModel._awaitInFlightWorkForTesting()
        XCTAssertEqual(mockRepository.lastSearchQuery, "日本語の本")
    }

    func testSearch_VeryLongQuery_Works() async {
        let viewModel = createViewModel()
        let longQuery = (0..<100).map { _ in "test" }.joined(separator: " ")

        viewModel.updateSearchQuery(longQuery)

        await viewModel._awaitInFlightWorkForTesting()
        XCTAssertEqual(mockRepository.lastSearchQuery, longQuery)
    }

    func testUpdateBooks_EmptyArray_Works() {
        let viewModel = createViewModel()
        viewModel.updateBooks([createTestBook()])
        XCTAssertFalse(viewModel.filteredBooks.isEmpty, "Precondition: must have books before clearing")

        viewModel.updateBooks([])

        XCTAssertTrue(viewModel.filteredBooks.isEmpty)
        XCTAssertEqual(viewModel.searchQuery, "", "Query must remain empty after clearing books")
    }

    func testUpdateBooks_LargeArray_Works() {
        let viewModel = createViewModel()
        let books = (0..<100).map { _ in createTestBook() }

        viewModel.updateBooks(books)

        XCTAssertEqual(viewModel.filteredBooks.count, 100)
        XCTAssertFalse(viewModel.isLoading, "isLoading must be false after updateBooks completes")
    }

    // MARK: - Concurrent Operation Tests

    func testConcurrentUpdates_DoNotCrash() async {
        let viewModel = createViewModel()
        let books = [createTestBook(), createTestBook()]

        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                viewModel.updateBooks(books)
            }
            group.addTask { @MainActor in
                viewModel.updateSearchQuery("test")
            }
            group.addTask { @MainActor in
                viewModel.clearSearch()
            }
        }

        XCTAssertNotNil(viewModel)
    }

    // MARK: - PP-3605 Regression Tests: Scroll Position on Pagination

    /// Regression test for PP-3605: Search results scroll to top during pagination
    /// The searchId should NOT change when pagination loads more books,
    /// so the view doesn't scroll back to the top.
    func testPP3605_LoadNextPage_DoesNotChangeSearchId() async {
        let viewModel = createViewModel()

        // Set up mock to return results with a next page URL
        let nextPageURL = URL(string: "https://example.com/catalog?page=2")!
        viewModel.nextPageURL = nextPageURL

        // Perform initial search
        viewModel.updateSearchQuery("sky")
        await viewModel._awaitInFlightWorkForTesting()

        // Capture the searchId after initial search
        let searchIdAfterInitialSearch = viewModel.searchId

        // Now load next page (pagination)
        await viewModel.loadNextPage()

        // searchId should NOT change after pagination
        XCTAssertEqual(
            viewModel.searchId,
            searchIdAfterInitialSearch,
            "searchId should remain unchanged during pagination to preserve scroll position"
        )
    }

    /// Regression test for PP-3605: Search results scroll to top on registry updates
    /// The searchId should NOT change when registry updates refresh book states.
    func testPP3605_ApplyRegistryUpdates_DoesNotChangeSearchId() {
        let viewModel = createViewModel()
        let books = [createTestBook(), createTestBook()]
        viewModel.updateBooks(books)

        // Simulate having search results
        viewModel.filteredBooks = books

        // Capture the searchId before registry update
        let searchIdBeforeUpdate = viewModel.searchId

        // Apply registry updates (simulates book state changes like downloads)
        viewModel.applyRegistryUpdates(changedIdentifier: nil)

        // searchId should NOT change after registry updates
        XCTAssertEqual(
            viewModel.searchId,
            searchIdBeforeUpdate,
            "searchId should remain unchanged during registry updates to preserve scroll position"
        )
    }

    /// Test that searchId DOES change when a new search query is entered
    func testPP3605_NewSearch_ChangesSearchId() async {
        let viewModel = createViewModel()

        // Capture initial searchId
        let initialSearchId = viewModel.searchId

        // Perform a search
        viewModel.updateSearchQuery("harry potter")
        await viewModel._awaitInFlightWorkForTesting()

        // searchId SHOULD change for a new search
        XCTAssertNotEqual(
            viewModel.searchId,
            initialSearchId,
            "searchId should change when performing a new search to trigger scroll to top"
        )
    }

    /// Test that searchId changes again for subsequent different searches
    func testPP3605_DifferentSearches_EachHaveUniqueSearchId() async {
        let viewModel = createViewModel()

        // First search
        viewModel.updateSearchQuery("sky")
        await viewModel._awaitInFlightWorkForTesting()
        let firstSearchId = viewModel.searchId

        // Second different search
        viewModel.updateSearchQuery("ocean")
        await viewModel._awaitInFlightWorkForTesting()
        let secondSearchId = viewModel.searchId

        // Each search should have a unique searchId
        XCTAssertNotEqual(
            firstSearchId,
            secondSearchId,
            "Different searches should have different searchIds"
        )
    }

    // MARK: - Format Entry Points Tests

    func testLoadFormatEntryPoints_WhenSuccessful_PopulatesFormatEntries() async {
        mockRepository.fetchSearchEntryPointsResult = makeFormatEntries()
        let viewModel = createViewModel()

        viewModel.loadFormatEntryPoints()
        await waitForFormatEntries(on: viewModel, count: 3)

        XCTAssertEqual(viewModel.formatEntries.count, 3)
        XCTAssertEqual(viewModel.formatEntries[0].title, "All")
        XCTAssertEqual(viewModel.formatEntries[1].title, "eBooks")
        XCTAssertEqual(viewModel.formatEntries[2].title, "Audiobooks")
    }

    func testLoadFormatEntryPoints_SelectsActiveEntry() async {
        let entries = [
            SearchFormatEntry(id: "all", title: "All",
                              groupsFeedURL: URL(string: "https://example.com/groups/?entrypoint=All")!,
                              searchDescriptorURL: nil, isActive: false),
            SearchFormatEntry(id: "audio", title: "Audiobooks",
                              groupsFeedURL: URL(string: "https://example.com/groups/?entrypoint=Audio")!,
                              searchDescriptorURL: URL(string: "https://example.com/search/?entrypoint=Audio")!,
                              isActive: true),
        ]
        mockRepository.fetchSearchEntryPointsResult = entries
        let viewModel = createViewModel()

        viewModel.loadFormatEntryPoints()
        await waitForFormatEntries(on: viewModel, count: 2)

        XCTAssertEqual(viewModel.selectedFormatIndex, 1, "Should pre-select the active entry point")
    }

    func testLoadFormatEntryPoints_WhenFeedHasNoEntryPoints_LeavesFormatEntriesEmpty() async {
        mockRepository.fetchSearchEntryPointsResult = []
        let viewModel = createViewModel()

        viewModel.loadFormatEntryPoints()
        await waitForFormatEntriesLoaded(on: viewModel)

        XCTAssertTrue(viewModel.formatEntries.isEmpty)
    }

    func testLoadFormatEntryPoints_WhenFetchFails_LeavesFormatEntriesEmpty() async {
        mockRepository.fetchSearchEntryPointsError = TestError.networkError
        let viewModel = createViewModel()

        viewModel.loadFormatEntryPoints()

        // On error the formatEntries publisher is never reassigned, so we JOIN the
        // retained entry-point load Task (which runs the catch block) instead of
        // polling. Deterministic — the Task completing IS the signal, no clock.
        await viewModel._awaitInFlightWorkForTesting()

        XCTAssertTrue(viewModel.formatEntries.isEmpty)
    }

    func testLoadFormatEntryPoints_WithNilBaseURL_DoesNotCallRepository() async {
        let viewModel = createViewModelWithNilURL()

        viewModel.loadFormatEntryPoints()

        // With a nil baseURL, loadFormatEntryPoints returns before spawning a Task,
        // so there is nothing to await — the seam resolves immediately. This
        // replaces the fixed sleep with a deterministic (empty) join.
        await viewModel._awaitInFlightWorkForTesting()

        XCTAssertEqual(mockRepository.fetchSearchEntryPointsCallCount, 0)
        XCTAssertTrue(viewModel.formatEntries.isEmpty)
    }

    func testSelectFormat_ChangesSelectedIndex() async {
        mockRepository.fetchSearchEntryPointsResult = makeFormatEntries()
        let viewModel = createViewModel()
        viewModel.loadFormatEntryPoints()
        await waitForFormatEntries(on: viewModel, count: 3)

        viewModel.selectFormat(at: 1)

        XCTAssertEqual(viewModel.selectedFormatIndex, 1)
    }

    func testSelectFormat_SameIndex_DoesNotChangeIndex() async {
        mockRepository.fetchSearchEntryPointsResult = makeFormatEntries()
        let viewModel = createViewModel()
        viewModel.loadFormatEntryPoints()
        await waitForFormatEntries(on: viewModel, count: 3)

        viewModel.selectFormat(at: 0)

        // selectFormat(at: 0) hits the same-index guard and returns synchronously —
        // it spawns no search work. Join any retained in-flight work (there is none
        // new) and assert the synchronously-decided state. No clock.
        await viewModel._awaitInFlightWorkForTesting()

        XCTAssertEqual(viewModel.selectedFormatIndex, 0)
        XCTAssertEqual(mockRepository.searchCallCount, 0, "Should not trigger search when selecting already-active format")
    }

    func testSelectFormat_WithActiveQuery_TriggersNewSearch() async {
        mockRepository.fetchSearchEntryPointsResult = makeFormatEntries()
        let viewModel = createViewModel()
        viewModel.loadFormatEntryPoints()
        await waitForFormatEntries(on: viewModel, count: 3)

        // First search may use the searchDescriptorURL path (format "All" has one
        // cached), which doesn't call onSearchCalled — but it still runs through the
        // retained searchTask, so a deterministic JOIN covers every target path.
        viewModel.updateSearchQuery("mystery")
        await viewModel._awaitInFlightWorkForTesting()
        let callCountAfterFirstSearch = mockRepository.searchCallCount + mockRepository.searchWithDescriptorCallCount

        // Format switch calls performSearch() directly (cancels debounce) and
        // assigns a fresh searchTask; join it deterministically. No clock.
        viewModel.selectFormat(at: 1)
        await viewModel._awaitInFlightWorkForTesting()

        XCTAssertGreaterThan(
            mockRepository.searchCallCount + mockRepository.searchWithDescriptorCallCount,
            callCountAfterFirstSearch,
            "Selecting a format should trigger a re-search when query is active"
        )
    }

    func testSelectFormat_WithCachedDescriptorURL_UsesDescriptorSearch() async {
        let descriptorURL = URL(string: "https://example.com/search/?entrypoint=Book")!
        let entries = [
            SearchFormatEntry(id: "all", title: "All",
                              groupsFeedURL: URL(string: "https://example.com/groups/?entrypoint=All")!,
                              searchDescriptorURL: URL(string: "https://example.com/search/?entrypoint=All")!,
                              isActive: true),
            SearchFormatEntry(id: "books", title: "eBooks",
                              groupsFeedURL: URL(string: "https://example.com/groups/?entrypoint=Book")!,
                              searchDescriptorURL: descriptorURL,
                              isActive: false),
        ]
        mockRepository.fetchSearchEntryPointsResult = entries
        let viewModel = createViewModel()
        viewModel.loadFormatEntryPoints()
        await waitForFormatEntries(on: viewModel, count: 2)

        // First search runs through the retained searchTask regardless of which
        // target path (base vs descriptor) it takes — JOIN it deterministically.
        viewModel.updateSearchQuery("mystery")
        await viewModel._awaitInFlightWorkForTesting()

        // Select eBooks (index 1) — it has a searchDescriptorURL pre-populated, so
        // this drives search(query:searchDescriptorURL:) (which does NOT call
        // onSearchCalled). The seam joins the fresh searchTask directly. No clock.
        viewModel.selectFormat(at: 1)
        await viewModel._awaitInFlightWorkForTesting()

        XCTAssertEqual(mockRepository.lastSearchDescriptorURL, descriptorURL,
                       "Should use cached search descriptor URL for eBooks format")
    }

    func testSelectFormat_WithEmptyQuery_DoesNotSearch() async {
        mockRepository.fetchSearchEntryPointsResult = makeFormatEntries()
        let viewModel = createViewModel()
        viewModel.loadFormatEntryPoints()
        await waitForFormatEntries(on: viewModel, count: 3)

        viewModel.selectFormat(at: 2)

        // With an empty query, selectFormat takes the filter-in-place branch and
        // triggers no search (searchTask stays nil). Join any retained in-flight
        // work — none is spawned on the search path — and assert. No clock.
        await viewModel._awaitInFlightWorkForTesting()

        XCTAssertEqual(mockRepository.searchCallCount, 0, "Should not search when query is empty")
        XCTAssertEqual(mockRepository.searchWithDescriptorCallCount, 0)
    }

    func testSearch_WithNoFormatEntries_UsesDefaultBaseURL() async {
        mockRepository.fetchSearchEntryPointsResult = []
        let viewModel = createViewModel()
        viewModel.loadFormatEntryPoints()
        await waitForFormatEntriesLoaded(on: viewModel)

        viewModel.updateSearchQuery("ocean")
        await viewModel._awaitInFlightWorkForTesting()

        XCTAssertEqual(mockRepository.lastSearchURL, testBaseURL,
                       "Should fall back to default base URL when no format entries")
    }

    func testClearSearch_ResetsSelectedFormat_DoesNotChangeFormatEntries() async {
        mockRepository.fetchSearchEntryPointsResult = makeFormatEntries()
        let viewModel = createViewModel()
        viewModel.loadFormatEntryPoints()
        await waitForFormatEntries(on: viewModel, count: 3)

        viewModel.selectFormat(at: 2)
        XCTAssertEqual(viewModel.selectedFormatIndex, 2)

        viewModel.clearSearch()

        // Format entries remain; selected index is unchanged (clear only resets search state)
        XCTAssertEqual(viewModel.formatEntries.count, 3, "Format entries should persist after clear")
        XCTAssertEqual(viewModel.selectedFormatIndex, 2, "Selected format should persist after clear")
    }

    // MARK: - Format Test Helper

    private func makeFormatEntries() -> [SearchFormatEntry] {
        [
            SearchFormatEntry(
                id: "all",
                title: "All",
                groupsFeedURL: URL(string: "https://example.com/groups/?entrypoint=All")!,
                searchDescriptorURL: URL(string: "https://example.com/search/?entrypoint=All")!,
                isActive: true
            ),
            SearchFormatEntry(
                id: "books",
                title: "eBooks",
                groupsFeedURL: URL(string: "https://example.com/groups/?entrypoint=Book")!,
                searchDescriptorURL: nil,
                isActive: false
            ),
            SearchFormatEntry(
                id: "audio",
                title: "Audiobooks",
                groupsFeedURL: URL(string: "https://example.com/groups/?entrypoint=Audio")!,
                searchDescriptorURL: nil,
                isActive: false
            ),
        ]
    }

    /// Test that clearing search changes searchId (to scroll to top of all books)
    func testPP3605_ClearSearch_ChangesSearchId() {
        let viewModel = createViewModel()
        let books = [createTestBook()]
        viewModel.updateBooks(books)

        // Set up a search state
        viewModel.searchQuery = "test"
        let searchIdBeforeClear = viewModel.searchId

        // Clear the search
        viewModel.clearSearch()

        // searchId SHOULD change when clearing search to scroll to top of results
        XCTAssertNotEqual(
            viewModel.searchId,
            searchIdBeforeClear,
            "searchId should change when clearing search to trigger scroll to top"
        )
    }

    // MARK: - PP-3673: VoiceOver Search Announcements

    /// PP-3673: When search returns nil (no results), VoiceOver announces "no results".
    func testPP3673_search_noResults_announcesNoResults() async {
        let capture = AnnouncementCapture()
        let announcer = makeCapturingAnnouncer(capture: capture)
        let viewModel = createViewModel(announcements: announcer)

        mockRepository.searchResult = nil

        // The announcement posts on a delayed main hop after the search task, so
        // await the actual announcement event (deterministic — see helper).
        await awaitNextAnnouncement(capture) {
            viewModel.updateSearchQuery("nonexistent")
        }

        let noResultMsg = capture.items.first(where: { $0.lowercased().contains("no results") })
        XCTAssertNotNil(noResultMsg, "Should announce no results, got: \(capture.items)")
    }

    /// PP-3673: When search fails with error, VoiceOver announces the failure.
    func testPP3673_search_error_announcesFailure() async {
        let capture = AnnouncementCapture()
        let announcer = makeCapturingAnnouncer(capture: capture)
        let viewModel = createViewModel(announcements: announcer)

        mockRepository.searchError = TestError.networkError

        // The failure announcement posts on a delayed main hop after the search
        // task's catch block, so await the actual announcement event.
        await awaitNextAnnouncement(capture) {
            viewModel.updateSearchQuery("test")
        }

        let failMsg = capture.items.first(where: {
            $0.lowercased().contains("search") && ($0.lowercased().contains("failed") || $0.lowercased().contains("error"))
        })
        XCTAssertNotNil(failMsg, "Should announce search failure, got: \(capture.items)")
    }

    /// PP-3673: When search is re-run with different results, VoiceOver announces updated status.
    func testPP3673_search_rerun_announcesUpdatedResults() async {
        let capture = AnnouncementCapture()
        let announcer = makeCapturingAnnouncer(capture: capture)
        let viewModel = createViewModel(announcements: announcer)

        // First search returns no results. Await the actual announcement event
        // (posts on a delayed main hop after the search task).
        mockRepository.searchResult = nil

        await awaitNextAnnouncement(capture) {
            viewModel.updateSearchQuery("first")
        }

        let firstAnnouncements = capture.items.count
        XCTAssertGreaterThan(firstAnnouncements, 0, "Should have at least one announcement")

        // Second search — await its announcement event too.
        await awaitNextAnnouncement(capture) {
            viewModel.updateSearchQuery("second")
        }

        XCTAssertGreaterThan(capture.items.count, firstAnnouncements,
                             "Should produce a new announcement for the second search")
    }

    /// PP-3673: Empty query does NOT produce a VoiceOver announcement.
    func testPP3673_search_emptyQuery_doesNotAnnounce() async {
        let capture = AnnouncementCapture()
        let announcer = makeCapturingAnnouncer(capture: capture)
        let viewModel = createViewModel(announcements: announcer)

        viewModel.updateSearchQuery("")

        // JOIN the debounce Task: performSearch() takes the empty-query branch,
        // which never spawns a searchTask and never announces. Awaiting guarantees
        // the branch ran before we assert the non-announcement — no clock.
        await viewModel._awaitInFlightWorkForTesting()

        XCTAssertTrue(capture.items.isEmpty, "Empty query should not trigger announcements, got: \(capture.items)")
    }

    /// PP-3673: Clearing search does NOT produce a VoiceOver announcement.
    func testPP3673_clearSearch_doesNotAnnounce() async {
        let capture = AnnouncementCapture()
        let announcer = makeCapturingAnnouncer(capture: capture)
        let viewModel = createViewModel(announcements: announcer)

        viewModel.updateSearchQuery("test")
        // Deterministic JOIN on the debounce→search chain (announce side effect
        // included) instead of an onSearchCalled deadline poll.
        await viewModel._awaitInFlightWorkForTesting()

        // Clear captured announcements before testing clearSearch
        capture.items.removeAll()

        viewModel.clearSearch()

        // clearSearch cancels all in-flight work and spawns NO announcing task.
        // Join whatever work remains (there is none) — deterministic, no clock.
        await viewModel._awaitInFlightWorkForTesting()

        XCTAssertTrue(capture.items.isEmpty, "Clearing search should not produce announcements, got: \(capture.items)")
    }

    // MARK: - Empty-Results State Tests (BUG-003)
    //
    // Background: prior to this change, a successful search returning zero books
    // rendered a completely blank screen — no spinner, no message — making it
    // indistinguishable from a hung request. The view model now exposes a
    // `hasCompletedSearch` flag plus a derived `shouldShowNoResultsState` so the
    // view can render a "No results" empty state in that case.

    func testHasCompletedSearch_StartsFalse() {
        let viewModel = createViewModel()

        XCTAssertFalse(
            viewModel.hasCompletedSearch,
            "hasCompletedSearch must be false before any search runs (no result has been observed yet)"
        )
    }

    func testHasCompletedSearch_BecomesTrue_AfterSearchReturnsEmpty() async {
        let viewModel = createViewModel()
        // Repository returns nil → zero results path
        mockRepository.searchResult = nil

        viewModel.updateSearchQuery("zzzzzzzzz")
        // JOIN the searchTask. Its defer block (isLoading=false /
        // hasCompletedSearch=true) runs INSIDE the task, so awaiting the task value
        // captures the deferred assignments — no separate flush sleep needed.
        await viewModel._awaitInFlightWorkForTesting()

        XCTAssertTrue(viewModel.filteredBooks.isEmpty, "Sanity: zero-result search must produce empty filteredBooks")
        XCTAssertFalse(viewModel.isLoading, "Sanity: search must have finished")
        XCTAssertTrue(
            viewModel.hasCompletedSearch,
            "hasCompletedSearch must flip to true once a zero-result search has finished so the view can show an empty state"
        )
    }

    func testHasCompletedSearch_ResetByClearSearch() async {
        let viewModel = createViewModel()
        mockRepository.searchResult = nil
        viewModel.updateSearchQuery("zzzzzzzzz")
        // JOIN the searchTask (its defer sets hasCompletedSearch=true). No clock.
        await viewModel._awaitInFlightWorkForTesting()

        XCTAssertTrue(viewModel.hasCompletedSearch, "Precondition: search must have completed")

        viewModel.clearSearch()

        XCTAssertFalse(
            viewModel.hasCompletedSearch,
            "clearSearch must reset hasCompletedSearch — the empty grid is now 'no query yet', not 'no results'"
        )
    }

    func testHasCompletedSearch_FlipsTrue_OnSearchError() async {
        let viewModel = createViewModel()
        mockRepository.searchError = TestError.networkError

        viewModel.updateSearchQuery("zzzzzzzzz")
        // JOIN the searchTask; its defer sets hasCompletedSearch=true even on the
        // thrown-error path (defer runs regardless of the catch). No clock.
        await viewModel._awaitInFlightWorkForTesting()

        // An errored search has still "completed" from the user's perspective —
        // they typed a query, the spinner stopped, and the grid is empty. The
        // empty-state branch is responsible for telling them so.
        XCTAssertTrue(
            viewModel.hasCompletedSearch,
            "hasCompletedSearch must flip true even when search throws, so the UI doesn't sit blank after a failure"
        )
        XCTAssertTrue(viewModel.filteredBooks.isEmpty)
    }

    func testShouldShowNoResultsState_True_WhenSearchCompletedWithZeroResults() async {
        let viewModel = createViewModel()
        mockRepository.searchResult = nil

        viewModel.updateSearchQuery("zzzzzzzzz")
        // JOIN the searchTask (defer sets isLoading=false + hasCompletedSearch=true,
        // the two inputs shouldShowNoResultsState reads). No clock.
        await viewModel._awaitInFlightWorkForTesting()

        XCTAssertTrue(
            viewModel.shouldShowNoResultsState,
            "After a completed, non-empty-query search with zero books, the no-results empty state must be shown"
        )
    }

    func testShouldShowNoResultsState_False_WhileLoading() async {
        // Hold the search task open long enough to observe the loading state.
        mockRepository.simulatedDelay = 0.3
        mockRepository.searchResult = nil

        let viewModel = createViewModel()

        let loadingExp = expectation(description: "isLoading observed true")
        var observed = false
        viewModel.$isLoading
            .dropFirst()
            .sink { isLoading in
                if isLoading && !observed {
                    observed = true
                    loadingExp.fulfill()
                }
            }
            .store(in: &cancellables)

        viewModel.updateSearchQuery("zzzzzzzzz")
        await fulfillment(of: [loadingExp], timeout: 5.0)

        // While the request is in flight, the no-results state must NOT be shown —
        // a spinner is the right affordance there.
        XCTAssertTrue(viewModel.isLoading, "Precondition: in-flight search")
        XCTAssertFalse(
            viewModel.shouldShowNoResultsState,
            "An in-flight search must not render the no-results empty state (loading != confirmed-empty)"
        )
    }

    func testShouldShowNoResultsState_False_WhenQueryEmpty() {
        let viewModel = createViewModel()

        // Force the view model into a "search ran, zero results, then user cleared the box"
        // posture by directly manipulating state — clearSearch resets hasCompletedSearch,
        // but we want to assert the guard against an empty query specifically.
        viewModel.searchQuery = ""
        viewModel.filteredBooks = []

        XCTAssertFalse(
            viewModel.shouldShowNoResultsState,
            "An empty query must never trigger the no-results state — there's no query to be 'no results for'"
        )
    }

    func testShouldShowNoResultsState_False_WhenResultsPresent() async {
        let viewModel = createViewModel()

        // Simulate a completed search that returned books.
        viewModel.searchQuery = "test"
        viewModel.filteredBooks = [createTestBook()]
        viewModel.isLoading = false
        viewModel.markSearchCompletedForTesting()

        XCTAssertFalse(
            viewModel.shouldShowNoResultsState,
            "If results exist the no-results state must not be shown — the books grid takes over"
        )
    }
}
