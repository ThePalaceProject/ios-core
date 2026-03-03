import XCTest
@testable import Palace

final class AudiobookDataManagerModelsTests: XCTestCase {
  
  // MARK: - Test Data
  
  private func createTestTimeEntry() -> AudiobookTimeEntry {
    AudiobookTimeEntry(
      id: "entry-123",
      bookId: "book-456",
      libraryId: "library-789",
      timeTrackingUrl: URL(string: "https://api.example.com/track")!,
      duringMinute: "2024-01-15T10:30Z",
      duration: 45
    )
  }
  
  // MARK: - LibraryBook Tests
  
  func testLibraryBookInit_directInit() {
    let libraryBook = LibraryBook(bookId: "book-1", libraryId: "lib-1")
    
    XCTAssertEqual(libraryBook.bookId, "book-1")
    XCTAssertEqual(libraryBook.libraryId, "lib-1")
  }
  
  func testLibraryBookInit_fromTimeEntry() {
    let timeEntry = createTestTimeEntry()
    let libraryBook = LibraryBook(time: timeEntry)
    
    XCTAssertEqual(libraryBook.bookId, "book-456")
    XCTAssertEqual(libraryBook.libraryId, "library-789")
  }
  
  func testLibraryBookEquality() {
    let book1 = LibraryBook(bookId: "abc", libraryId: "123")
    let book2 = LibraryBook(bookId: "abc", libraryId: "123")
    let book3 = LibraryBook(bookId: "abc", libraryId: "456")
    
    XCTAssertEqual(book1, book2)
    XCTAssertNotEqual(book1, book3)
  }
  
  func testLibraryBookHashable() {
    let book1 = LibraryBook(bookId: "abc", libraryId: "123")
    let book2 = LibraryBook(bookId: "abc", libraryId: "123")
    
    var set = Set<LibraryBook>()
    set.insert(book1)
    set.insert(book2)
    
    XCTAssertEqual(set.count, 1)
  }
  
  func testLibraryBookCodable() throws {
    let original = LibraryBook(bookId: "test-book", libraryId: "test-lib")
    
    let encoded = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(LibraryBook.self, from: encoded)
    
    XCTAssertEqual(decoded.bookId, original.bookId)
    XCTAssertEqual(decoded.libraryId, original.libraryId)
  }
  
  // MARK: - RequestData Tests
  
  func testRequestDataInit_direct() {
    let timeEntry = RequestData.TimeEntry(id: "e1", duringMinute: "2024-01-01T00:00Z", secondsPlayed: 30)
    let requestData = RequestData(libraryId: "lib", bookId: "book", timeEntries: [timeEntry])
    
    XCTAssertEqual(requestData.libraryId, "lib")
    XCTAssertEqual(requestData.bookId, "book")
    XCTAssertEqual(requestData.timeEntries.count, 1)
    XCTAssertEqual(requestData.timeEntries[0].secondsPlayed, 30)
  }
  
  func testRequestDataInit_fromLibraryBookAndEntries() {
    let libraryBook = LibraryBook(bookId: "book-123", libraryId: "lib-456")
    let entries = [createTestTimeEntry()]
    
    let requestData = RequestData(libraryBook: libraryBook, timeEntries: entries)
    
    XCTAssertEqual(requestData.bookId, "book-123")
    XCTAssertEqual(requestData.libraryId, "lib-456")
    XCTAssertEqual(requestData.timeEntries.count, 1)
    XCTAssertEqual(requestData.timeEntries[0].id, "entry-123")
    XCTAssertEqual(requestData.timeEntries[0].secondsPlayed, 45)
  }
  
  func testRequestDataJsonRepresentation() throws {
    let timeEntry = RequestData.TimeEntry(id: "e1", duringMinute: "2024-01-01T00:00Z", secondsPlayed: 60)
    let requestData = RequestData(libraryId: "my-lib", bookId: "my-book", timeEntries: [timeEntry])
    
    guard let jsonData = requestData.jsonRepresentation else {
      XCTFail("JSON representation should not be nil")
      return
    }
    
    let json = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
    
    XCTAssertEqual(json?["libraryId"] as? String, "my-lib")
    XCTAssertEqual(json?["bookId"] as? String, "my-book")
    
    let entries = json?["timeEntries"] as? [[String: Any]]
    XCTAssertEqual(entries?.count, 1)
    XCTAssertEqual(entries?[0]["id"] as? String, "e1")
    XCTAssertEqual(entries?[0]["secondsPlayed"] as? Int, 60)
  }
  
  func testRequestDataTimeEntryDescription() {
    let timeEntry = RequestData.TimeEntry(id: "test-id", duringMinute: "2024-06-01T12:00Z", secondsPlayed: 120)
    
    let description = timeEntry.description
    
    XCTAssertTrue(description.contains("test-id"))
    XCTAssertTrue(description.contains("2024-06-01T12:00Z"))
    XCTAssertTrue(description.contains("120"))
  }
  
  // MARK: - ResponseData Tests
  
  func testResponseDataInit_fromData_validJson() {
    let json = """
    {
      "responses": [
        {"status": 200, "message": "OK", "id": "entry-1"},
        {"status": 201, "message": "Created", "id": "entry-2"}
      ]
    }
    """
    let data = json.data(using: .utf8)!
    
    let responseData = ResponseData(data: data)
    
    XCTAssertNotNil(responseData)
    XCTAssertEqual(responseData?.responses.count, 2)
    XCTAssertEqual(responseData?.responses[0].status, 200)
    XCTAssertEqual(responseData?.responses[0].message, "OK")
    XCTAssertEqual(responseData?.responses[0].id, "entry-1")
    XCTAssertEqual(responseData?.responses[1].status, 201)
    XCTAssertEqual(responseData?.responses[1].id, "entry-2")
  }
  
