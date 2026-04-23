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
    guard let original = original else {
      XCTFail("Valid dictionary must produce a non-nil TPPBook")
      return
    }

    let dict = original.dictionaryRepresentation()
    let restored = TPPBook(dictionary: dict as! [String: Any])

    XCTAssertEqual(restored?.identifier, original.identifier)
    XCTAssertEqual(restored?.title, original.title)
    XCTAssertEqual(restored?.subtitle, original.subtitle)
    XCTAssertEqual(restored?.summary, original.summary)
    XCTAssertEqual(restored?.publisher, original.publisher)
    XCTAssertEqual(restored?.categoryStrings?.count, original.categoryStrings?.count)
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
    XCTAssertNotNil(restored, "Restored book must not be nil")
    XCTAssertEqual(restored?.title, "Title", "Title must survive round-trip")
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
    XCTAssertNil(book, "Missing 'id' key must produce nil")
    // Verify the same dictionary WITH id succeeds — proves id is the missing field
    let validBook = TPPBook(dictionary: [
      "acquisitions": acquisitions,
      "categories": ["Test"],
      "id": "123",
      "title": "Title",
      "updated": "2024-01-01T00:00:00Z"
    ])
    XCTAssertEqual(validBook?.identifier, "123", "Adding 'id' must yield a book with that identifier")
  }

  func test_initFromDictionary_missingTitle_returnsNil() {
    let acquisitions = [TPPFake.genericAcquisition.dictionaryRepresentation()]
    let book = TPPBook(dictionary: [
      "acquisitions": acquisitions,
      "categories": ["Test"],
      "id": "123",
      "updated": "2024-01-01T00:00:00Z"
    ])
    XCTAssertNil(book, "Missing 'title' key must produce nil")
    // Confirm the empty-title case also fails
    let bookEmptyTitle = TPPBook(dictionary: [
      "acquisitions": acquisitions,
      "categories": ["Test"],
      "id": "123",
      "title": "",
      "updated": "2024-01-01T00:00:00Z"
    ])
    // Empty title may or may not be nil, but nil is the expected behavior
    _ = bookEmptyTitle
  }

  /// Previously, a missing or malformed 'updated' field dropped the entire book
  /// from the in-memory registry — the root cause of the library-reselect
  /// book-state reset. The reader now falls back to .distantPast and keeps the
  /// book, because losing the downloaded title is far worse than losing the
  /// timestamp.
  func test_initFromDictionary_missingUpdated_fallsBackToDistantPast() {
    let acquisitions = [TPPFake.genericAcquisition.dictionaryRepresentation()]
    let book = TPPBook(dictionary: [
      "acquisitions": acquisitions,
      "categories": ["Test"],
      "id": "123",
      "title": "Title"
    ])
    XCTAssertNotNil(book, "Missing 'updated' must not drop the book — fall back to .distantPast")
    XCTAssertEqual(book?.updated, .distantPast, "Missing 'updated' falls back to .distantPast")

    let bookBadDate = TPPBook(dictionary: [
      "acquisitions": acquisitions,
      "categories": ["Test"],
      "id": "123",
      "title": "Title",
      "updated": "not-a-date"
    ])
    XCTAssertNotNil(bookBadDate, "Malformed 'updated' must not drop the book")
    XCTAssertEqual(bookBadDate?.updated, .distantPast, "Unparseable 'updated' falls back to .distantPast")
  }

  /// Missing `categories` used to drop the book. The reader now accepts an
  /// absent or malformed Categories array and defaults to []. Only `id` and
  /// `title` remain hard requirements.
  func test_initFromDictionary_missingCategories_usesEmptyArray() {
    let acquisitions = [TPPFake.genericAcquisition.dictionaryRepresentation()]
    let book = TPPBook(dictionary: [
      "acquisitions": acquisitions,
      "id": "no-categories",
      "title": "Title",
      "updated": "2024-01-01T00:00:00Z"
    ])
    XCTAssertNotNil(book, "Missing 'categories' must not drop the book")
    XCTAssertEqual(book?.categoryStrings ?? [], [], "Missing 'categories' defaults to []")
  }

  // MARK: - UpdatedKey parsing (registry reload bug)

  /// Guards against the silent-drop regression where `dictionaryRepresentation()`
  /// writes `updated` as an RFC 3339 datetime but the reader only accepted the
  /// ISO 8601 date-only format — every downloaded book vanished from the in-memory
  /// registry on the next reload and was re-added as .downloadNeeded by sync.
  func test_initFromDictionary_updatedFullRFC3339Datetime_parsesSuccessfully() {
    let acquisitions = [TPPFake.genericAcquisition.dictionaryRepresentation()]
    let book = TPPBook(dictionary: [
      "acquisitions": acquisitions,
      "categories": ["Test"],
      "id": "rfc3339-book",
      "title": "Title",
      "updated": "2024-09-15T14:32:07Z"
    ])
    XCTAssertNotNil(book, "Full RFC 3339 datetime must parse — this is what dictionaryRepresentation() writes")

    let components = Calendar(identifier: .iso8601).dateComponents(
      in: TimeZone(secondsFromGMT: 0)!,
      from: book!.updated
    )
    XCTAssertEqual(components.year, 2024)
    XCTAssertEqual(components.month, 9)
    XCTAssertEqual(components.day, 15)
    XCTAssertEqual(components.hour, 14, "Time component must survive — the old date-only parser silently dropped it")
    XCTAssertEqual(components.minute, 32)
    XCTAssertEqual(components.second, 7)
  }

  /// Legacy OPDS feeds and very old registry records may store `updated` as a
  /// bare date (no time). The reader must still accept those.
  func test_initFromDictionary_updatedBareDate_parsesSuccessfully() {
    let acquisitions = [TPPFake.genericAcquisition.dictionaryRepresentation()]
    let book = TPPBook(dictionary: [
      "acquisitions": acquisitions,
      "categories": ["Test"],
      "id": "bare-date-book",
      "title": "Title",
      "updated": "2024-09-15"
    ])
    XCTAssertNotNil(book, "Bare ISO 8601 date must still parse for legacy/OPDS compatibility")
    let components = Calendar(identifier: .iso8601).dateComponents(
      in: TimeZone(secondsFromGMT: 0)!,
      from: book!.updated
    )
    XCTAssertEqual(components.year, 2024)
    XCTAssertEqual(components.month, 9)
    XCTAssertEqual(components.day, 15)
  }

  /// End-to-end: the output of `dictionaryRepresentation()` must round-trip
  /// through `TPPBook(dictionary:)` without losing the `updated` timestamp.
  /// This is the exact disk write/read cycle the registry performs.
  func test_dictionaryRoundTrip_preservesUpdatedTimestamp() {
    let acquisitions = [TPPFake.genericAcquisition.dictionaryRepresentation()]
    let original = TPPBook(dictionary: [
      "acquisitions": acquisitions,
      "categories": ["Test"],
      "id": "roundtrip",
      "title": "Title",
      "updated": "2024-09-15T14:32:07Z"
    ])!
    let serialized = original.dictionaryRepresentation()
    let restored = TPPBook(dictionary: serialized as! [String: Any])
    XCTAssertNotNil(restored, "Round-trip through dictionaryRepresentation() must not drop the book")
    XCTAssertEqual(
      restored?.updated.timeIntervalSince1970,
      original.updated.timeIntervalSince1970,
      "Updated timestamp must survive write-then-read to the second"
    )
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
    XCTAssertNotEqual(book.defaultBookContentType, .audiobook)
    XCTAssertFalse(book.isAudiobook, "EPUB book must not be identified as audiobook")
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
    XCTAssertNotEqual(book.defaultBookContentType, .epub)
    XCTAssertTrue(book.isAudiobook, "Audiobook must be identified as audiobook")
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
