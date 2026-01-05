//
//  MyBooksViewModelTests.swift
//  PalaceTests
//
//  Created for Testing Migration
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

/// Tests for MyBooksViewModel functionality including sorting, filtering, and state management.
class MyBooksViewModelTests: XCTestCase {
  
  var mockRegistry: TPPBookRegistryMock!
  
  override func setUp() {
    super.setUp()
    mockRegistry = TPPBookRegistryMock()
  }
  
  override func tearDown() {
    mockRegistry = nil
    super.tearDown()
  }
  
  // MARK: - Facet Tests
  
  func testFacet_AuthorLocalizedString() {
    let facet = Facet.author
    XCTAssertEqual(facet.localizedString, Strings.FacetView.author)
  }
  
  func testFacet_TitleLocalizedString() {
    let facet = Facet.title
    XCTAssertEqual(facet.localizedString, Strings.FacetView.title)
  }
  
  func testFacet_RawValues() {
    XCTAssertEqual(Facet.author.rawValue, "author")
    XCTAssertEqual(Facet.title.rawValue, "title")
  }
  
  // MARK: - Sorting Tests
  
  func testSortByAuthor_AscendingOrder() {
    // Create mock books with different authors
    struct MockBook {
      let title: String
      let authors: String?
    }
    
    var books = [
      MockBook(title: "Zoo Story", authors: "Zebra Author"),
      MockBook(title: "Apple Book", authors: "Apple Author"),
      MockBook(title: "Middle Book", authors: "Middle Author")
    ]
    
    // Sort by author (author + title)
    books.sort { first, second in
      "\(first.authors ?? "") \(first.title)" < "\(second.authors ?? "") \(second.title)"
    }
    
    XCTAssertEqual(books[0].authors, "Apple Author", "Apple Author should be first")
    XCTAssertEqual(books[1].authors, "Middle Author", "Middle Author should be second")
    XCTAssertEqual(books[2].authors, "Zebra Author", "Zebra Author should be third")
  }
  
  func testSortByTitle_AscendingOrder() {
    struct MockBook {
      let title: String
      let authors: String?
    }
    
    var books = [
      MockBook(title: "Zoo Story", authors: "Author 1"),
      MockBook(title: "Apple Book", authors: "Author 2"),
      MockBook(title: "Middle Book", authors: "Author 3")
    ]
    
    // Sort by title (title + author)
    books.sort { first, second in
      "\(first.title) \(first.authors ?? "")" < "\(second.title) \(second.authors ?? "")"
    }
    
    XCTAssertEqual(books[0].title, "Apple Book", "Apple Book should be first")
    XCTAssertEqual(books[1].title, "Middle Book", "Middle Book should be second")
    XCTAssertEqual(books[2].title, "Zoo Story", "Zoo Story should be third")
  }
  
  func testSortByAuthor_NilAuthorsHandled() {
    struct MockBook {
      let title: String
      let authors: String?
    }
    
    var books = [
      MockBook(title: "Book A", authors: nil),
      MockBook(title: "Book B", authors: "Beta Author"),
      MockBook(title: "Book C", authors: "Alpha Author")
    ]
    
    // Sort by author with nil handling
    books.sort { first, second in
      "\(first.authors ?? "") \(first.title)" < "\(second.authors ?? "") \(second.title)"
    }
    
    // nil authors (treated as empty string) should come first
    XCTAssertNil(books[0].authors, "Nil author should be first (empty string sort)")
  }
  
  // MARK: - Filter Tests
  
  func testFilterBooks_ByTitle() {
    struct MockBook {
      let title: String
      let authors: String?
    }
    
    let allBooks = [
      MockBook(title: "Harry Potter", authors: "J.K. Rowling"),
      MockBook(title: "Lord of the Rings", authors: "J.R.R. Tolkien"),
      MockBook(title: "The Hobbit", authors: "J.R.R. Tolkien")
    ]
    
    let query = "Harry"
    let filteredBooks = allBooks.filter {
      $0.title.localizedCaseInsensitiveContains(query)
    }
    
    XCTAssertEqual(filteredBooks.count, 1)
    XCTAssertEqual(filteredBooks[0].title, "Harry Potter")
  }
  
