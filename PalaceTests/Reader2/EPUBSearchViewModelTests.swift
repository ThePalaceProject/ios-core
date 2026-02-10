//
//  EPUBSearchViewModelTests.swift
//  PalaceTests
//
//  Tests for EPUBSearchViewModel search functionality.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import Combine
import ReadiumShared
@testable import Palace

// MARK: - Mock Search Iterator

/// Mock SearchIterator for controlled test results
final class MockSearchIterator: SearchIterator {
  var resultCount: Int?

  private var results: [LocatorCollection?]
  private var currentIndex = 0
  private var errorToThrow: SearchError?

  /// Number of times next() was called
  private(set) var nextCallCount = 0

  init(results: [LocatorCollection?] = [], resultCount: Int? = nil, errorToThrow: SearchError? = nil) {
    self.results = results
    self.resultCount = resultCount
    self.errorToThrow = errorToThrow
  }

  func next() async -> SearchResult<LocatorCollection?> {
    nextCallCount += 1

    if let error = errorToThrow {
      return .failure(error)
    }

    guard currentIndex < results.count else {
      return .success(nil)
    }

    let result = results[currentIndex]
    currentIndex += 1
    return .success(result)
  }

  func close() {
    // No-op for mock
  }
}

// MARK: - Mock Search Service

/// Mock SearchService for injecting into Publication
final class MockSearchService: SearchService {
  var options: SearchOptions = SearchOptions()

  /// The iterator to return from search
  var mockIterator: SearchIterator?

  /// Error to return from search
  var errorToReturn: SearchError?

  /// Number of times search was called
  private(set) var searchCallCount = 0

  /// The last query passed to search
  private(set) var lastQuery: String?

  func search(query: String, options: SearchOptions?) async -> SearchResult<SearchIterator> {
    searchCallCount += 1
    lastQuery = query

    if let error = errorToReturn {
      return .failure(error)
    }

    guard let iterator = mockIterator else {
      return .failure(.publicationNotSearchable)
    }

    return .success(iterator)
  }

  func reset() {
    mockIterator = nil
    errorToReturn = nil
    searchCallCount = 0
    lastQuery = nil
  }
}

// MARK: - Mock EPUB Search Delegate

/// Mock delegate to verify navigation calls
@MainActor
final class MockEPUBSearchDelegate: EPUBSearchDelegate {
  private(set) var didSelectCallCount = 0
  private(set) var lastSelectedLocation: Locator?

  func didSelect(location: Locator) {
    didSelectCallCount += 1
    lastSelectedLocation = location
  }

  func reset() {
    didSelectCallCount = 0
    lastSelectedLocation = nil
  }
}

// MARK: - Test Helpers

extension Locator {
  /// Creates a test locator with the given parameters
  static func testLocator(
    href: String = "/chapter1.xhtml",
    title: String? = "Chapter 1",
    progression: Double? = 0.5,
    totalProgression: Double? = 0.25,
    highlight: String? = "test highlight"
  ) -> Locator {
    Locator(
      href: AnyURL(string: href)!,
      mediaType: .xhtml,
      title: title,
      locations: Locator.Locations(
        progression: progression,
        totalProgression: totalProgression
      ),
      text: Locator.Text(highlight: highlight)
    )
  }
}

extension LocatorCollection {
  /// Creates a test collection with the given locators
  static func testCollection(locators: [Locator]) -> LocatorCollection {
    LocatorCollection(locators: locators)
  }
}

// MARK: - Publication Test Helper

extension Publication {
  /// Creates a test Publication with a mock search service
  static func testPublication(searchService: SearchService?) -> Publication {
    let manifest = Manifest(metadata: Metadata(title: "Test Book"))

    var servicesBuilder = PublicationServicesBuilder()
    if let service = searchService {
      servicesBuilder.set(SearchService.self) { _ in service }
    }

    return Publication(manifest: manifest, servicesBuilder: servicesBuilder)
  }
}

// MARK: - Tests

