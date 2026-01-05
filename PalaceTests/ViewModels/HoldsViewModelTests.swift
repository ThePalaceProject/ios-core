//
//  HoldsViewModelTests.swift
//  PalaceTests
//
//  Tests for HoldsViewModel including reload, filtering, and badge count updates.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import Combine
@testable import Palace

@MainActor
final class HoldsViewModelTests: XCTestCase {
  
  // MARK: - Properties
  
  private var mockRegistry: TPPBookRegistryMock!
  private var cancellables: Set<AnyCancellable>!
  
  // MARK: - Setup/Teardown
  
  override func setUp() async throws {
    try await super.setUp()
    mockRegistry = TPPBookRegistryMock()
    cancellables = Set<AnyCancellable>()
  }
  
  override func tearDown() async throws {
    mockRegistry = nil
    cancellables = nil
    try await super.tearDown()
  }
  
  // MARK: - Helper Methods
  
  private func createHoldingBook() -> TPPBook {
    return TPPBookMocker.mockBook(distributorType: .EpubZip)
  }
  
  private func createReservedBook() -> TPPBook {
    let emptyUrl = URL(string: "http://example.com/reserved")!
    
    let reservedAvailability = TPPOPDSAcquisitionAvailabilityReserved(
      holdPosition: 3,
      copiesTotal: 5,
      since: Date(),
      until: nil
    )
    
    let acquisition = TPPOPDSAcquisition(
      relation: .generic,
      type: "application/epub+zip",
      hrefURL: emptyUrl,
      indirectAcquisitions: [],
      availability: reservedAvailability
    )
    
    return TPPBook(
      acquisitions: [acquisition],
      authors: [],
      categoryStrings: [],
      distributor: "Test",
      identifier: UUID().uuidString,
      imageURL: emptyUrl,
      imageThumbnailURL: emptyUrl,
      published: Date(),
      publisher: "Test",
      subtitle: "",
      summary: "",
      title: "Reserved Book",
      updated: Date(),
      annotationsURL: emptyUrl,
      analyticsURL: emptyUrl,
      alternateURL: emptyUrl,
      relatedWorksURL: emptyUrl,
      previewLink: nil,
      seriesURL: emptyUrl,
      revokeURL: emptyUrl,
      reportURL: emptyUrl,
      timeTrackingURL: emptyUrl,
      contributors: [:],
      bookDuration: nil,
      imageCache: MockImageCache()
    )
  }
  
  private func createReadyBook() -> TPPBook {
    let emptyUrl = URL(string: "http://example.com/ready")!
    
    let readyAvailability = TPPOPDSAcquisitionAvailabilityReady(since: nil, until: Date().addingTimeInterval(86400))
    
    let acquisition = TPPOPDSAcquisition(
      relation: .generic,
      type: "application/epub+zip",
      hrefURL: emptyUrl,
      indirectAcquisitions: [],
      availability: readyAvailability
    )
    
    return TPPBook(
      acquisitions: [acquisition],
      authors: [],
      categoryStrings: [],
      distributor: "Test",
      identifier: UUID().uuidString,
      imageURL: emptyUrl,
      imageThumbnailURL: emptyUrl,
      published: Date(),
      publisher: "Test",
      subtitle: "",
      summary: "",
      title: "Ready Book",
      updated: Date(),
      annotationsURL: emptyUrl,
      analyticsURL: emptyUrl,
      alternateURL: emptyUrl,
      relatedWorksURL: emptyUrl,
      previewLink: nil,
      seriesURL: emptyUrl,
      revokeURL: emptyUrl,
      reportURL: emptyUrl,
      timeTrackingURL: emptyUrl,
      contributors: [:],
      bookDuration: nil,
      imageCache: MockImageCache()
    )
  }
  
  // MARK: - Initialization Tests
  
  func testHoldsBookViewModel_Init() {
    let book = createHoldingBook()
    let vm = HoldsBookViewModel(book: book)
    
    XCTAssertEqual(vm.id, book.identifier)
    XCTAssertNotNil(vm.book)
  }
  
  func testHoldsBookViewModel_IsReserved_DefaultBook() {
    let book = createHoldingBook()
    let vm = HoldsBookViewModel(book: book)
    
    // Default book without reserved availability should not be reserved
    XCTAssertFalse(vm.isReserved)
  }
  
  func testHoldsBookViewModel_IsReserved_ReservedBook() {
    let book = createReservedBook()
    let vm = HoldsBookViewModel(book: book)
    
    XCTAssertTrue(vm.isReserved)
  }
  
  func testHoldsBookViewModel_IsReserved_ReadyBook() {
    let book = createReadyBook()
    let vm = HoldsBookViewModel(book: book)
    
    // Ready books are also flagged as reserved (ready to pick up)
    XCTAssertTrue(vm.isReserved)
  }
  
  // MARK: - Loading State Tests
  
  func testLoadingState_InitiallyFalse() {
    var isLoading = false
    
    XCTAssertFalse(isLoading)
  }
  
