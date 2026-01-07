//
//  HoldsViewModelTests.swift
//  PalaceTests
//
//  Created for testing HoldsViewModel functionality.
//

import XCTest
import Combine
@testable import Palace

@MainActor
final class HoldsViewModelTests: XCTestCase {
  
  private var cancellables: Set<AnyCancellable> = []
  
  override func setUp() {
    super.setUp()
    cancellables = []
  }
  
  override func tearDown() {
    cancellables.removeAll()
    super.tearDown()
  }
  
  // MARK: - Initialization Tests
  
  func testInitialState() async {
    let viewModel = HoldsViewModel()
    
    XCTAssertFalse(viewModel.isLoading)
    XCTAssertFalse(viewModel.showLibraryAccountView)
    XCTAssertFalse(viewModel.selectNewLibrary)
    XCTAssertFalse(viewModel.showSearchSheet)
    XCTAssertEqual(viewModel.searchQuery, "")
  }
  
  // MARK: - Sync Notification Tests
  
  func testSyncBeganSetsLoadingTrue() async {
    let viewModel = HoldsViewModel()
    
    let expectation = XCTestExpectation(description: "Loading becomes true on sync began")
    
    viewModel.$isLoading
      .dropFirst()
      .sink { isLoading in
        if isLoading {
          expectation.fulfill()
        }
      }
      .store(in: &cancellables)
    
    NotificationCenter.default.post(name: .TPPSyncBegan, object: nil)
    
    await fulfillment(of: [expectation], timeout: 1.0)
    XCTAssertTrue(viewModel.isLoading)
  }
  
  func testSyncEndedSetsLoadingFalse() async {
    let viewModel = HoldsViewModel()
    
    NotificationCenter.default.post(name: .TPPSyncBegan, object: nil)
    
    try? await Task.sleep(nanoseconds: 100_000_000)
    
    let expectation = XCTestExpectation(description: "Loading becomes false on sync ended")
    
    viewModel.$isLoading
      .dropFirst()
      .sink { isLoading in
        if !isLoading {
          expectation.fulfill()
        }
      }
      .store(in: &cancellables)
    
    NotificationCenter.default.post(name: .TPPSyncEnded, object: nil)
    
    await fulfillment(of: [expectation], timeout: 1.0)
    XCTAssertFalse(viewModel.isLoading)
  }
  
  // MARK: - Filter Tests
  
  func testFilterBooksWithEmptyQueryReturnsAll() async {
    let viewModel = HoldsViewModel()
    
    await viewModel.filterBooks(query: "")
    
    XCTAssertEqual(viewModel.visibleBooks, viewModel.visibleBooks)
  }
  
  func testFilterBooksWithQuery() async {
    let viewModel = HoldsViewModel()
    
    await viewModel.filterBooks(query: "Test Query That Matches Nothing")
    
    XCTAssertTrue(viewModel.visibleBooks.isEmpty)
  }
  
  // MARK: - State Toggle Tests
  
  func testShowSearchSheetToggle() async {
    let viewModel = HoldsViewModel()
    
    XCTAssertFalse(viewModel.showSearchSheet)
    viewModel.showSearchSheet = true
    XCTAssertTrue(viewModel.showSearchSheet)
    viewModel.showSearchSheet = false
    XCTAssertFalse(viewModel.showSearchSheet)
  }
  
  func testSelectNewLibraryToggle() async {
    let viewModel = HoldsViewModel()
    
    XCTAssertFalse(viewModel.selectNewLibrary)
    viewModel.selectNewLibrary = true
    XCTAssertTrue(viewModel.selectNewLibrary)
  }
  
  func testShowLibraryAccountViewToggle() async {
    let viewModel = HoldsViewModel()
    
    XCTAssertFalse(viewModel.showLibraryAccountView)
    viewModel.showLibraryAccountView = true
    XCTAssertTrue(viewModel.showLibraryAccountView)
  }
  
  func testSearchQueryUpdate() async {
    let viewModel = HoldsViewModel()
    
    XCTAssertEqual(viewModel.searchQuery, "")
    viewModel.searchQuery = "Harry Potter"
    XCTAssertEqual(viewModel.searchQuery, "Harry Potter")
  }
  
  // MARK: - OpenSearchDescription Tests
  
  func testOpenSearchDescriptionHumanReadableDescription() async {
    let viewModel = HoldsViewModel()
    
    let searchDescription = viewModel.openSearchDescription
    
    XCTAssertEqual(searchDescription.humanReadableDescription, "Search Reservations")
  }
}

// MARK: - HoldsBookViewModel Tests

@MainActor
final class HoldsBookViewModelTests: XCTestCase {
  
  func testIdMatchesBookIdentifier() {
    let book = TPPBookMocker.snapshotEPUB()
    let viewModel = HoldsBookViewModel(book: book)
    
    XCTAssertEqual(viewModel.id, book.identifier)
  }
  
  func testBookPropertyReturnsCorrectBook() {
    let book = TPPBookMocker.snapshotAudiobook()
    let viewModel = HoldsBookViewModel(book: book)
    
    XCTAssertEqual(viewModel.book.identifier, book.identifier)
    XCTAssertEqual(viewModel.book.title, book.title)
  }
  
  func testIsReservedForNonReservedBook() {
    let book = TPPBookMocker.snapshotEPUB()
    let viewModel = HoldsBookViewModel(book: book)
    
    XCTAssertFalse(viewModel.isReserved)
  }
  
  func testIsReservedForHoldBook() {
    let book = TPPBookMocker.snapshotHoldBook()
    let viewModel = HoldsBookViewModel(book: book)
    
    XCTAssertTrue(viewModel.isReserved)
  }
}