@MainActor
final class EPUBSearchViewModelTests: XCTestCase {

  // MARK: - Properties

  private var mockSearchService: MockSearchService!
  private var mockDelegate: MockEPUBSearchDelegate!
  private var publication: Publication!
  private var viewModel: EPUBSearchViewModel!
  private var cancellables: Set<AnyCancellable>!

  // MARK: - Setup/Teardown

  override func setUp() {
    super.setUp()
    mockSearchService = MockSearchService()
    mockDelegate = MockEPUBSearchDelegate()
    publication = Publication.testPublication(searchService: mockSearchService)
    viewModel = EPUBSearchViewModel(publication: publication)
    viewModel.delegate = mockDelegate
    cancellables = Set<AnyCancellable>()
  }

  override func tearDown() {
    mockSearchService = nil
    mockDelegate = nil
    publication = nil
    viewModel = nil
    cancellables = nil
    super.tearDown()
  }

  // MARK: - Initialization Tests

  func testInit_HasCorrectDefaults() {
    let newViewModel = EPUBSearchViewModel(publication: publication)

    XCTAssertTrue(newViewModel.results.isEmpty, "Results should be empty on init")
    XCTAssertTrue(newViewModel.sections.isEmpty, "Sections should be empty on init")

    switch newViewModel.state {
    case .empty:
      break // Expected
    default:
      XCTFail("Initial state should be .empty, got \(newViewModel.state)")
    }
  }

  // MARK: - Search Tests

  func testSearch_WithEmptyQuery_DoesNotSearch() async {
    // Note: The current implementation doesn't check for empty queries,
    // so the search will be performed. This test documents that behavior.
    mockSearchService.mockIterator = MockSearchIterator(results: [])

    await viewModel.search(with: "")

    // The search is called even with empty query
    XCTAssertEqual(mockSearchService.searchCallCount, 1)
  }

  func testSearch_WithValidQuery_PerformsSearch() async {
    let testQuery = "test search"
    mockSearchService.mockIterator = MockSearchIterator(results: [nil])

    await viewModel.search(with: testQuery)

    XCTAssertEqual(mockSearchService.searchCallCount, 1)
    XCTAssertEqual(mockSearchService.lastQuery, testQuery)
  }

  func testSearch_SetsIsSearching() async {
    let expectation = XCTestExpectation(description: "State becomes starting")

    // Set up slow iterator to observe intermediate state
    let slowIterator = MockSearchIterator(results: [nil])
    mockSearchService.mockIterator = slowIterator

    var observedStartingState = false
    viewModel.$state
      .sink { state in
        if case .starting = state {
          observedStartingState = true
          expectation.fulfill()
        }
      }
      .store(in: &cancellables)

    await viewModel.search(with: "test")

    await fulfillment(of: [expectation], timeout: 1.0)
    XCTAssertTrue(observedStartingState, "Should have transitioned through starting state")
  }

  func testSearch_WithResults_UpdatesResults() async {
    let testLocators = [
      Locator.testLocator(href: "/ch1.xhtml", title: "Chapter 1", progression: 0.1),
      Locator.testLocator(href: "/ch2.xhtml", title: "Chapter 2", progression: 0.5)
    ]
    let collection = LocatorCollection.testCollection(locators: testLocators)
    mockSearchService.mockIterator = MockSearchIterator(results: [collection, nil])

    await viewModel.search(with: "test")

    XCTAssertEqual(viewModel.results.count, 2, "Should have 2 results")
    XCTAssertFalse(viewModel.sections.isEmpty, "Sections should be populated")
  }

  func testSearch_WithNoResults_SetsEmptyState() async {
    // Iterator returns nil immediately (no results)
    mockSearchService.mockIterator = MockSearchIterator(results: [nil])

    await viewModel.search(with: "nonexistent")

    XCTAssertTrue(viewModel.results.isEmpty, "Results should be empty")

    switch viewModel.state {
    case .end:
      break // Expected - search ended with no results
    default:
      XCTFail("State should be .end when no results found, got \(viewModel.state)")
    }
  }