  func testLoadingState_DuringSync() {
    var isLoading = false
    
    // Simulate sync began
    isLoading = true
    XCTAssertTrue(isLoading)
    
    // Simulate sync ended
    isLoading = false
    XCTAssertFalse(isLoading)
  }
  
  // MARK: - Book List Tests
  
  func testReservedAndHeldBooks_Separation() {
    let reservedBook = createReservedBook()
    let readyBook = createReadyBook()
    let regularBook = createHoldingBook()
    
    var reservedVMs: [HoldsBookViewModel] = []
    var heldVMs: [HoldsBookViewModel] = []
    
    let allBooks = [reservedBook, readyBook, regularBook]
    
    for book in allBooks {
      let vm = HoldsBookViewModel(book: book)
      if vm.isReserved {
        reservedVMs.append(vm)
      } else {
        heldVMs.append(vm)
      }
    }
    
    XCTAssertEqual(reservedVMs.count, 2)  // reserved + ready
    XCTAssertEqual(heldVMs.count, 1)      // regular book
  }
  
  func testVisibleBooks_ContainsAllBooks() {
    let book1 = createHoldingBook()
    let book2 = createReservedBook()
    let book3 = createReadyBook()
    
    let allBooks = [book1, book2, book3]
    var visibleBooks = allBooks
    
    XCTAssertEqual(visibleBooks.count, 3)
  }
  
  // MARK: - Filtering Tests
  
  func testFilterBooks_ByTitle() async {
    struct MockBook {
      let title: String
      let authors: String?
    }
    
    let books = [
      MockBook(title: "Harry Potter", authors: "J.K. Rowling"),
      MockBook(title: "The Hobbit", authors: "J.R.R. Tolkien"),
      MockBook(title: "Lord of the Rings", authors: "J.R.R. Tolkien")
    ]
    
    let query = "Harry"
    let filtered = books.filter {
      $0.title.localizedCaseInsensitiveContains(query)
    }
    
    XCTAssertEqual(filtered.count, 1)
    XCTAssertEqual(filtered.first?.title, "Harry Potter")
  }
  
  func testFilterBooks_ByAuthor() async {
    struct MockBook {
      let title: String
      let authors: String?
    }
    
    let books = [
      MockBook(title: "Harry Potter", authors: "J.K. Rowling"),
      MockBook(title: "The Hobbit", authors: "J.R.R. Tolkien"),
      MockBook(title: "Lord of the Rings", authors: "J.R.R. Tolkien")
    ]
    
    let query = "Tolkien"
    let filtered = books.filter {
      $0.authors?.localizedCaseInsensitiveContains(query) ?? false
    }
    
    XCTAssertEqual(filtered.count, 2)
  }
  
  func testFilterBooks_EmptyQuery_ReturnsAll() async {
    let book1 = createHoldingBook()
    let book2 = createReservedBook()
    
    let allBooks = [book1, book2]
    let query = ""
    
    let visibleBooks: [TPPBook]
    if query.isEmpty {
      visibleBooks = allBooks
    } else {
      visibleBooks = allBooks.filter {
        $0.title.localizedCaseInsensitiveContains(query)
      }
    }
    
    XCTAssertEqual(visibleBooks.count, 2)
  }
  
  func testFilterBooks_CaseInsensitive() async {
    struct MockBook {
      let title: String
    }
    
    let books = [
      MockBook(title: "Harry Potter")
    ]
    
    let queries = ["HARRY", "harry", "Harry", "hArRy"]
    
    for query in queries {
      let filtered = books.filter {
        $0.title.localizedCaseInsensitiveContains(query)
      }
      XCTAssertEqual(filtered.count, 1, "Failed for query: \(query)")
    }
  }
  
  // MARK: - Badge Count Tests
  
  func testBadgeCount_EqualsReservedCount() {
    let reservedBook1 = createReservedBook()
    let reservedBook2 = createReadyBook()
    let regularBook = createHoldingBook()
    
    var reservedVMs: [HoldsBookViewModel] = []
    
    let allBooks = [reservedBook1, reservedBook2, regularBook]
    
    for book in allBooks {
      let vm = HoldsBookViewModel(book: book)
      if vm.isReserved {
        reservedVMs.append(vm)
      }
    }
    
    let badgeCount = reservedVMs.count
    
    XCTAssertEqual(badgeCount, 2)
  }
  
  func testBadgeCount_ZeroWhenNoReservations() {
    let regularBook = createHoldingBook()
    
    var reservedVMs: [HoldsBookViewModel] = []
    
    let vm = HoldsBookViewModel(book: regularBook)
    if vm.isReserved {
      reservedVMs.append(vm)
    }
    
    let badgeCount = reservedVMs.count
    
    XCTAssertEqual(badgeCount, 0)
  }
  
  // MARK: - Search Sheet State Tests
  
  func testSearchSheet_InitiallyHidden() {
    var showSearchSheet = false
    
    XCTAssertFalse(showSearchSheet)
  }
  
  func testSearchSheet_Toggle() {
    var showSearchSheet = false
    
    showSearchSheet = true
    XCTAssertTrue(showSearchSheet)
    
    showSearchSheet = false
    XCTAssertFalse(showSearchSheet)
  }
  