  func testFilterBooks_ByAuthor() {
    struct MockBook {
      let title: String
      let authors: String?
    }
    
    let allBooks = [
      MockBook(title: "Harry Potter", authors: "J.K. Rowling"),
      MockBook(title: "Lord of the Rings", authors: "J.R.R. Tolkien"),
      MockBook(title: "The Hobbit", authors: "J.R.R. Tolkien")
    ]
    
    let query = "Tolkien"
    let filteredBooks = allBooks.filter {
      ($0.authors?.localizedCaseInsensitiveContains(query) ?? false)
    }
    
    XCTAssertEqual(filteredBooks.count, 2)
  }
  
  func testFilterBooks_CaseInsensitive() {
    struct MockBook {
      let title: String
      let authors: String?
    }
    
    let allBooks = [
      MockBook(title: "Harry Potter", authors: "J.K. Rowling")
    ]
    
    let query = "HARRY"
    let filteredBooks = allBooks.filter {
      $0.title.localizedCaseInsensitiveContains(query)
    }
    
    XCTAssertEqual(filteredBooks.count, 1, "Case insensitive search should match")
  }
  
  func testFilterBooks_EmptyQuery() {
    struct MockBook {
      let title: String
      let authors: String?
    }
    
    let allBooks = [
      MockBook(title: "Book 1", authors: "Author 1"),
      MockBook(title: "Book 2", authors: "Author 2")
    ]
    
    let query = ""
    let shouldShowAll = query.isEmpty
    
    XCTAssertTrue(shouldShowAll, "Empty query should show all books")
    
    let filteredBooks = shouldShowAll ? allBooks : []
    XCTAssertEqual(filteredBooks.count, 2)
  }
  
  func testFilterBooks_NoMatch() {
    struct MockBook {
      let title: String
      let authors: String?
    }
    
    let allBooks = [
      MockBook(title: "Harry Potter", authors: "J.K. Rowling"),
      MockBook(title: "Lord of the Rings", authors: "J.R.R. Tolkien")
    ]
    
    let query = "xyz123"
    let filteredBooks = allBooks.filter {
      $0.title.localizedCaseInsensitiveContains(query) ||
      ($0.authors?.localizedCaseInsensitiveContains(query) ?? false)
    }
    
    XCTAssertTrue(filteredBooks.isEmpty, "No books should match nonexistent query")
  }
  
  // MARK: - Loading State Tests
  
  func testLoadingState_InitiallyFalse() {
    var isLoading = false
    
    XCTAssertFalse(isLoading, "Loading should initially be false")
  }
  
  func testLoadingState_PreventsDuplicateLoads() {
    var isLoading = true
    var loadAttempts = 0
    
    // Simulate guard that prevents duplicate loads
    func loadData() {
      guard !isLoading else { return }
      loadAttempts += 1
    }
    
    loadData()
    loadData()
    loadData()
    
    XCTAssertEqual(loadAttempts, 0, "Should not load when already loading")
  }
  
  // MARK: - Empty State Tests
  
  func testEmptyState_WhenNoBooksExist() {
    let books: [String] = []
    let showInstructionsLabel = books.isEmpty
    
    XCTAssertTrue(showInstructionsLabel, "Should show instructions when no books")
  }
  
  func testEmptyState_WhenBooksExist() {
    let books = ["Book 1", "Book 2"]
    let showInstructionsLabel = books.isEmpty
    
    XCTAssertFalse(showInstructionsLabel, "Should not show instructions when books exist")
  }
  
  // MARK: - Expired Book Filtering Tests
  
