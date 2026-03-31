//
//  SearchResultsViewModelTests.swift
//  PalaceTests
//
//  Tests for SearchResultsViewModel filtering, sorting, and state management.
//
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import XCTest
import Combine
@testable import Palace

@MainActor
final class SearchResultsViewModelTests: XCTestCase {

  private var viewModel: SearchResultsViewModel!
  private var cancellables: Set<AnyCancellable>!

  override func setUp() {
    super.setUp()
    viewModel = SearchResultsViewModel()
    cancellables = Set<AnyCancellable>()
  }

  override func tearDown() {
    viewModel = nil
    cancellables = nil
    super.tearDown()
  }

  // MARK: - Test Helpers

  private func makeResult(
    id: String = UUID().uuidString,
    title: String = "Test Book",
    authors: [String] = ["Author"],
    availability: AvailabilityStatus = .availableNow,
    format: BookFormat = .epub,
    published: Date? = nil,
    libraryId: String = "lib-1"
  ) -> CrossLibrarySearchResponse.MergedSearchResult {
    let libraryResult = LibrarySearchResult(
      libraryId: libraryId,
      libraryName: "Library \(libraryId)",
      bookIdentifier: id,
      title: title,
      authors: authors,
      summary: nil,
      categories: [],
      coverImageURL: nil,
      thumbnailURL: nil,
      availability: availability,
      copiesAvailable: availability == .availableNow ? 1 : 0,
      copiesTotal: 1,
      holdPosition: nil,
      published: published,
      publisher: nil,
      borrowURL: nil,
      format: format,
      book: nil
    )
    return CrossLibrarySearchResponse.MergedSearchResult(
      id: id,
      title: title,
      authors: authors,
      summary: nil,
      categories: [],
      coverImageURL: nil,
      thumbnailURL: nil,
      published: published,
      publisher: nil,
      format: format,
      libraryResults: [libraryResult]
    )
  }

  private func makeLibrary(id: String, name: String, succeeded: Bool = true, resultCount: Int = 1) -> CrossLibrarySearchResponse.SearchedLibrary {
    CrossLibrarySearchResponse.SearchedLibrary(
      id: id,
      name: name,
      succeeded: succeeded,
      resultCount: resultCount
    )
  }

  // MARK: - Initial State

  func testInitialState_HasEmptyResults() {
    XCTAssertTrue(viewModel.displayResults.isEmpty)
  }

  func testInitialState_HasDefaultSort() {
    XCTAssertEqual(viewModel.sortOption, .relevance)
  }

  func testInitialState_HasDefaultFilters() {
    XCTAssertEqual(viewModel.availabilityFilter, .all)
    XCTAssertNil(viewModel.libraryFilter)
    XCTAssertNil(viewModel.formatFilter)
  }

  // MARK: - updateResults

  func testUpdateResults_PopulatesDisplayResults() {
    let results = [
      makeResult(id: "1", title: "Book A"),
      makeResult(id: "2", title: "Book B"),
    ]
    let libraries = [makeLibrary(id: "lib-1", name: "Library One")]

    viewModel.updateResults(results, libraries: libraries)

    XCTAssertEqual(viewModel.displayResults.count, 2)
    XCTAssertEqual(viewModel.displayResults[0].title, "Book A")
    XCTAssertEqual(viewModel.displayResults[1].title, "Book B")
  }

  // MARK: - Sort Options

  func testSortByTitle_OrdersAlphabetically() {
    let results = [
      makeResult(id: "1", title: "Zebra"),
      makeResult(id: "2", title: "Apple"),
      makeResult(id: "3", title: "Mango"),
    ]
    viewModel.updateResults(results, libraries: [])
    viewModel.sortOption = .title

    // applyFiltersAndSort is called synchronously via updateResults + property change
    // Give the debounce a moment
    let expectation = XCTestExpectation(description: "Sort applied")
    viewModel.$displayResults
      .dropFirst()
      .first()
      .sink { results in
        XCTAssertEqual(results.map(\.title), ["Apple", "Mango", "Zebra"])
        expectation.fulfill()
      }
      .store(in: &cancellables)

    wait(for: [expectation], timeout: 1.0)
  }