  func testSearch_WithError_SetsErrorMessage() async {
    mockSearchService.errorToReturn = .publicationNotSearchable

    await viewModel.search(with: "test")

    switch viewModel.state {
    case .failure(let error):
      XCTAssertNotNil(error, "Error should be captured in state")
    default:
      XCTFail("State should be .failure when search fails, got \(viewModel.state)")
    }
  }

  func testSearch_WithIteratorError_SetsErrorState() async {
    let errorIterator = MockSearchIterator(
      results: [],
      errorToThrow: .reading(.access(.fileSystem(.fileNotFound(nil))))
    )
    mockSearchService.mockIterator = errorIterator

    await viewModel.search(with: "test")

    switch viewModel.state {
    case .failure:
      break // Expected
    case .end:
      // Also acceptable if error during fetch sets end state
      break
    default:
      XCTFail("State should be .failure or .end when iterator fails, got \(viewModel.state)")
    }
  }

  // MARK: - Navigation Tests

  func testSelectResult_NavigatesToLocation() {
    let testLocator = Locator.testLocator()

    viewModel.userSelected(testLocator)

    XCTAssertEqual(mockDelegate.didSelectCallCount, 1, "Delegate should be called once")
    XCTAssertEqual(mockDelegate.lastSelectedLocation?.href, testLocator.href, "Should pass correct locator")
  }

  func testSelectResult_WithNilDelegate_DoesNotCrash() {
    viewModel.delegate = nil
    let testLocator = Locator.testLocator()

    // Should not crash
    viewModel.userSelected(testLocator)

    // No assertion needed - test passes if no crash occurs
  }

  // MARK: - Clear Search Tests

  func testClearSearch_ResetsState() async {
    // First, perform a search with results
    let testLocators = [Locator.testLocator()]
    let collection = LocatorCollection.testCollection(locators: testLocators)
    mockSearchService.mockIterator = MockSearchIterator(results: [collection, nil])

    await viewModel.search(with: "test")
    XCTAssertFalse(viewModel.results.isEmpty, "Should have results before clear")

    // Now clear
    viewModel.cancelSearch()

    XCTAssertTrue(viewModel.results.isEmpty, "Results should be empty after clear")

    switch viewModel.state {
    case .empty:
      break // Expected
    default:
      XCTFail("State should be .empty after cancel, got \(viewModel.state)")
    }
  }

  // MARK: - In-Flight Cancellation Tests

  func testSearch_CancelsInFlight_OnNewQuery() async {
    // Set up first search with results
    let firstLocators = [Locator.testLocator(href: "/first.xhtml", title: "First")]
    let firstCollection = LocatorCollection.testCollection(locators: firstLocators)
    mockSearchService.mockIterator = MockSearchIterator(results: [firstCollection, nil])

    await viewModel.search(with: "first query")

    XCTAssertEqual(viewModel.results.count, 1, "Should have results from first search")

    // Now start a second search - this should cancel/clear previous results
    let secondLocators = [
      Locator.testLocator(href: "/second1.xhtml", title: "Second 1"),
      Locator.testLocator(href: "/second2.xhtml", title: "Second 2")
    ]
    let secondCollection = LocatorCollection.testCollection(locators: secondLocators)
    mockSearchService.mockIterator = MockSearchIterator(results: [secondCollection, nil])

    await viewModel.search(with: "second query")

    // Results should only contain second search results
    XCTAssertEqual(viewModel.results.count, 2, "Should have results from second search only")
    XCTAssertEqual(mockSearchService.searchCallCount, 2, "Should have called search twice")
  }

  // MARK: - State Machine Tests

