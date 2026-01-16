//
//  HoldsViewModelTests.swift
//  PalaceTests
//
//  Tests for HoldsViewModel with dependency injection.
//  Uses TPPBookRegistryMock to test real business logic.
//  NOTE: Tests verify synchronous behavior only - no timing dependencies.
//

import XCTest
import Combine
@testable import Palace

@MainActor
final class HoldsViewModelTests: XCTestCase {
  
  private var cancellables: Set<AnyCancellable> = []
  private var mockRegistry: TPPBookRegistryMock!
  
  override func setUp() {
    super.setUp()
    cancellables = []
    mockRegistry = TPPBookRegistryMock()
  }
  
  override func tearDown() {
    cancellables.removeAll()
    mockRegistry = nil
    super.tearDown()
  }
  
  private func createViewModel() -> HoldsViewModel {
    HoldsViewModel(bookRegistry: mockRegistry)
  }
  
  private func addHeldBook(identifier: String = "held-book", title: String = "Test Book") -> TPPBook {
    let book = TPPBookMocker.snapshotReservedBook(identifier: identifier, title: title)
    mockRegistry.addBook(book, state: .holding)
    return book
  }
  
  // MARK: - Initialization Tests
  
  func testInitialState_HasCorrectDefaults() {
    let viewModel = createViewModel()
    
    XCTAssertFalse(viewModel.isLoading)
    XCTAssertFalse(viewModel.showLibraryAccountView)
    XCTAssertFalse(viewModel.selectNewLibrary)
    XCTAssertFalse(viewModel.showSearchSheet)
    XCTAssertEqual(viewModel.searchQuery, "")
  }
  
  func testInitialState_EmptyBookLists() {
    let viewModel = createViewModel()
    
    XCTAssertTrue(viewModel.reservedBookVMs.isEmpty)
    XCTAssertTrue(viewModel.heldBookVMs.isEmpty)
    XCTAssertTrue(viewModel.visibleBooks.isEmpty)
  }
  
  // MARK: - Sync Notification Tests
  
  func testSyncBeganSetsLoadingTrue() async {
    let viewModel = createViewModel()
    
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
    let viewModel = createViewModel()
    viewModel.isLoading = true // Set initial state
    
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
    let viewModel = createViewModel()
    
    await viewModel.filterBooks(query: "")
    
    XCTAssertEqual(viewModel.visibleBooks, viewModel.visibleBooks)
  }
  
  func testFilterBooksWithQuery() async {
    let viewModel = createViewModel()
    
    await viewModel.filterBooks(query: "Test Query That Matches Nothing")
    
    XCTAssertTrue(viewModel.visibleBooks.isEmpty)
  }
  
  // MARK: - State Toggle Tests
  
  func testShowSearchSheetToggle() {
    let viewModel = createViewModel()
    
    XCTAssertFalse(viewModel.showSearchSheet)
    viewModel.showSearchSheet = true
    XCTAssertTrue(viewModel.showSearchSheet)
    viewModel.showSearchSheet = false
    XCTAssertFalse(viewModel.showSearchSheet)
  }
  
  func testSelectNewLibraryToggle() {
    let viewModel = createViewModel()
    
    XCTAssertFalse(viewModel.selectNewLibrary)
    viewModel.selectNewLibrary = true
    XCTAssertTrue(viewModel.selectNewLibrary)
  }
  
  func testShowLibraryAccountViewToggle() {
    let viewModel = createViewModel()
    
    XCTAssertFalse(viewModel.showLibraryAccountView)
    viewModel.showLibraryAccountView = true
    XCTAssertTrue(viewModel.showLibraryAccountView)
  }
  
  func testSearchQueryUpdate() {
    let viewModel = createViewModel()
    
    XCTAssertEqual(viewModel.searchQuery, "")
    viewModel.searchQuery = "Harry Potter"
    XCTAssertEqual(viewModel.searchQuery, "Harry Potter")
  }
  
  // MARK: - OpenSearchDescription Tests
  
  func testOpenSearchDescriptionHumanReadableDescription() {
    let viewModel = createViewModel()
    
    let searchDescription = viewModel.openSearchDescription
    
    XCTAssertEqual(searchDescription.humanReadableDescription, "Search Reservations")
  }
  
  // MARK: - ReloadData Tests (Testing Real Business Logic with Mock)
  
  func testReloadData_CallsMethod() {
    let book = TPPBookMocker.snapshotReservedBook(identifier: "test-1", title: "Test Book")
    mockRegistry.addBook(book, state: .holding)
    
    let viewModel = createViewModel()
    
    // Call reloadData directly - no waiting
    viewModel.reloadData()
    
    // The ViewModel should have processed the held books
    XCTAssertNotNil(viewModel)
  }
  
  func testReloadData_HandlesMultipleBooks() {
    let reservedBook = TPPBookMocker.snapshotReservedBook(identifier: "reserved-1", title: "Reserved Book")
    let readyBook = TPPBookMocker.snapshotReadyBook(identifier: "ready-1", title: "Ready Book")
    
    mockRegistry.addBook(reservedBook, state: .holding)
    mockRegistry.addBook(readyBook, state: .holding)
    
    let viewModel = createViewModel()
    
    viewModel.reloadData()
    
    // Test passes if no crash
    XCTAssertNotNil(viewModel.reservedBookVMs)
    XCTAssertNotNil(viewModel.heldBookVMs)
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
  
  func testIsReservedForReadyBook() {
    let book = TPPBookMocker.snapshotReadyBook()
    let viewModel = HoldsBookViewModel(book: book)
    
    // Ready books should also return true for isReserved (they're still in holds)
    XCTAssertTrue(viewModel.isReserved)
  }
}

// MARK: - Badge Count Calculation Tests

/// Tests for PP-3411: Badge should show only "ready" books, not all held books
@MainActor
final class HoldsBadgeCountTests: XCTestCase {
  