  func testSortByAvailability_OrdersByStatus() {
    let results = [
      makeResult(id: "1", title: "Unavailable", availability: .unavailable),
      makeResult(id: "2", title: "Available", availability: .availableNow),
      makeResult(id: "3", title: "Short Wait", availability: .shortWait),
    ]
    viewModel.updateResults(results, libraries: [])
    viewModel.sortOption = .availability

    let expectation = XCTestExpectation(description: "Sort applied")
    viewModel.$displayResults
      .dropFirst()
      .first()
      .sink { results in
        XCTAssertEqual(results.map(\.title), ["Available", "Short Wait", "Unavailable"])
        expectation.fulfill()
      }
      .store(in: &cancellables)

    wait(for: [expectation], timeout: 1.0)
  }

  func testSortByDate_OrdersNewestFirst() {
    let now = Date()
    let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
    let lastWeek = Calendar.current.date(byAdding: .day, value: -7, to: now)!

    let results = [
      makeResult(id: "1", title: "Old", published: lastWeek),
      makeResult(id: "2", title: "New", published: now),
      makeResult(id: "3", title: "Yesterday", published: yesterday),
    ]
    viewModel.updateResults(results, libraries: [])
    viewModel.sortOption = .date

    let expectation = XCTestExpectation(description: "Sort applied")
    viewModel.$displayResults
      .dropFirst()
      .first()
      .sink { results in
        XCTAssertEqual(results.map(\.title), ["New", "Yesterday", "Old"])
        expectation.fulfill()
      }
      .store(in: &cancellables)

    wait(for: [expectation], timeout: 1.0)
  }

  func testSortByRelevance_KeepsOriginalOrder() {
    let results = [
      makeResult(id: "1", title: "First"),
      makeResult(id: "2", title: "Second"),
      makeResult(id: "3", title: "Third"),
    ]
    viewModel.updateResults(results, libraries: [])

    // Relevance is the default, order should match input
    XCTAssertEqual(viewModel.displayResults.map(\.title), ["First", "Second", "Third"])
  }

  // MARK: - Availability Filter

  func testFilterByAvailableNow_ShowsOnlyAvailable() {
    let results = [
      makeResult(id: "1", title: "Available", availability: .availableNow),
      makeResult(id: "2", title: "Waiting", availability: .longWait),
      makeResult(id: "3", title: "Short", availability: .shortWait),
    ]
    viewModel.updateResults(results, libraries: [])
    viewModel.availabilityFilter = .availableNow

    let expectation = XCTestExpectation(description: "Filter applied")
    viewModel.$displayResults
      .dropFirst()
      .first()
      .sink { results in
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.title, "Available")
        expectation.fulfill()
      }
      .store(in: &cancellables)

