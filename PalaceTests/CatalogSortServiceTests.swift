import XCTest
@testable import Palace

final class CatalogSortServiceTests: XCTestCase {
  
  // MARK: - Test Data
  
  private func createTestBooks() -> [TPPBook] {
    let bookA = TPPBookMocker.mockBook(title: "Alpha Story", authors: "Adams, John")
    let bookB = TPPBookMocker.mockBook(title: "Beta Tales", authors: "Brown, Lisa")
    let bookC = TPPBookMocker.mockBook(title: "Gamma Quest", authors: "Carter, Mike")
    return [bookB, bookC, bookA]  // Intentionally unsorted
  }
  
  // MARK: - SortOption localizedString Tests
  
  func testSortOptionLocalizedStrings() {
    XCTAssertEqual(CatalogSortService.SortOption.authorAZ.localizedString, "Author (A-Z)")
    XCTAssertEqual(CatalogSortService.SortOption.authorZA.localizedString, "Author (Z-A)")
    XCTAssertEqual(CatalogSortService.SortOption.recentlyAddedAZ.localizedString, "Recently Added (A-Z)")
    XCTAssertEqual(CatalogSortService.SortOption.recentlyAddedZA.localizedString, "Recently Added (Z-A)")
    XCTAssertEqual(CatalogSortService.SortOption.titleAZ.localizedString, "Title (A-Z)")
    XCTAssertEqual(CatalogSortService.SortOption.titleZA.localizedString, "Title (Z-A)")
  }
  
  func testSortOptionFromLocalizedString_validStrings() {
    XCTAssertEqual(CatalogSortService.SortOption.from(localizedString: "Author (A-Z)"), .authorAZ)
    XCTAssertEqual(CatalogSortService.SortOption.from(localizedString: "Author (Z-A)"), .authorZA)
    XCTAssertEqual(CatalogSortService.SortOption.from(localizedString: "Recently Added (A-Z)"), .recentlyAddedAZ)
    XCTAssertEqual(CatalogSortService.SortOption.from(localizedString: "Recently Added (Z-A)"), .recentlyAddedZA)
    XCTAssertEqual(CatalogSortService.SortOption.from(localizedString: "Title (A-Z)"), .titleAZ)
    XCTAssertEqual(CatalogSortService.SortOption.from(localizedString: "Title (Z-A)"), .titleZA)
  }
  
  func testSortOptionFromLocalizedString_invalidString_returnsNil() {
    XCTAssertNil(CatalogSortService.SortOption.from(localizedString: "Invalid Sort"))
    XCTAssertNil(CatalogSortService.SortOption.from(localizedString: ""))
    XCTAssertNil(CatalogSortService.SortOption.from(localizedString: "author (a-z)"))  // Case sensitive
  }
  
  // MARK: - Sort by Author Tests
  
  func testSortByAuthorAZ() {
    var books = createTestBooks()
    CatalogSortService.sort(books: &books, by: .authorAZ)
    
    XCTAssertEqual(books[0].authors, "Adams, John")
    XCTAssertEqual(books[1].authors, "Brown, Lisa")
    XCTAssertEqual(books[2].authors, "Carter, Mike")
  }
  
  func testSortByAuthorZA() {
    var books = createTestBooks()
    CatalogSortService.sort(books: &books, by: .authorZA)
    
    XCTAssertEqual(books[0].authors, "Carter, Mike")
    XCTAssertEqual(books[1].authors, "Brown, Lisa")
    XCTAssertEqual(books[2].authors, "Adams, John")
  }
  
  // MARK: - Sort by Title Tests
  
  func testSortByTitleAZ() {
    var books = createTestBooks()
    CatalogSortService.sort(books: &books, by: .titleAZ)
    
    XCTAssertEqual(books[0].title, "Alpha Story")
    XCTAssertEqual(books[1].title, "Beta Tales")
    XCTAssertEqual(books[2].title, "Gamma Quest")
  }
  