  func testResponseDataInit_fromData_invalidJson_returnsNil() {
    let invalidJson = "not valid json"
    let data = invalidJson.data(using: .utf8)!
    
    let responseData = ResponseData(data: data)
    
    XCTAssertNil(responseData)
  }
  
  func testResponseDataInit_fromData_emptyResponses() {
    let json = """
    {"responses": []}
    """
    let data = json.data(using: .utf8)!
    
    let responseData = ResponseData(data: data)
    
    XCTAssertNotNil(responseData)
    XCTAssertEqual(responseData?.responses.count, 0)
  }
  
  func testResponseDataInit_direct() {
    let entries = [
      ResponseData.ResponseEntry(status: 200, message: "Success", id: "id-1")
    ]
    let responseData = ResponseData(responses: entries)
    
    XCTAssertEqual(responseData.responses.count, 1)
    XCTAssertEqual(responseData.responses[0].status, 200)
  }
  
  // MARK: - AudiobookDataManagerStore Tests
  
  func testAudiobookDataManagerStoreInit_empty() {
    let store = AudiobookDataManagerStore()
    
    XCTAssertTrue(store.urls.isEmpty)
    XCTAssertTrue(store.queue.isEmpty)
  }
  
  func testAudiobookDataManagerStoreInit_fromData_validJson() throws {
    let libraryBook = LibraryBook(bookId: "b1", libraryId: "l1")
    let entry = createTestTimeEntry()
    
    var originalStore = AudiobookDataManagerStore()
    originalStore.urls[libraryBook] = URL(string: "https://example.com")!
    originalStore.queue.append(entry)
    
    let jsonData = originalStore.jsonRepresentation!
    
    let decodedStore = AudiobookDataManagerStore(data: jsonData)
    
    XCTAssertNotNil(decodedStore)
    XCTAssertEqual(decodedStore?.urls.count, 1)
    XCTAssertEqual(decodedStore?.queue.count, 1)
    XCTAssertEqual(decodedStore?.queue.first?.id, "entry-123")
  }
  
  func testAudiobookDataManagerStoreInit_fromData_invalidJson_returnsNil() {
    let invalidData = "invalid".data(using: .utf8)!
    
    let store = AudiobookDataManagerStore(data: invalidData)
    
    XCTAssertNil(store)
  }
  
  func testAudiobookDataManagerStoreJsonRepresentation() {
    var store = AudiobookDataManagerStore()
    let libraryBook = LibraryBook(bookId: "book", libraryId: "lib")
    store.urls[libraryBook] = URL(string: "https://test.com")!
    
    let jsonData = store.jsonRepresentation
    
    XCTAssertNotNil(jsonData)
    XCTAssertGreaterThan(jsonData?.count ?? 0, 0)
  }
  
  func testAudiobookDataManagerStoreRoundTrip() throws {
    var originalStore = AudiobookDataManagerStore()
    let entry1 = AudiobookTimeEntry(
      id: "id1",
      bookId: "book1",
      libraryId: "lib1",
      timeTrackingUrl: URL(string: "https://api.test/1")!,
      duringMinute: "2024-01-01T00:00Z",
      duration: 60
    )
    let entry2 = AudiobookTimeEntry(
      id: "id2",
      bookId: "book2",
      libraryId: "lib2",
      timeTrackingUrl: URL(string: "https://api.test/2")!,
      duringMinute: "2024-01-01T01:00Z",
      duration: 120
    )
    
    originalStore.queue.append(entry1)
    originalStore.queue.append(entry2)
    originalStore.urls[LibraryBook(time: entry1)] = entry1.timeTrackingUrl
    originalStore.urls[LibraryBook(time: entry2)] = entry2.timeTrackingUrl
    
    let jsonData = originalStore.jsonRepresentation!
    let restoredStore = AudiobookDataManagerStore(data: jsonData)!
    
    XCTAssertEqual(restoredStore.queue.count, 2)
    XCTAssertEqual(restoredStore.urls.count, 2)
    XCTAssertEqual(restoredStore.queue[0].id, "id1")
    XCTAssertEqual(restoredStore.queue[1].duration, 120)
  }
  
  // MARK: - AudiobookTimeEntry Tests
  
  func testAudiobookTimeEntryEquality() {
    let entry1 = AudiobookTimeEntry(
      id: "same-id",
      bookId: "book",
      libraryId: "lib",
      timeTrackingUrl: URL(string: "https://test.com")!,
      duringMinute: "2024-01-01T00:00Z",
      duration: 30
    )
    let entry2 = AudiobookTimeEntry(
      id: "same-id",
      bookId: "book",
      libraryId: "lib",
      timeTrackingUrl: URL(string: "https://test.com")!,
      duringMinute: "2024-01-01T00:00Z",
      duration: 30
    )
    
    XCTAssertEqual(entry1, entry2)
  }
  
  func testAudiobookTimeEntryCodable() throws {
    let original = createTestTimeEntry()
    
    let encoded = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(AudiobookTimeEntry.self, from: encoded)
    
    XCTAssertEqual(decoded.id, original.id)
    XCTAssertEqual(decoded.bookId, original.bookId)
    XCTAssertEqual(decoded.libraryId, original.libraryId)
    XCTAssertEqual(decoded.timeTrackingUrl, original.timeTrackingUrl)
    XCTAssertEqual(decoded.duringMinute, original.duringMinute)
    XCTAssertEqual(decoded.duration, original.duration)
  }
}

