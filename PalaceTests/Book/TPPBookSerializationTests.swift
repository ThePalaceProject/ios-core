import XCTest
@testable import Palace

class TPPBookSerializationTests: XCTestCase {

  // MARK: - Dictionary round-trip

  func test_dictionaryRoundTrip_preservesAllFields() throws {
    let acquisitions = [TPPFake.genericAcquisition.dictionaryRepresentation()]
    let original = TPPBook(dictionary: [
      "acquisitions": acquisitions,
      "categories": ["Fiction", "Fantasy"],
      "id": "book-42",
      "title": "Test Book",
      "updated": "2024-01-15T10:30:00Z",
      "authors": [["name": "Test Author"]],
      "subtitle": "A Subtitle",
      "summary": "A great book.",
      "publisher": "Test Publisher"
    ])
    XCTAssertNotNil(original)

    let dict = original!.dictionaryRepresentation()
    let restored = TPPBook(dictionary: dict as! [String: Any])
    XCTAssertNotNil(restored)

    XCTAssertEqual(restored?.identifier, original?.identifier)
    XCTAssertEqual(restored?.title, original?.title)
    XCTAssertEqual(restored?.subtitle, original?.subtitle)
    XCTAssertEqual(restored?.summary, original?.summary)
    XCTAssertEqual(restored?.publisher, original?.publisher)
    XCTAssertEqual(restored?.categoryStrings?.count, original?.categoryStrings?.count)
  }

  func test_dictionaryRoundTrip_preservesIdentifier() throws {
    let acquisitions = [TPPFake.genericAcquisition.dictionaryRepresentation()]
    let book = TPPBook(dictionary: [
      "acquisitions": acquisitions,
      "categories": ["Test"],
      "id": "unique-id-123",
      "title": "Title",
      "updated": "2024-01-01T00:00:00Z"
    ])!

    let dict = book.dictionaryRepresentation()
    let restored = TPPBook(dictionary: dict as! [String: Any])
    XCTAssertEqual(restored?.identifier, "unique-id-123")
  }

  // MARK: - Required fields validation

  func test_initFromDictionary_missingId_returnsNil() {
    let acquisitions = [TPPFake.genericAcquisition.dictionaryRepresentation()]
    let book = TPPBook(dictionary: [
      "acquisitions": acquisitions,
      "categories": ["Test"],
      "title": "Title",
      "updated": "2024-01-01T00:00:00Z"
    ])
    XCTAssertNil(book)
  }

  func test_initFromDictionary_missingTitle_returnsNil() {
    let acquisitions = [TPPFake.genericAcquisition.dictionaryRepresentation()]
    let book = TPPBook(dictionary: [
      "acquisitions": acquisitions,
      "categories": ["Test"],
      "id": "123",
      "updated": "2024-01-01T00:00:00Z"
    ])
    XCTAssertNil(book)
  }

  func test_initFromDictionary_missingUpdated_returnsNil() {
    let acquisitions = [TPPFake.genericAcquisition.dictionaryRepresentation()]
    let book = TPPBook(dictionary: [
      "acquisitions": acquisitions,
      "categories": ["Test"],
      "id": "123",
      "title": "Title"
    ])
    XCTAssertNil(book)
  }

  // MARK: - Content type

  func test_defaultBookContentType_forEpub_returnsEpub() {
    let acquisitions = [TPPFake.genericAcquisition.dictionaryRepresentation()]
    let book = TPPBook(dictionary: [
      "acquisitions": acquisitions,
      "categories": ["Test"],
      "id": "epub-book",
      "title": "EPUB Book",
      "updated": "2024-01-01T00:00:00Z"
    ])!
    XCTAssertEqual(book.defaultBookContentType, .epub)
  }

  func test_defaultBookContentType_forAudiobook_returnsAudiobook() {
    let acquisitions = [TPPFake.genericAudiobookAcquisition.dictionaryRepresentation()]
    let book = TPPBook(dictionary: [
      "acquisitions": acquisitions,
      "categories": ["Test"],
      "id": "audio-book",
      "title": "Audiobook",
      "updated": "2024-01-01T00:00:00Z"
    ])!
    XCTAssertEqual(book.defaultBookContentType, .audiobook)
  }

  // MARK: - Category strings

  func test_categoryStrings_returnsCategories() {
    let acquisitions = [TPPFake.genericAcquisition.dictionaryRepresentation()]
    let book = TPPBook(dictionary: [
      "acquisitions": acquisitions,
      "categories": ["Fiction", "Mystery", "Thriller"],
      "id": "cat-book",
      "title": "Categories",
      "updated": "2024-01-01T00:00:00Z"
    ])!
    XCTAssertEqual(book.categoryStrings?.count, 3)
    XCTAssertTrue(book.categoryStrings?.contains("Fiction") ?? false)
  }

  // MARK: - Comparable

  func test_comparable_sortsAlphabeticallyByTitle() {
    let acquisitions = [TPPFake.genericAcquisition.dictionaryRepresentation()]
    let bookA = TPPBook(dictionary: [
      "acquisitions": acquisitions,
      "categories": ["Test"],
      "id": "a",
      "title": "Alpha",
      "updated": "2024-01-01T00:00:00Z"
    ])!
    let bookB = TPPBook(dictionary: [
      "acquisitions": acquisitions,
      "categories": ["Test"],
      "id": "b",
      "title": "Beta",
      "updated": "2024-01-01T00:00:00Z"
    ])!
    XCTAssertTrue(bookA < bookB)
    XCTAssertFalse(bookB < bookA)
  }
}