  func testSortByTitleZA() {
    var books = createTestBooks()
    CatalogSortService.sort(books: &books, by: .titleZA)
    
    XCTAssertEqual(books[0].title, "Gamma Quest")
    XCTAssertEqual(books[1].title, "Beta Tales")
    XCTAssertEqual(books[2].title, "Alpha Story")
  }
  
  // MARK: - Sort by Recently Added Tests
  
  func testSortByRecentlyAddedAZ() {
    let oldDate = Date(timeIntervalSince1970: 1000)
    let midDate = Date(timeIntervalSince1970: 2000)
    let newDate = Date(timeIntervalSince1970: 3000)
    
    let bookOld = TPPBookMocker.mockBook(title: "Old Book", updated: oldDate)
    let bookMid = TPPBookMocker.mockBook(title: "Mid Book", updated: midDate)
    let bookNew = TPPBookMocker.mockBook(title: "New Book", updated: newDate)
    
    var books = [bookNew, bookOld, bookMid]
    CatalogSortService.sort(books: &books, by: .recentlyAddedAZ)
    
    XCTAssertEqual(books[0].title, "Old Book")
    XCTAssertEqual(books[1].title, "Mid Book")
    XCTAssertEqual(books[2].title, "New Book")
  }
  
  func testSortByRecentlyAddedZA() {
    let oldDate = Date(timeIntervalSince1970: 1000)
    let midDate = Date(timeIntervalSince1970: 2000)
    let newDate = Date(timeIntervalSince1970: 3000)
    
    let bookOld = TPPBookMocker.mockBook(title: "Old Book", updated: oldDate)
    let bookMid = TPPBookMocker.mockBook(title: "Mid Book", updated: midDate)
    let bookNew = TPPBookMocker.mockBook(title: "New Book", updated: newDate)
    
    var books = [bookNew, bookOld, bookMid]
    CatalogSortService.sort(books: &books, by: .recentlyAddedZA)
    
    XCTAssertEqual(books[0].title, "New Book")
    XCTAssertEqual(books[1].title, "Mid Book")
    XCTAssertEqual(books[2].title, "Old Book")
  }
  
  // MARK: - Sorted (Copy) Method Tests
  
  func testSortedReturnsNewArray() {
    let books = createTestBooks()
    let sortedBooks = CatalogSortService.sorted(books: books, by: .titleAZ)
    
    XCTAssertEqual(sortedBooks[0].title, "Alpha Story")
    XCTAssertEqual(books[0].title, "Beta Tales")  // Original unchanged
  }
  
  // MARK: - Edge Cases
  
  func testSortEmptyArray() {
    var books: [TPPBook] = []
    CatalogSortService.sort(books: &books, by: .titleAZ)
    XCTAssertTrue(books.isEmpty)
  }
  
  func testSortSingleBook() {
    var books = [TPPBookMocker.mockBook(title: "Solo")]
    CatalogSortService.sort(books: &books, by: .titleAZ)
    XCTAssertEqual(books.count, 1)
    XCTAssertEqual(books[0].title, "Solo")
  }
  
  func testSortWithNilAuthors() {
    let bookWithAuthor = TPPBookMocker.mockBook(title: "With Author", authors: "Zebra, Zack")
    let bookNoAuthor = TPPBookMocker.mockBook(title: "No Author", authors: nil)
    
    var books = [bookWithAuthor, bookNoAuthor]
    CatalogSortService.sort(books: &books, by: .authorAZ)
    
    // Nil authors treated as empty string, should come before "Zebra"
    XCTAssertEqual(books[0].title, "No Author")
    XCTAssertEqual(books[1].title, "With Author")
  }
  
  // MARK: - CaseIterable Tests
  
  func testAllCases() {
    XCTAssertEqual(CatalogSortService.SortOption.allCases.count, 6)
  }
}