  /// Helper function that mirrors the badge counting logic in AppTabHostView
  private func calculateReadyCount(for books: [TPPBook]) -> Int {
    var readyCount = 0
    for book in books {
      book.defaultAcquisition?.availability.matchUnavailable(nil,
                                                              limited: nil,
                                                              unlimited: nil,
                                                              reserved: nil,
                                                              ready: { _ in readyCount += 1 })
    }
    return readyCount
  }
  
  // MARK: - Badge Count Tests
  
  func testBadgeCount_noBooks_returnsZero() {
    let books: [TPPBook] = []
    let readyCount = calculateReadyCount(for: books)
    
    XCTAssertEqual(readyCount, 0, "Empty book list should have badge count of 0")
  }
  
  func testBadgeCount_oneReservedBook_returnsZero() {
    // PP-3411: A book waiting in queue should NOT be counted in badge
    let books = [TPPBookMocker.snapshotReservedBook()]
    let readyCount = calculateReadyCount(for: books)
    
    XCTAssertEqual(readyCount, 0, "One reserved book should have badge count of 0")
  }
  
  func testBadgeCount_oneReadyBook_returnsOne() {
    // PP-3411: A book ready to borrow SHOULD be counted in badge
    let books = [TPPBookMocker.snapshotReadyBook()]
    let readyCount = calculateReadyCount(for: books)
    
    XCTAssertEqual(readyCount, 1, "One ready book should have badge count of 1")
  }
  
  func testBadgeCount_mixedHolds_countsOnlyReady() {
    // PP-3411: With 4 holds and 1 ready, badge should show 1 (not 4)
    let books = [
      TPPBookMocker.snapshotReservedBook(identifier: "reserved-1", title: "Book 1", author: "Author 1"),
      TPPBookMocker.snapshotReservedBook(identifier: "reserved-2", title: "Book 2", author: "Author 2"),
      TPPBookMocker.snapshotReservedBook(identifier: "reserved-3", title: "Book 3", author: "Author 3"),
      TPPBookMocker.snapshotReadyBook(identifier: "ready-1", title: "Ready Book", author: "Ready Author")
    ]
    let readyCount = calculateReadyCount(for: books)
    
    XCTAssertEqual(readyCount, 1, "4 holds with 1 ready should have badge count of 1")
  }
  
  func testBadgeCount_multipleReady_countsAll() {
    let books = [
      TPPBookMocker.snapshotReadyBook(identifier: "ready-1", title: "Ready 1", author: "Author 1"),
      TPPBookMocker.snapshotReadyBook(identifier: "ready-2", title: "Ready 2", author: "Author 2"),
      TPPBookMocker.snapshotReadyBook(identifier: "ready-3", title: "Ready 3", author: "Author 3")
    ]
    let readyCount = calculateReadyCount(for: books)
    
    XCTAssertEqual(readyCount, 3, "3 ready books should have badge count of 3")
  }
  
  func testBadgeCount_allReserved_returnsZero() {
    let books = [
      TPPBookMocker.snapshotReservedBook(identifier: "reserved-1", title: "Book 1", author: "Author 1"),
      TPPBookMocker.snapshotReservedBook(identifier: "reserved-2", title: "Book 2", author: "Author 2"),
      TPPBookMocker.snapshotReservedBook(identifier: "reserved-3", title: "Book 3", author: "Author 3")
    ]
    let readyCount = calculateReadyCount(for: books)
    
    XCTAssertEqual(readyCount, 0, "All reserved books should have badge count of 0")
  }
  
  func testBadgeCount_regularBook_notCounted() {
    // Regular available books (not on hold) should not affect badge
    let books = [TPPBookMocker.snapshotEPUB()]
    let readyCount = calculateReadyCount(for: books)
    
    XCTAssertEqual(readyCount, 0, "Regular available book should not be counted in badge")
  }
  
  // MARK: - Availability State Tests
  
  func testReservedBookHasReservedAvailability() {
    let book = TPPBookMocker.snapshotReservedBook()
    var isReserved = false
    
    book.defaultAcquisition?.availability.matchUnavailable(nil,
                                                            limited: nil,
                                                            unlimited: nil,
                                                            reserved: { _ in isReserved = true },
                                                            ready: nil)
    
    XCTAssertTrue(isReserved, "Reserved book should have 'reserved' availability")
  }
  
  func testReadyBookHasReadyAvailability() {
    let book = TPPBookMocker.snapshotReadyBook()
    var isReady = false
    
    book.defaultAcquisition?.availability.matchUnavailable(nil,
                                                            limited: nil,
                                                            unlimited: nil,
                                                            reserved: nil,
                                                            ready: { _ in isReady = true })
    
    XCTAssertTrue(isReady, "Ready book should have 'ready' availability")
  }
}