    wait(for: [expectation], timeout: 1.0)
  }

  func testFilterByShortWait_ShowsAvailableAndShortWait() {
    let results = [
      makeResult(id: "1", title: "Available", availability: .availableNow),
      makeResult(id: "2", title: "Long", availability: .longWait),
      makeResult(id: "3", title: "Short", availability: .shortWait),
    ]
    viewModel.updateResults(results, libraries: [])
    viewModel.availabilityFilter = .shortWait

    let expectation = XCTestExpectation(description: "Filter applied")
    viewModel.$displayResults
      .dropFirst()
      .first()
      .sink { results in
        XCTAssertEqual(results.count, 2)
        let titles = Set(results.map(\.title))
        XCTAssertTrue(titles.contains("Available"))
        XCTAssertTrue(titles.contains("Short"))
        expectation.fulfill()
      }
      .store(in: &cancellables)

    wait(for: [expectation], timeout: 1.0)
  }

  // MARK: - Library Filter

  func testFilterByLibrary_ShowsOnlyMatchingLibrary() {
    let result1 = makeResult(id: "1", title: "Lib1 Book", libraryId: "lib-1")
    let result2 = makeResult(id: "2", title: "Lib2 Book", libraryId: "lib-2")
    viewModel.updateResults([result1, result2], libraries: [])
    viewModel.libraryFilter = "lib-1"

    let expectation = XCTestExpectation(description: "Filter applied")
    viewModel.$displayResults
      .dropFirst()
      .first()
      .sink { results in
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.title, "Lib1 Book")
        expectation.fulfill()
      }
      .store(in: &cancellables)

    wait(for: [expectation], timeout: 1.0)
  }

  // MARK: - Format Filter

  func testFilterByFormat_ShowsOnlyMatchingFormat() {
    let results = [
      makeResult(id: "1", title: "EPUB Book", format: .epub),
      makeResult(id: "2", title: "PDF Book", format: .pdf),
      makeResult(id: "3", title: "Audio Book", format: .audiobook),
    ]
    viewModel.updateResults(results, libraries: [])
    viewModel.formatFilter = .audiobook

    let expectation = XCTestExpectation(description: "Filter applied")
    viewModel.$displayResults
      .dropFirst()
      .first()
      .sink { results in
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.title, "Audio Book")
        expectation.fulfill()
      }
      .store(in: &cancellables)

    wait(for: [expectation], timeout: 1.0)
  }

  // MARK: - Combined Filters

  func testMultipleFilters_ApplyTogether() {
    let results = [
      makeResult(id: "1", title: "Good", availability: .availableNow, format: .epub, libraryId: "lib-1"),
      makeResult(id: "2", title: "Wrong Format", availability: .availableNow, format: .pdf, libraryId: "lib-1"),
      makeResult(id: "3", title: "Wrong Library", availability: .availableNow, format: .epub, libraryId: "lib-2"),
      makeResult(id: "4", title: "Wrong Availability", availability: .longWait, format: .epub, libraryId: "lib-1"),
    ]
    viewModel.updateResults(results, libraries: [])
    viewModel.availabilityFilter = .availableNow
    viewModel.formatFilter = .epub
    viewModel.libraryFilter = "lib-1"

    let expectation = XCTestExpectation(description: "Filters applied")
    viewModel.$displayResults
      .dropFirst()
      .first()
      .sink { results in
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.title, "Good")
        expectation.fulfill()
      }
      .store(in: &cancellables)

    wait(for: [expectation], timeout: 1.0)
  }

  // MARK: - clearFilters

  func testClearFilters_ResetsAllFilters() {
    viewModel.sortOption = .title
    viewModel.availabilityFilter = .availableNow
    viewModel.libraryFilter = "lib-1"
    viewModel.formatFilter = .epub

    viewModel.clearFilters()

    XCTAssertEqual(viewModel.sortOption, .relevance)
    XCTAssertEqual(viewModel.availabilityFilter, .all)
    XCTAssertNil(viewModel.libraryFilter)
    XCTAssertNil(viewModel.formatFilter)
  }

  // MARK: - availableLibraries

  func testAvailableLibraries_ReturnsOnlySucceeded() {
    let libraries = [
      makeLibrary(id: "1", name: "Success", succeeded: true),
      makeLibrary(id: "2", name: "Failed", succeeded: false),
      makeLibrary(id: "3", name: "Also Success", succeeded: true),
    ]
    viewModel.updateResults([], libraries: libraries)

    let available = viewModel.availableLibraries
    XCTAssertEqual(available.count, 2)
    XCTAssertTrue(available.allSatisfy(\.succeeded))
  }

  // MARK: - Empty Results After Filtering

  func testFilterReturnsEmpty_WhenNothingMatches() {
    let results = [
      makeResult(id: "1", title: "Only Book", availability: .longWait, format: .pdf),
    ]
    viewModel.updateResults(results, libraries: [])
    viewModel.availabilityFilter = .availableNow

    let expectation = XCTestExpectation(description: "Filter applied")
    viewModel.$displayResults
      .dropFirst()
      .first()
      .sink { results in
        XCTAssertTrue(results.isEmpty)
        expectation.fulfill()
      }
      .store(in: &cancellables)

    wait(for: [expectation], timeout: 1.0)
  }
}
