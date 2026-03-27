import XCTest
@testable import Palace

class TPPBookAuthorTests: XCTestCase {

  func test_init_withNameAndURL_setsProperties() {
    let url = URL(string: "https://example.com/authors/tolkien")!
    let author = TPPBookAuthor(authorName: "J.R.R. Tolkien", relatedBooksURL: url)

    XCTAssertEqual(author.name, "J.R.R. Tolkien")
    XCTAssertEqual(author.relatedBooksURL, url)
  }

  func test_init_withNilURL_setsNilURL() {
    let author = TPPBookAuthor(authorName: "Anonymous", relatedBooksURL: nil)

    XCTAssertEqual(author.name, "Anonymous")
    XCTAssertNil(author.relatedBooksURL)
  }

  func test_init_withEmptyName_setsEmptyName() {
    let author = TPPBookAuthor(authorName: "", relatedBooksURL: nil)
    XCTAssertEqual(author.name, "")
  }

  func test_sameNameAndURL_haveMatchingProperties() {
    let url = URL(string: "https://example.com/a")!
    let a = TPPBookAuthor(authorName: "Author", relatedBooksURL: url)
    let b = TPPBookAuthor(authorName: "Author", relatedBooksURL: url)
    XCTAssertEqual(a.name, b.name)
    XCTAssertEqual(a.relatedBooksURL, b.relatedBooksURL)
  }

  func test_differentName_haveDifferentProperties() {
    let a = TPPBookAuthor(authorName: "Alice", relatedBooksURL: nil)
    let b = TPPBookAuthor(authorName: "Bob", relatedBooksURL: nil)
    XCTAssertNotEqual(a.name, b.name)
  }
}
