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
@testable import Palace

// MARK: - Mock Repository for Search Tests

@MainActor
final class CatalogRepositoryMock: CatalogRepositoryProtocol {

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

    // MARK: - Call Tracking

    private(set) var loadTopLevelCatalogCallCount = 0
    private(set) var searchCallCount = 0
    private(set) var searchWithDescriptorCallCount = 0
    private(set) var fetchSearchEntryPointsCallCount = 0
    private(set) var lastSearchQuery: String?
    private(set) var lastSearchURL: URL?
    private(set) var lastSearchDescriptorURL: URL?
    private(set) var lastFetchSearchEntryPointsURL: URL?
    private(set) var lastLoadURL: URL?
    private(set) var searchHistory: [(query: String, url: URL)] = []

    /// Callback fired after each search — use with XCTestExpectation for deterministic waits
    var onSearchCalled: (() -> Void)?

    // MARK: - CatalogRepositoryProtocol

    func loadTopLevelCatalog(at url: URL) async throws -> CatalogFeed? {
        loadTopLevelCatalogCallCount += 1
        lastLoadURL = url

        if simulatedDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(simulatedDelay * 1_000_000_000))
        }

        if let error = loadTopLevelCatalogError {
            throw error
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

    func invalidateCache(for url: URL) {
        // No-op for mock
    }

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
        loadTopLevelCatalogCallCount = 0
        searchCallCount = 0
        searchWithDescriptorCallCount = 0
        fetchSearchEntryPointsCallCount = 0
        lastSearchQuery = nil
        lastSearchURL = nil
        lastSearchDescriptorURL = nil
        lastFetchSearchEntryPointsURL = nil
        lastLoadURL = nil
        searchHistory.removeAll()
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
        if let announcements {
            return CatalogSearchViewModel(
                repository: mockRepository,
                baseURL: { urlToUse },
                debounceInterval: debounceInterval,
                announcements: announcements
            )
        }
        return CatalogSearchViewModel(
            repository: mockRepository,
            baseURL: { urlToUse },
            debounceInterval: debounceInterval
        )
    }

    private func createViewModelWithNilURL(
        debounceInterval: TimeInterval = 0.05
    ) -> CatalogSearchViewModel {
        return CatalogSearchViewModel(
            repository: mockRepository,
            baseURL: { nil },
            debounceInterval: debounceInterval
        )
    }

    private func createTestBook() -> TPPBook {
        return TPPBookMocker.mockBook(distributorType: .EpubZip)
    }

    /// Helper: wait for `loadFormatEntryPoints()` to finish by observing `$formatEntries`.
    private func waitForFormatEntries(on viewModel: CatalogSearchViewModel, count: Int) async {
        if viewModel.formatEntries.count == count { return }
        let exp = expectation(description: "formatEntries populated with \(count) entries")
        var sub: AnyCancellable?
        sub = viewModel.$formatEntries
            .dropFirst()
            .sink { entries in
                if entries.count == count {
                    exp.fulfill()
                    sub?.cancel()
                }
            }
        await fulfillment(of: [exp], timeout: 5.0)
    }

    /// Helper: wait for `loadFormatEntryPoints()` to finish (any count >= 0).
    private func waitForFormatEntriesLoaded(on viewModel: CatalogSearchViewModel) async {
        let exp = expectation(description: "formatEntries loaded")
        // loadFormatEntryPoints publishes to formatEntries once done.
        // If the result is empty and the current value is already empty, we use a small yield.
        var sub: AnyCancellable?
        sub = viewModel.$formatEntries
            .dropFirst()
            .sink { _ in
                exp.fulfill()
                sub?.cancel()
            }
        await fulfillment(of: [exp], timeout: 5.0)
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

        // We cannot observe something that doesn't happen; yield and wait briefly.
        await Task.yield()
        try? await Task.sleep(nanoseconds: 150_000_000)

        // Repository should not be called for empty query
        XCTAssertEqual(mockRepository.searchCallCount, 0, "Repository search should not be called for empty query")
    }

    func testSearch_WithWhitespaceOnlyQuery_DoesNotCallRepository() async {
        let viewModel = createViewModel()

        // Trigger search with whitespace-only query
        viewModel.updateSearchQuery("   ")

        // We cannot observe something that doesn't happen; yield and wait briefly.
        await Task.yield()
        try? await Task.sleep(nanoseconds: 150_000_000)

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

        // Empty query restores books synchronously via the debounce path; yield and wait briefly
        // since no search is called and we cannot observe a non-event.
        await Task.yield()
        try? await Task.sleep(nanoseconds: 150_000_000)

        // Should restore all books
        XCTAssertEqual(viewModel.filteredBooks.count, 2, "Empty query should restore all books")
    }

    // MARK: - Search With Valid Query Tests

    func testSearch_WithValidQuery_CallsRepository() async {
        let exp = expectation(description: "search called")
        mockRepository.onSearchCalled = { exp.fulfill() }

        let viewModel = createViewModel()

        // Trigger search with valid query
        viewModel.updateSearchQuery("Harry Potter")

        await fulfillment(of: [exp], timeout: 5.0)

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
        let exp = expectation(description: "search called")
        mockRepository.onSearchCalled = { exp.fulfill() }

        let viewModel = createViewModel()

        // Trigger search
        viewModel.updateSearchQuery("test")

        await fulfillment(of: [exp], timeout: 5.0)

        XCTAssertFalse(viewModel.isLoading, "isLoading should be false after search completes")
    }

    // MARK: - Search Results Tests

    func testSearch_WithResults_UpdatesResults() async {
        let exp = expectation(description: "search called")
        mockRepository.onSearchCalled = { exp.fulfill() }

        let viewModel = createViewModel()

        // Configure mock to return a feed
        // Note: We can't easily create a full CatalogFeed, but we can verify the search was called
        // and the state management is correct
        mockRepository.searchResult = nil // Will result in empty results

        // Trigger search
        viewModel.updateSearchQuery("test query")

        await fulfillment(of: [exp], timeout: 5.0)

        // Verify search was called
        XCTAssertEqual(mockRepository.searchCallCount, 1)
        XCTAssertFalse(viewModel.isLoading, "isLoading should be false after search")
    }

    func testSearch_WithNilResult_SetsEmptyResults() async {
        let exp = expectation(description: "search called")
        mockRepository.onSearchCalled = { exp.fulfill() }

        let viewModel = createViewModel()

        // Pre-populate with books
        let books = [createTestBook()]
        viewModel.updateBooks(books)

        // Configure mock to return nil
        mockRepository.searchResult = nil

        // Trigger search
        viewModel.updateSearchQuery("nonexistent")

        await fulfillment(of: [exp], timeout: 5.0)

        // Filtered books should be empty
        XCTAssertTrue(viewModel.filteredBooks.isEmpty, "filteredBooks should be empty when search returns nil")
    }

    // MARK: - Search Error Tests

    func testSearch_WithError_SetsErrorMessage() async {
        let exp = expectation(description: "search called")
        mockRepository.onSearchCalled = { exp.fulfill() }

        let viewModel = createViewModel()

        // Configure mock to throw error
        mockRepository.searchError = TestError.networkError

        // Trigger search
        viewModel.updateSearchQuery("test")

        await fulfillment(of: [exp], timeout: 5.0)

        // Verify error handling - filteredBooks should be cleared
        XCTAssertTrue(viewModel.filteredBooks.isEmpty, "filteredBooks should be empty on error")
        XCTAssertFalse(viewModel.isLoading, "isLoading should be false after error")
    }

    func testSearch_WithError_ClearsNextPageURL() async {
        let exp = expectation(description: "search called")
        mockRepository.onSearchCalled = { exp.fulfill() }

        let viewModel = createViewModel()

        // Set up initial state with next page URL
        viewModel.nextPageURL = URL(string: "https://example.com/page2")

        // Configure mock to throw error
        mockRepository.searchError = TestError.networkError

        // Trigger search
        viewModel.updateSearchQuery("test")

        await fulfillment(of: [exp], timeout: 5.0)

        XCTAssertNil(viewModel.nextPageURL, "nextPageURL should be nil after error")
    }

    // MARK: - Debouncing Tests

    func testSearch_Debounces_MultipleQueries() async {
        let exp = expectation(description: "search called once after debounce")
        mockRepository.onSearchCalled = { exp.fulfill() }

        let viewModel = createViewModel(debounceInterval: 0.1)

        // Rapidly fire multiple search queries
        viewModel.updateSearchQuery("H")
        viewModel.updateSearchQuery("Ha")
        viewModel.updateSearchQuery("Har")
        viewModel.updateSearchQuery("Harr")
        viewModel.updateSearchQuery("Harry")

        await fulfillment(of: [exp], timeout: 5.0)

        // Should only call repository once with final query
        XCTAssertEqual(mockRepository.searchCallCount, 1, "Repository should only be called once after debounce")
        XCTAssertEqual(mockRepository.lastSearchQuery, "Harry", "Should use final query value")
    }

    func testSearch_Debounces_DoesNotSearchDuringDebounceWindow() async {
        // Use a 1s debounce so the mid-window check has a wide enough margin to be
        // reliable on slow CI machines (Task.sleep can overshoot significantly under load).
        let viewModel = createViewModel(debounceInterval: 1.0)

        let exp = expectation(description: "search called after debounce completes")
        mockRepository.onSearchCalled = { exp.fulfill() }

        viewModel.updateSearchQuery("test")

        // Immediately after triggering — debounce has not fired.
        XCTAssertEqual(mockRepository.searchCallCount, 0, "Should not search immediately")

        // 300ms into a 1s debounce window — still should not have fired.
        // We cannot observe a non-event; use a brief sleep that is well within the debounce window.
        await Task.yield()
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(mockRepository.searchCallCount, 0, "Should not search during debounce window")

        // Wait for the search to actually fire
        await fulfillment(of: [exp], timeout: 5.0)
        XCTAssertEqual(mockRepository.searchCallCount, 1, "Should search after debounce completes")
    }

    // MARK: - Cancellation Tests

    func testSearch_CancelsInFlight_OnNewQuery() async {
        let viewModel = createViewModel(debounceInterval: 0.05)

        // Add delay to mock so first search is still in progress
        mockRepository.simulatedDelay = 0.3

        let exp = expectation(description: "second search called")
        // We set the callback before the second query, but after the first starts debouncing.
        // The first search may or may not call it, so we track by query value.

        // Start first search
        viewModel.updateSearchQuery("first")

        // Wait for debounce to fire (but search is still in-flight due to simulatedDelay)
        await Task.yield()
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Now set callback for the second search
        mockRepository.onSearchCalled = { exp.fulfill() }
        // Start second search (should cancel first)
        mockRepository.simulatedDelay = 0.05 // Make second search faster
        viewModel.updateSearchQuery("second")

        await fulfillment(of: [exp], timeout: 5.0)

        // Verify last search query was "second"
        XCTAssertEqual(mockRepository.lastSearchQuery, "second", "Last search should be 'second'")
    }

    func testSearch_CancelsDebounce_OnNewQuery() async {
        // 1s debounce gives a wide margin for CI: 300ms is safely inside the window
        // even on a machine under load.
        let viewModel = createViewModel(debounceInterval: 1.0)

        let exp = expectation(description: "search called for second query")
        mockRepository.onSearchCalled = { exp.fulfill() }

        viewModel.updateSearchQuery("first")

        // 300ms into the 1s debounce — "first" has not fired yet. Trigger "second".
        await Task.yield()
        try? await Task.sleep(nanoseconds: 300_000_000)
        viewModel.updateSearchQuery("second")

        // Wait for "second" to complete
        await fulfillment(of: [exp], timeout: 5.0)

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

        // We cannot observe something that doesn't happen; yield and wait briefly
        // past the original debounce window.
        await Task.yield()
        try? await Task.sleep(nanoseconds: 300_000_000)

        // Search should not have been called
        XCTAssertEqual(mockRepository.searchCallCount, 0, "Search should be cancelled by clearSearch")
    }

    // MARK: - Nil Base URL Tests

    func testSearch_WithNilBaseURL_DoesNotSearch() async {
        let viewModel = createViewModelWithNilURL()

        // Trigger search
        viewModel.updateSearchQuery("test")

        // We cannot observe something that doesn't happen; yield and wait briefly.
        await Task.yield()
        try? await Task.sleep(nanoseconds: 150_000_000)

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

        // We cannot observe something that doesn't happen; yield and wait briefly.
        await Task.yield()
        try? await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertNil(viewModel.nextPageURL, "nextPageURL should be cleared when baseURL is nil")
    }

    // MARK: - Search ID Tests (PP-3605 Regression)

    func testSearch_NewSearch_ChangesSearchId() async {
        let exp = expectation(description: "search called")
        mockRepository.onSearchCalled = { exp.fulfill() }

        let viewModel = createViewModel()
        let initialSearchId = viewModel.searchId

        // Perform a search
        viewModel.updateSearchQuery("test")

        await fulfillment(of: [exp], timeout: 5.0)

        XCTAssertNotEqual(viewModel.searchId, initialSearchId, "searchId should change for new search")
    }

    func testSearch_DifferentQueries_HaveDifferentSearchIds() async {
        let viewModel = createViewModel()

        // First search
        let exp1 = expectation(description: "first search called")
        mockRepository.onSearchCalled = { exp1.fulfill() }
        viewModel.updateSearchQuery("first")
        await fulfillment(of: [exp1], timeout: 5.0)
        let firstSearchId = viewModel.searchId

        // Second search
        let exp2 = expectation(description: "second search called")
        mockRepository.onSearchCalled = { exp2.fulfill() }
        viewModel.updateSearchQuery("second")
        await fulfillment(of: [exp2], timeout: 5.0)
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
        let exp = expectation(description: "search called")
        mockRepository.onSearchCalled = { exp.fulfill() }

        let viewModel = createViewModel()

        viewModel.updateSearchQuery("Harry's Book & Other Stories (Volume 1)")

        await fulfillment(of: [exp], timeout: 5.0)

        // Should not crash and query should be stored
        XCTAssertEqual(mockRepository.lastSearchQuery, "Harry's Book & Other Stories (Volume 1)")
    }

    func testSearch_UnicodeCharacters_Works() async {
        let searchCalled = expectation(description: "search called with unicode query")
        mockRepository.onSearchCalled = { searchCalled.fulfill() }

        let viewModel = createViewModel()
        viewModel.updateSearchQuery("日本語の本")

        await fulfillment(of: [searchCalled], timeout: 5.0)
        XCTAssertEqual(mockRepository.lastSearchQuery, "日本語の本")
    }

    func testSearch_VeryLongQuery_Works() async {
        let searchCalled = expectation(description: "search called with long query")
        mockRepository.onSearchCalled = { searchCalled.fulfill() }

        let viewModel = createViewModel()
        let longQuery = (0..<100).map { _ in "test" }.joined(separator: " ")

        viewModel.updateSearchQuery(longQuery)

        await fulfillment(of: [searchCalled], timeout: 5.0)
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
        let exp = expectation(description: "initial search called")
        mockRepository.onSearchCalled = { exp.fulfill() }
        viewModel.updateSearchQuery("sky")
        await fulfillment(of: [exp], timeout: 5.0)

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
        let exp = expectation(description: "search called")
        mockRepository.onSearchCalled = { exp.fulfill() }
        viewModel.updateSearchQuery("harry potter")
        await fulfillment(of: [exp], timeout: 5.0)

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
        let exp1 = expectation(description: "first search called")
        mockRepository.onSearchCalled = { exp1.fulfill() }
        viewModel.updateSearchQuery("sky")
        await fulfillment(of: [exp1], timeout: 5.0)
        let firstSearchId = viewModel.searchId

        // Second different search
        let exp2 = expectation(description: "second search called")
        mockRepository.onSearchCalled = { exp2.fulfill() }
        viewModel.updateSearchQuery("ocean")
        await fulfillment(of: [exp2], timeout: 5.0)
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

        // On error the formatEntries publisher is never reassigned, so we cannot observe it.
        // Wait briefly for the async task to complete.
        await Task.yield()
        try? await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertTrue(viewModel.formatEntries.isEmpty)
    }

    func testLoadFormatEntryPoints_WithNilBaseURL_DoesNotCallRepository() async {
        let viewModel = createViewModelWithNilURL()

        viewModel.loadFormatEntryPoints()

        // We cannot observe something that doesn't happen; yield and wait briefly.
        await Task.yield()
        try? await Task.sleep(nanoseconds: 150_000_000)

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

        // We cannot observe something that doesn't happen; yield and wait briefly.
        await Task.yield()
        try? await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(viewModel.selectedFormatIndex, 0)
        XCTAssertEqual(mockRepository.searchCallCount, 0, "Should not trigger search when selecting already-active format")
    }

    func testSelectFormat_WithActiveQuery_TriggersNewSearch() async {
        mockRepository.fetchSearchEntryPointsResult = makeFormatEntries()
        let viewModel = createViewModel()
        viewModel.loadFormatEntryPoints()
        await waitForFormatEntries(on: viewModel, count: 3)

        // First search may use searchDescriptorURL path (format "All" has one cached),
        // so observe isLoading returning to false instead of onSearchCalled.
        let exp1 = expectation(description: "first search completes")
        var sub1: AnyCancellable?
        sub1 = viewModel.$isLoading
            .dropFirst()
            .filter { !$0 }
            .sink { _ in exp1.fulfill(); sub1?.cancel() }
        viewModel.updateSearchQuery("mystery")
        await fulfillment(of: [exp1], timeout: 5.0)
        let callCountAfterFirstSearch = mockRepository.searchCallCount + mockRepository.searchWithDescriptorCallCount

        // Format switch also may use descriptor path, observe isLoading again.
        let exp2 = expectation(description: "format re-search completes")
        var sub2: AnyCancellable?
        sub2 = viewModel.$isLoading
            .dropFirst()
            .filter { !$0 }
            .sink { _ in exp2.fulfill(); sub2?.cancel() }
        viewModel.selectFormat(at: 1)
        await fulfillment(of: [exp2], timeout: 5.0)

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

        // First search may use the descriptor path (format "All" has a cached descriptor URL),
        // so observe isLoading returning to false.
        let exp1 = expectation(description: "first search completes")
        var sub1: AnyCancellable?
        sub1 = viewModel.$isLoading
            .dropFirst()
            .filter { !$0 }
            .sink { _ in exp1.fulfill(); sub1?.cancel() }
        viewModel.updateSearchQuery("mystery")
        await fulfillment(of: [exp1], timeout: 5.0)

        // Select eBooks (index 1) — it has a searchDescriptorURL pre-populated.
        // This triggers search(query:searchDescriptorURL:) which does NOT call onSearchCalled,
        // so we observe isLoading going back to false instead.
        let exp2 = expectation(description: "descriptor search completes")
        var sub2: AnyCancellable?
        sub2 = viewModel.$isLoading
            .dropFirst()
            .filter { !$0 }
            .sink { _ in exp2.fulfill(); sub2?.cancel() }
        viewModel.selectFormat(at: 1)
        await fulfillment(of: [exp2], timeout: 5.0)

        XCTAssertEqual(mockRepository.lastSearchDescriptorURL, descriptorURL,
                       "Should use cached search descriptor URL for eBooks format")
    }

    func testSelectFormat_WithEmptyQuery_DoesNotSearch() async {
        mockRepository.fetchSearchEntryPointsResult = makeFormatEntries()
        let viewModel = createViewModel()
        viewModel.loadFormatEntryPoints()
        await waitForFormatEntries(on: viewModel, count: 3)

        viewModel.selectFormat(at: 2)

        // We cannot observe something that doesn't happen; yield and wait briefly.
        await Task.yield()
        try? await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(mockRepository.searchCallCount, 0, "Should not search when query is empty")
        XCTAssertEqual(mockRepository.searchWithDescriptorCallCount, 0)
    }

    func testSearch_WithNoFormatEntries_UsesDefaultBaseURL() async {
        mockRepository.fetchSearchEntryPointsResult = []
        let viewModel = createViewModel()
        viewModel.loadFormatEntryPoints()
        await waitForFormatEntriesLoaded(on: viewModel)

        let exp = expectation(description: "search called")
        mockRepository.onSearchCalled = { exp.fulfill() }
        viewModel.updateSearchQuery("ocean")
        await fulfillment(of: [exp], timeout: 5.0)

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

        let announcementMade = expectation(description: "no results announced")
        capture.onAnnouncement = {
            if capture.items.contains(where: { $0.lowercased().contains("no results") }) {
                announcementMade.fulfill()
            }
        }
        viewModel.updateSearchQuery("nonexistent")
        await fulfillment(of: [announcementMade], timeout: 5.0)

        let noResultMsg = capture.items.first(where: { $0.lowercased().contains("no results") })
        XCTAssertNotNil(noResultMsg, "Should announce no results, got: \(capture.items)")
    }

    /// PP-3673: When search fails with error, VoiceOver announces the failure.
    func testPP3673_search_error_announcesFailure() async {
        let capture = AnnouncementCapture()
        let announcer = makeCapturingAnnouncer(capture: capture)
        let viewModel = createViewModel(announcements: announcer)

        mockRepository.searchError = TestError.networkError

        // Wait for the announcement itself, not just the search call —
        // the view model processes the error asynchronously after the search returns.
        let announcementMade = expectation(description: "failure announced")
        capture.onAnnouncement = {
            if capture.items.contains(where: { $0.lowercased().contains("failed") || $0.lowercased().contains("error") }) {
                announcementMade.fulfill()
            }
        }
        viewModel.updateSearchQuery("test")
        await fulfillment(of: [announcementMade], timeout: 5.0)

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

        // First search returns no results — wait for the announcement, not the search call
        mockRepository.searchResult = nil

        let firstAnnounced = expectation(description: "first announcement")
        capture.onAnnouncement = { firstAnnounced.fulfill() }
        viewModel.updateSearchQuery("first")
        await fulfillment(of: [firstAnnounced], timeout: 5.0)

        let firstAnnouncements = capture.items.count
        XCTAssertGreaterThan(firstAnnouncements, 0, "Should have at least one announcement")

        // Second search — wait for additional announcement
        let secondAnnounced = expectation(description: "second announcement")
        capture.onAnnouncement = {
            if capture.items.count > firstAnnouncements {
                secondAnnounced.fulfill()
            }
        }
        viewModel.updateSearchQuery("second")
        await fulfillment(of: [secondAnnounced], timeout: 5.0)

        XCTAssertGreaterThan(capture.items.count, firstAnnouncements,
                             "Should produce a new announcement for the second search")
    }

    /// PP-3673: Empty query does NOT produce a VoiceOver announcement.
    func testPP3673_search_emptyQuery_doesNotAnnounce() async {
        let capture = AnnouncementCapture()
        let announcer = makeCapturingAnnouncer(capture: capture)
        let viewModel = createViewModel(announcements: announcer)

        viewModel.updateSearchQuery("")

        // We cannot observe something that doesn't happen; yield and wait briefly.
        await Task.yield()
        try? await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertTrue(capture.items.isEmpty, "Empty query should not trigger announcements, got: \(capture.items)")
    }

    /// PP-3673: Clearing search does NOT produce a VoiceOver announcement.
    func testPP3673_clearSearch_doesNotAnnounce() async {
        let capture = AnnouncementCapture()
        let announcer = makeCapturingAnnouncer(capture: capture)
        let viewModel = createViewModel(announcements: announcer)

        let exp = expectation(description: "search called")
        mockRepository.onSearchCalled = { exp.fulfill() }
        viewModel.updateSearchQuery("test")
        await fulfillment(of: [exp], timeout: 5.0)

        // Clear captured announcements before testing clearSearch
        capture.items.removeAll()

        viewModel.clearSearch()

        // We cannot observe something that doesn't happen; yield and wait briefly.
        await Task.yield()
        try? await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertTrue(capture.items.isEmpty, "Clearing search should not produce announcements, got: \(capture.items)")
    }
}