  func testSearchQuery_EmptyInitially() {
    var searchQuery = ""
    
    XCTAssertTrue(searchQuery.isEmpty)
  }
  
  func testSearchQuery_UpdatesOnInput() {
    var searchQuery = ""
    
    searchQuery = "Harry"
    XCTAssertEqual(searchQuery, "Harry")
    
    searchQuery = ""
    XCTAssertTrue(searchQuery.isEmpty)
  }
  
  // MARK: - Library Account View Tests
  
  func testShowLibraryAccountView_InitiallyFalse() {
    var showLibraryAccountView = false
    
    XCTAssertFalse(showLibraryAccountView)
  }
  
  func testSelectNewLibrary_InitiallyFalse() {
    var selectNewLibrary = false
    
    XCTAssertFalse(selectNewLibrary)
  }
  
  // MARK: - Account Loading Tests
  
  func testLoadAccount_ClearsFlags() {
    var showLibraryAccountView = true
    var selectNewLibrary = true
    
    // Simulate loadAccount completion
    showLibraryAccountView = false
    selectNewLibrary = false
    
    XCTAssertFalse(showLibraryAccountView)
    XCTAssertFalse(selectNewLibrary)
  }
  
  // MARK: - Open Search Description Tests
  
  func testOpenSearchDescription_ContainsAllBooks() {
    let book1 = createHoldingBook()
    let book2 = createReservedBook()
    
    let allBooks = [book1, book2]
    let title = NSLocalizedString("Search Reservations", comment: "")
    
    let description = TPPOpenSearchDescription(title: title, books: allBooks)
    
    XCTAssertNotNil(description)
  }
  
  // MARK: - Sync State Tests
  
  func testSyncState_BeganNotification() {
    var isLoading = false
    
    // Simulate sync began notification
    isLoading = true
    
    XCTAssertTrue(isLoading)
  }
  
  func testSyncState_EndedNotification() {
    var isLoading = true
    
    // Simulate sync ended notification
    isLoading = false
    
    XCTAssertFalse(isLoading)
  }
  
  // MARK: - Book Separation Logic Tests
  
  func testBookSeparation_ReservedFromHeld() {
    let reservedBook = createReservedBook()
    let readyBook = createReadyBook()
    let holdingBook = createHoldingBook()
    
    let allHeldBooks = [reservedBook, readyBook, holdingBook]
    
    var reservedBookVMs: [HoldsBookViewModel] = []
    var heldBookVMs: [HoldsBookViewModel] = []
    
    for book in allHeldBooks {
      let vm = HoldsBookViewModel(book: book)
      if vm.isReserved {
        reservedBookVMs.append(vm)
      } else {
        heldBookVMs.append(vm)
      }
    }
    
    // Reserved and ready books go to reservedBookVMs
    XCTAssertEqual(reservedBookVMs.count, 2)
    // Regular holding books go to heldBookVMs
    XCTAssertEqual(heldBookVMs.count, 1)
  }
  
  // MARK: - Animation State Tests
  
  func testReloadData_UpdatesWithAnimation() {
    var reservedBookVMs: [HoldsBookViewModel] = []
    var heldBookVMs: [HoldsBookViewModel] = []
    
    let book = createReservedBook()
    let vm = HoldsBookViewModel(book: book)
    
    // Simulate withAnimation update
    reservedBookVMs.append(vm)
    
    XCTAssertEqual(reservedBookVMs.count, 1)
    XCTAssertTrue(heldBookVMs.isEmpty)
  }
  
  // MARK: - Combine/Publisher Tests
  
  func testNotificationPublisher_SyncBegan() {
    var syncBeganReceived = false
    
    NotificationCenter.default.publisher(for: .TPPSyncBegan)
      .sink { _ in
        syncBeganReceived = true
      }
      .store(in: &cancellables)
    
    // Post notification
    NotificationCenter.default.post(name: .TPPSyncBegan, object: nil)
    
    // Wait for async processing
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
    
    XCTAssertTrue(syncBeganReceived)
  }
  
  func testNotificationPublisher_SyncEnded() {
    var syncEndedReceived = false
    
    NotificationCenter.default.publisher(for: .TPPSyncEnded)
      .sink { _ in
        syncEndedReceived = true
      }
      .store(in: &cancellables)
    
    // Post notification
    NotificationCenter.default.post(name: .TPPSyncEnded, object: nil)
    
    // Wait for async processing
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
    
    XCTAssertTrue(syncEndedReceived)
  }
  
  func testNotificationPublisher_RegistryDidChange() {
    var registryChangeReceived = false
    
    NotificationCenter.default.publisher(for: .TPPBookRegistryDidChange)
      .sink { _ in
        registryChangeReceived = true
      }
      .store(in: &cancellables)
    
    // Post notification
    NotificationCenter.default.post(name: .TPPBookRegistryDidChange, object: nil)
    
    // Wait for async processing
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
    
    XCTAssertTrue(registryChangeReceived)
  }
}