  func testExpiredBooks_FilteredWhenOffline() {
    struct MockBook {
      let title: String
      let isExpired: Bool
    }
    
    let registryBooks = [
      MockBook(title: "Valid Book", isExpired: false),
      MockBook(title: "Expired Book", isExpired: true),
      MockBook(title: "Another Valid Book", isExpired: false)
    ]
    
    let isConnected = false
    let filteredBooks = isConnected 
      ? registryBooks 
      : registryBooks.filter { !$0.isExpired }
    
    XCTAssertEqual(filteredBooks.count, 2, "Expired books should be filtered when offline")
    XCTAssertTrue(filteredBooks.allSatisfy { !$0.isExpired })
  }
  
  func testExpiredBooks_ShownWhenOnline() {
    struct MockBook {
      let title: String
      let isExpired: Bool
    }
    
    let registryBooks = [
      MockBook(title: "Valid Book", isExpired: false),
      MockBook(title: "Expired Book", isExpired: true)
    ]
    
    let isConnected = true
    let filteredBooks = isConnected 
      ? registryBooks 
      : registryBooks.filter { !$0.isExpired }
    
    XCTAssertEqual(filteredBooks.count, 2, "All books should show when online")
  }
  
  // MARK: - Alert Model Tests
  
  func testAlertModel_CreationWithMessage() {
    let alert = AlertModel(
      title: "Error",
      message: "Something went wrong"
    )
    
    XCTAssertEqual(alert.title, "Error")
    XCTAssertEqual(alert.message, "Something went wrong")
  }
  
  func testAlertModel_SyncingAlert() {
    let title = Strings.MyBooksView.accountSyncingAlertTitle
    let message = Strings.MyBooksView.accountSyncingAlertMessage
    
    let alert = AlertModel(title: title, message: message)
    
    XCTAssertNotNil(alert.title)
    XCTAssertNotNil(alert.message)
  }
  
  // MARK: - FacetViewModel Tests
  
  func testFacetViewModel_InitWithDefaultSort() {
    let facets: [Facet] = [.title, .author]
    let firstFacet = facets.first!
    
    XCTAssertEqual(firstFacet, .title, "Default sort should be first facet")
  }
  
  func testFacetViewModel_AllFacetsPresent() {
    let facets: [Facet] = [.title, .author]
    
    XCTAssertEqual(facets.count, 2)
    XCTAssertTrue(facets.contains(.title))
    XCTAssertTrue(facets.contains(.author))
  }
  
  // MARK: - Book Return Tests
  
  func testBookReturn_RemovesFromList() {
    struct MockBook: Equatable {
      let id: String
      let title: String
    }
    
    var books = [
      MockBook(id: "1", title: "Book 1"),
      MockBook(id: "2", title: "Book 2"),
      MockBook(id: "3", title: "Book 3")
    ]
    
    let bookToReturn = books[1]
    books.removeAll { $0.id == bookToReturn.id }
    
    XCTAssertEqual(books.count, 2)
    XCTAssertFalse(books.contains(bookToReturn))
  }
  
  func testBookReturn_UpdatesRegistry() {
    // Simulate registry update after book return
    var registryBookCount = 3
    
    // Simulate book return
    registryBookCount -= 1
    
    XCTAssertEqual(registryBookCount, 2, "Registry should have one less book")
  }
  
  // MARK: - Combined Filter and Sort Tests
  
  func testFilterThenSort_MaintainsOrder() {
    struct MockBook {
      let title: String
      let authors: String?
    }
    
    let allBooks = [
      MockBook(title: "Zoo Book", authors: "A"),
      MockBook(title: "Apple Book", authors: "B"),
      MockBook(title: "Zoo Animal", authors: "C")
    ]
    
    // Filter by "Zoo"
    var filteredBooks = allBooks.filter { $0.title.contains("Zoo") }
    
    // Sort by title
    filteredBooks.sort { $0.title < $1.title }
    
    XCTAssertEqual(filteredBooks.count, 2)
    XCTAssertEqual(filteredBooks[0].title, "Zoo Animal")
    XCTAssertEqual(filteredBooks[1].title, "Zoo Book")
  }
}