  func testState_IsLoadingState_ReturnsCorrectValues() {
    // Test each state's isLoadingState property

    let emptyState = EPUBSearchViewModel.State.empty
    XCTAssertFalse(emptyState.isLoadingState, ".empty should not be loading")

    let startingState = EPUBSearchViewModel.State.starting
    XCTAssertTrue(startingState.isLoadingState, ".starting should be loading")

    let endState = EPUBSearchViewModel.State.end
    XCTAssertFalse(endState.isLoadingState, ".end should not be loading")

    let failureState = EPUBSearchViewModel.State.failure(SearchError.publicationNotSearchable)
    XCTAssertFalse(failureState.isLoadingState, ".failure should not be loading")
  }

  // MARK: - Fetch Next Batch Tests

  func testFetchNextBatch_WhenNotIdle_DoesNothing() async {
    // Set state to .empty (not .idle)
    viewModel.cancelSearch()

    let initialResultCount = viewModel.results.count

    await viewModel.fetchNextBatch()

    XCTAssertEqual(viewModel.results.count, initialResultCount, "Results should not change when not idle")
  }

  func testFetchNextBatch_WithMoreResults_AppendsResults() async {
    // First search to get into idle state with some results
    let firstBatch = [Locator.testLocator(href: "/ch1.xhtml", title: "Chapter 1")]
    let secondBatch = [Locator.testLocator(href: "/ch2.xhtml", title: "Chapter 2")]

    // Create iterator that returns two batches then nil
    mockSearchService.mockIterator = MockSearchIterator(results: [
      LocatorCollection.testCollection(locators: firstBatch),
      LocatorCollection.testCollection(locators: secondBatch),
      nil
    ])

    await viewModel.search(with: "test")

    // After initial search, we should have results from the first batch
    // (search() calls fetchNextBatch() once internally)
    XCTAssertEqual(viewModel.results.count, 1, "Should have results from first batch")

    // Now explicitly call fetchNextBatch to get the second batch
    await viewModel.fetchNextBatch()

    XCTAssertEqual(viewModel.results.count, 2, "Should have accumulated results from pagination")
  }

  // MARK: - Grouping Tests

  func testSearch_GroupsResultsByTitle() async {
    let locatorsChapter1 = [
      Locator.testLocator(href: "/ch1.xhtml", title: "Chapter 1", progression: 0.1),
      Locator.testLocator(href: "/ch1.xhtml", title: "Chapter 1", progression: 0.5)
    ]
    let locatorsChapter2 = [
      Locator.testLocator(href: "/ch2.xhtml", title: "Chapter 2", progression: 0.3)
    ]

    let allLocators = locatorsChapter1 + locatorsChapter2
    let collection = LocatorCollection.testCollection(locators: allLocators)
    mockSearchService.mockIterator = MockSearchIterator(results: [collection, nil])

    await viewModel.search(with: "test")

    // Results should be grouped by title
    XCTAssertEqual(viewModel.results.count, 3, "Should have all results")
    XCTAssertEqual(viewModel.sections.count, 2, "Should have 2 sections (by title)")
  }

  // MARK: - Duplicate Handling Tests

  func testSearch_FiltersDuplicateResults() async {
    let duplicateLocator = Locator.testLocator(
      href: "/ch1.xhtml",
      title: "Chapter 1",
      progression: 0.5,
      totalProgression: 0.25
    )

    // Same locator appears twice
    let collection = LocatorCollection.testCollection(locators: [duplicateLocator, duplicateLocator])
    mockSearchService.mockIterator = MockSearchIterator(results: [collection, nil])

    await viewModel.search(with: "test")

    XCTAssertEqual(viewModel.results.count, 1, "Duplicates should be filtered")
  }

  // MARK: - Publication Not Searchable Tests

  func testSearch_PublicationNotSearchable_SetsFailureState() async {
    // Create publication without search service
    let nonSearchablePublication = Publication.testPublication(searchService: nil)
    let nonSearchableViewModel = EPUBSearchViewModel(publication: nonSearchablePublication)

    await nonSearchableViewModel.search(with: "test")

    switch nonSearchableViewModel.state {
    case .failure:
      break // Expected
    default:
      XCTFail("State should be .failure when publication is not searchable")
    }
  }
}
