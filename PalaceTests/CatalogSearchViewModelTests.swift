import XCTest
import Combine
@testable import Palace

@MainActor
final class CatalogSearchViewModelTests: XCTestCase {
  private var viewModel: CatalogSearchViewModel!
  private var cancellables: Set<AnyCancellable>!
  
  override func setUp() {
    super.setUp()
    viewModel = CatalogSearchViewModel()
    cancellables = Set<AnyCancellable>()
  }
  
  override func tearDown() {
    cancellables?.removeAll()
    viewModel = nil
    super.tearDown()
  }
  
  // MARK: - Test Data
  
  private var sampleBooks: [TPPBook] {
    [
      createMockBook(title: "Swift Programming", authors: "John Doe"),
      createMockBook(title: "iOS Development", authors: "Jane Smith"),
      createMockBook(title: "SwiftUI Guide", authors: "Bob Johnson"),
      createMockBook(title: "Objective-C Legacy", authors: "Old Developer")
    ]
  }
  
  private func createMockBook(title: String, authors: String) -> TPPBook {
    let book = TPPBook()
    book.title = title
    book.authors = authors
    book.identifier = UUID().uuidString
    return book
  }
  
  // MARK: - Search Functionality Tests
  
  func testInitialState() {
    XCTAssertTrue(viewModel.searchQuery.isEmpty)
    XCTAssertTrue(viewModel.filteredBooks.isEmpty)
  }
  
  func testUpdateBooks() {
    // Given
    let books = sampleBooks
    
    // When
    viewModel.updateBooks(books)
    
    // Then
    XCTAssertEqual(viewModel.filteredBooks.count, 4)
    XCTAssertEqual(viewModel.filteredBooks, books)
  }
  
  func testSearchByTitle() {
    // Given
    viewModel.updateBooks(sampleBooks)
    
    // When
    viewModel.updateSearchQuery("Swift")
    
    // Then
    XCTAssertEqual(viewModel.filteredBooks.count, 2)
    XCTAssertTrue(viewModel.filteredBooks.allSatisfy { $0.title.contains("Swift") })
  }
  
  func testSearchByAuthor() {
    // Given
    viewModel.updateBooks(sampleBooks)
    
    // When
    viewModel.updateSearchQuery("John")
    
    // Then
    XCTAssertEqual(viewModel.filteredBooks.count, 2)
    let titles = viewModel.filteredBooks.map { $0.title }
    XCTAssertTrue(titles.contains("Swift Programming"))
    XCTAssertTrue(titles.contains("SwiftUI Guide"))
  }
  
  func testCaseInsensitiveSearch() {
    // Given
    viewModel.updateBooks(sampleBooks)
    
    // When
    viewModel.updateSearchQuery("swift")
    
    // Then
    XCTAssertEqual(viewModel.filteredBooks.count, 2)
    XCTAssertTrue(viewModel.filteredBooks.allSatisfy { $0.title.lowercased().contains("swift") })
  }
  
  func testEmptySearchQuery() {
    // Given
    viewModel.updateBooks(sampleBooks)
    viewModel.updateSearchQuery("Swift")
    
    // When
    viewModel.updateSearchQuery("")
    
    // Then
    XCTAssertEqual(viewModel.filteredBooks.count, 4)
    XCTAssertEqual(viewModel.filteredBooks, sampleBooks)
  }
  
  func testWhitespaceOnlyQuery() {
    // Given
    viewModel.updateBooks(sampleBooks)
    
    // When
    viewModel.updateSearchQuery("   ")
    
    // Then
    XCTAssertEqual(viewModel.filteredBooks.count, 4)
    XCTAssertEqual(viewModel.filteredBooks, sampleBooks)
  }
  
  func testNoResults() {
    // Given
    viewModel.updateBooks(sampleBooks)
    
    // When
    viewModel.updateSearchQuery("Python")
    
    // Then
    XCTAssertTrue(viewModel.filteredBooks.isEmpty)
  }
  
  func testClearSearch() {
    // Given
    viewModel.updateBooks(sampleBooks)
    viewModel.updateSearchQuery("Swift")
    
    // When
    viewModel.clearSearch()
    
    // Then
    XCTAssertTrue(viewModel.searchQuery.isEmpty)
    XCTAssertEqual(viewModel.filteredBooks.count, 4)
  }
  
  // MARK: - Reactive Updates Tests
  
  func testSearchQueryPublisher() {
    // Given
    let expectation = XCTestExpectation(description: "Search query updates")
    var queryUpdates: [String] = []
    
    viewModel.$searchQuery
      .sink { query in
        queryUpdates.append(query)
        if queryUpdates.count == 3 {
          expectation.fulfill()
        }
      }
      .store(in: &cancellables)
    
    // When
    viewModel.updateSearchQuery("S")
    viewModel.updateSearchQuery("Sw")
    
    // Then
    wait(for: [expectation], timeout: 1.0)
    XCTAssertEqual(queryUpdates, ["", "S", "Sw"])
  }
  
  func testFilteredBooksPublisher() {
    // Given
    let expectation = XCTestExpectation(description: "Filtered books updates")
    var bookCounts: [Int] = []
    
    viewModel.$filteredBooks
      .sink { books in
        bookCounts.append(books.count)
        if bookCounts.count == 3 {
          expectation.fulfill()
        }
      }
      .store(in: &cancellables)
    
    viewModel.updateBooks(sampleBooks)
    
    // When
    viewModel.updateSearchQuery("Swift")
    
    // Then
    wait(for: [expectation], timeout: 1.0)
    XCTAssertEqual(bookCounts, [0, 4, 2])
  }
  
  // MARK: - Performance Tests
  
  func testLargeDatasetPerformance() {
    // Given
    let largeBookSet = (0..<10000).map { index in
      createMockBook(title: "Book \(index)", authors: "Author \(index % 100)")
    }
    
    viewModel.updateBooks(largeBookSet)
    
    // When
    measure {
      viewModel.updateSearchQuery("Book 1")
    }
    
    // Then - Should complete within reasonable time
    XCTAssertFalse(viewModel.filteredBooks.isEmpty)
  }
  
  // MARK: - Edge Cases
  
  func testNilAuthors() {
    // Given
    let bookWithNilAuthors = TPPBook()
    bookWithNilAuthors.title = "Test Book"
    bookWithNilAuthors.authors = nil
    bookWithNilAuthors.identifier = "test-id"
    
    viewModel.updateBooks([bookWithNilAuthors])
    
    // When
    viewModel.updateSearchQuery("Test")
    
    // Then - Should not crash and should find the book
    XCTAssertEqual(viewModel.filteredBooks.count, 1)
    XCTAssertEqual(viewModel.filteredBooks.first?.title, "Test Book")
  }
  
  func testEmptyTitle() {
    // Given
    let bookWithEmptyTitle = createMockBook(title: "", authors: "Some Author")
    viewModel.updateBooks([bookWithEmptyTitle])
    
    // When
    viewModel.updateSearchQuery("Author")
    
    // Then - Should find by author even with empty title
    XCTAssertEqual(viewModel.filteredBooks.count, 1)
  }
}

