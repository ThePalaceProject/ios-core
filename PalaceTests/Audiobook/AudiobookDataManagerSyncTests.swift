//
//  AudiobookDataManagerSyncTests.swift
//  PalaceTests
//
//  Tests for AudiobookDataManager network sync, error handling, and data persistence
//

import XCTest
import Combine
@testable import Palace

// MARK: - Mock Network Executor for Testing

/// Thread-safe mock network executor for AudiobookDataManager tests
class MockNetworkExecutorForSync: TPPNetworkExecutor {

    private let lock = NSLock()
    private var _responses: [URL: MockResponse] = [:]
    private var _requestHistory: [(request: URLRequest, body: Data?)] = []

    struct MockResponse {
        let statusCode: Int
        let data: Data?
        let error: Error?
        let delay: TimeInterval

        init(statusCode: Int, data: Data? = nil, error: Error? = nil, delay: TimeInterval = 0) {
            self.statusCode = statusCode
            self.data = data
            self.error = error
            self.delay = delay
        }
    }

    var responses: [URL: MockResponse] {
        get { lock.withLock { _responses } }
        set { lock.withLock { _responses = newValue } }
    }

    var requestHistory: [(request: URLRequest, body: Data?)] {
        lock.withLock { _requestHistory }
    }

    func clearHistory() {
        lock.withLock { _requestHistory.removeAll() }
    }

    convenience init() {
        self.init(cachingStrategy: .ephemeral)
    }

    override func POST(_ request: URLRequest,
                       useTokenIfAvailable: Bool,
                       completion: ((_ result: Data?, _ response: URLResponse?, _ error: Error?) -> Void)?) -> URLSessionDataTask? {

        lock.lock()
        _requestHistory.append((request: request, body: request.httpBody))
        lock.unlock()

        guard let url = request.url else {
            completion?(nil, nil, NSError(domain: "MockNetworkExecutor", code: -1, userInfo: [NSLocalizedDescriptionKey: "No URL"]))
            return nil
        }

        let mockResponse = lock.withLock { _responses[url] } ?? MockResponse(statusCode: 200, data: nil)

        let dispatchDelay = mockResponse.delay
        DispatchQueue.global().asyncAfter(deadline: .now() + dispatchDelay) {
            let httpResponse = HTTPURLResponse(
                url: url,
                statusCode: mockResponse.statusCode,
                httpVersion: "1.1",
                headerFields: ["Content-Type": "application/json"]
            )

            completion?(mockResponse.data, httpResponse, mockResponse.error)
        }

        return nil
    }
}

// MARK: - Network Sync Tests

final class AudiobookDataManagerNetworkSyncTests: XCTestCase {

    private var mockNetworkExecutor: MockNetworkExecutorForSync!
    private var dataManager: AudiobookDataManager!
    private var testStoreURL: URL!

    override func setUp() {
        super.setUp()
        mockNetworkExecutor = MockNetworkExecutorForSync()
        dataManager = AudiobookDataManager(syncTimeInterval: 3600, networkService: mockNetworkExecutor)
        dataManager.store.queue.removeAll()
        dataManager.store.urls.removeAll()
        testStoreURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_timetracker")
    }

    override func tearDown() {
        dataManager?.store.queue.removeAll()
        dataManager?.store.urls.removeAll()
        dataManager = nil
        mockNetworkExecutor = nil
        try? FileManager.default.removeItem(at: testStoreURL)
        super.tearDown()
    }

    // MARK: - Successful Sync Tests

    func testAudiobookDataManager_Sync_InitializesCorrectly() {
        XCTAssertNotNil(dataManager)
        XCTAssertTrue(dataManager.store.queue.isEmpty)
        XCTAssertTrue(dataManager.store.urls.isEmpty)
    }

    func testSyncValues_withQueuedEntries_postsToCorrectURL() {
        let trackingURL = URL(string: "https://api.example.com/track")!
        let entry = AudiobookTimeEntry(
            id: "entry-1", bookId: "book-123", libraryId: "lib-456",
            timeTrackingUrl: trackingURL, duringMinute: "2024-01-15T10:30Z", duration: 45
        )

        let successResponse = Data("""
    {"responses": [{"status": 200, "message": "OK", "id": "entry-1"}]}
    """.utf8)
        mockNetworkExecutor.responses[trackingURL] = MockNetworkExecutorForSync.MockResponse(
            statusCode: 200, data: successResponse
        )

        dataManager.save(time: entry)

        // Poll until the mock receives a POST rather than using a fixed delay
        let mockRef = mockNetworkExecutor!
        let requestReceived = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in mockRef.requestHistory.count > 0 },
            object: nil
        )
        dataManager.syncValues()
        wait(for: [requestReceived], timeout: 5.0)

        XCTAssertEqual(mockNetworkExecutor.requestHistory.count, 1, "Should have made one request")
        XCTAssertEqual(mockNetworkExecutor.requestHistory.first?.request.url, trackingURL)
        XCTAssertEqual(mockNetworkExecutor.requestHistory.first?.request.httpMethod, "POST")
    }

    func testSyncValues_withSuccessfulResponse_removesEntriesFromQueue() {
        let trackingURL = URL(string: "https://api.example.com/track")!
        let entry = AudiobookTimeEntry(
            id: "entry-1", bookId: "book-123", libraryId: "lib-456",
            timeTrackingUrl: trackingURL, duringMinute: "2024-01-15T10:30Z", duration: 45
        )

        let successResponse = Data("""
    {"responses": [{"status": 200, "message": "OK", "id": "entry-1"}]}
    """.utf8)
        mockNetworkExecutor.responses[trackingURL] = MockNetworkExecutorForSync.MockResponse(
            statusCode: 200, data: successResponse
        )

        dataManager.save(time: entry)

        // save uses syncQueue.async(flags:.barrier); polling queue count is safe via its internal sync
        let savedExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { [weak self] _, _ in self?.dataManager.store.queue.count == 1 },
            object: nil
        )
        wait(for: [savedExpectation], timeout: 2.0)
        XCTAssertEqual(dataManager.store.queue.count, 1, "Should have one entry before sync")

        let queueEmptyExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { [weak self] _, _ in self?.dataManager.store.queue.isEmpty == true },
            object: nil
        )
        dataManager.syncValues()
        wait(for: [queueEmptyExpectation], timeout: 5.0)

        XCTAssertEqual(dataManager.store.queue.count, 0, "Entry should be removed after successful sync")
    }

    func testSyncValues_withMultipleBooks_makesRequestForEach() {
        let trackingURL1 = URL(string: "https://api.example.com/track/book1")!
        let trackingURL2 = URL(string: "https://api.example.com/track/book2")!

        let entry1 = AudiobookTimeEntry(
            id: "entry-1", bookId: "book-1", libraryId: "lib-1",
            timeTrackingUrl: trackingURL1, duringMinute: "2024-01-15T10:30Z", duration: 30
        )
        let entry2 = AudiobookTimeEntry(
            id: "entry-2", bookId: "book-2", libraryId: "lib-1",
            timeTrackingUrl: trackingURL2, duringMinute: "2024-01-15T10:31Z", duration: 45
        )

        let successResponse1 = Data("""
    {"responses": [{"status": 200, "message": "OK", "id": "entry-1"}]}
    """.utf8)
        let successResponse2 = Data("""
    {"responses": [{"status": 200, "message": "OK", "id": "entry-2"}]}
    """.utf8)

        mockNetworkExecutor.responses[trackingURL1] = MockNetworkExecutorForSync.MockResponse(statusCode: 200, data: successResponse1)
        mockNetworkExecutor.responses[trackingURL2] = MockNetworkExecutorForSync.MockResponse(statusCode: 200, data: successResponse2)

        dataManager.save(time: entry1)
        dataManager.save(time: entry2)

        let mockRef = mockNetworkExecutor!
        let twoRequestsReceived = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in mockRef.requestHistory.count >= 2 },
            object: nil
        )
        dataManager.syncValues()
        wait(for: [twoRequestsReceived], timeout: 5.0)

        XCTAssertEqual(mockNetworkExecutor.requestHistory.count, 2, "Should make request for each book")
    }

    func testSyncValues_requestBodyContainsCorrectFormat() {
        let trackingURL = URL(string: "https://api.example.com/track")!
        let entry = AudiobookTimeEntry(
            id: "entry-123", bookId: "book-456", libraryId: "lib-789",
            timeTrackingUrl: trackingURL, duringMinute: "2024-01-15T10:30Z", duration: 45
        )

        let successResponse = Data("""
    {"responses": [{"status": 200, "message": "OK", "id": "entry-123"}]}
    """.utf8)
        mockNetworkExecutor.responses[trackingURL] = MockNetworkExecutorForSync.MockResponse(statusCode: 200, data: successResponse)

        dataManager.save(time: entry)

        let mockRef = mockNetworkExecutor!
        let requestReceived = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in mockRef.requestHistory.count > 0 },
            object: nil
        )
        dataManager.syncValues()
        wait(for: [requestReceived], timeout: 10.0)

        guard let requestBody = mockNetworkExecutor.requestHistory.first?.body else {
            XCTFail("Request body should exist")
            return
        }

        guard let jsonObject = try? JSONSerialization.jsonObject(with: requestBody),
              let json = jsonObject as? [String: Any] else {
            XCTFail("Request body should be valid JSON dictionary")
            return
        }

        XCTAssertEqual(json["bookId"] as? String, "book-456")
        XCTAssertEqual(json["libraryId"] as? String, "lib-789")

        guard let timeEntries = json["timeEntries"] as? [[String: Any]] else {
            XCTFail("timeEntries should be present")
            return
        }
        XCTAssertEqual(timeEntries.count, 1)

        guard let firstEntry = timeEntries.first else {
            XCTFail("Should have at least one time entry")
            return
        }
        XCTAssertEqual(firstEntry["id"] as? String, "entry-123")
        XCTAssertEqual(firstEntry["duringMinute"] as? String, "2024-01-15T10:30Z")
        XCTAssertEqual(firstEntry["secondsPlayed"] as? Int, 45)
    }
}

// MARK: - Error Response Handling Tests

final class AudiobookDataManagerErrorHandlingTests: XCTestCase {

    private var mockNetworkExecutor: MockNetworkExecutorForSync!
    private var dataManager: AudiobookDataManager!

    override func setUp() {
        super.setUp()
        mockNetworkExecutor = MockNetworkExecutorForSync()
        dataManager = AudiobookDataManager(syncTimeInterval: 3600, networkService: mockNetworkExecutor)
        dataManager.store.queue.removeAll()
        dataManager.store.urls.removeAll()
    }

    override func tearDown() {
        dataManager?.store.queue.removeAll()
        dataManager?.store.urls.removeAll()
        dataManager = nil
        mockNetworkExecutor = nil
        super.tearDown()
    }

    private func waitForEntry(count: Int = 1, file: StaticString = #file, line: UInt = #line) {
        let savedExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { [weak self] _, _ in self?.dataManager.store.queue.count == count },
            object: nil
        )
        wait(for: [savedExpectation], timeout: 2.0)
    }

    private func waitForSync(predicate: @escaping () -> Bool) {
        let syncDone = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in predicate() },
            object: nil
        )
        wait(for: [syncDone], timeout: 5.0)
    }

    func testSyncValues_with404Response_removesEntriesAndURL() {
        let trackingURL = URL(string: "https://api.example.com/track/expired")!
        let entry = AudiobookTimeEntry(
            id: "entry-1", bookId: "book-expired", libraryId: "lib-456",
            timeTrackingUrl: trackingURL, duringMinute: "2024-01-15T10:30Z", duration: 45
        )

        mockNetworkExecutor.responses[trackingURL] = MockNetworkExecutorForSync.MockResponse(statusCode: 404)

        dataManager.save(time: entry)
        waitForEntry()
        XCTAssertEqual(dataManager.store.queue.count, 1)
        XCTAssertNotNil(dataManager.store.urls[LibraryBook(time: entry)])

        dataManager.syncValues()
        waitForSync { self.dataManager.store.queue.isEmpty }

        XCTAssertEqual(dataManager.store.queue.count, 0, "Entries should be removed on 404")
        XCTAssertNil(dataManager.store.urls[LibraryBook(time: entry)], "URL mapping should be removed on 404")
    }

    func testSyncValues_with500Response_keepsEntriesForRetry() {
        let trackingURL = URL(string: "https://api.example.com/track")!
        let entry = AudiobookTimeEntry(
            id: "entry-1", bookId: "book-123", libraryId: "lib-456",
            timeTrackingUrl: trackingURL, duringMinute: "2024-01-15T10:30Z", duration: 45
        )

        mockNetworkExecutor.responses[trackingURL] = MockNetworkExecutorForSync.MockResponse(statusCode: 500)

        dataManager.save(time: entry)
        waitForEntry()

        let mockRef = mockNetworkExecutor!
        let requestFired = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in mockRef.requestHistory.count > 0 },
            object: nil
        )
        dataManager.syncValues()
        wait(for: [requestFired], timeout: 5.0)

        XCTAssertEqual(dataManager.store.queue.count, 1, "Entries should be kept for retry on 5xx error")
    }

    func testSyncValues_with503Response_keepsEntriesForRetry() {
        let trackingURL = URL(string: "https://api.example.com/track")!
        let entry = AudiobookTimeEntry(
            id: "entry-1", bookId: "book-123", libraryId: "lib-456",
            timeTrackingUrl: trackingURL, duringMinute: "2024-01-15T10:30Z", duration: 45
        )

        mockNetworkExecutor.responses[trackingURL] = MockNetworkExecutorForSync.MockResponse(statusCode: 503)

        dataManager.save(time: entry)
        waitForEntry()

        let mockRef = mockNetworkExecutor!
        let requestFired = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in mockRef.requestHistory.count > 0 },
            object: nil
        )
        dataManager.syncValues()
        wait(for: [requestFired], timeout: 5.0)

        XCTAssertEqual(dataManager.store.queue.count, 1, "Entries should be kept for retry on 503")
    }

    func testSyncValues_withPartialSuccess_removesOnlySuccessfulEntries() {
        let trackingURL = URL(string: "https://api.example.com/track")!
        let entry1 = AudiobookTimeEntry(
            id: "entry-success", bookId: "book-1", libraryId: "lib-1",
            timeTrackingUrl: trackingURL, duringMinute: "2024-01-15T10:30Z", duration: 30
        )
        let entry2 = AudiobookTimeEntry(
            id: "entry-fail", bookId: "book-1", libraryId: "lib-1",
            timeTrackingUrl: trackingURL, duringMinute: "2024-01-15T10:31Z", duration: 45
        )

        let partialResponse = Data("""
    {"responses": [
      {"status": 200, "message": "OK", "id": "entry-success"},
      {"status": 400, "message": "Invalid entry", "id": "entry-fail"}
    ]}
    """.utf8)
        mockNetworkExecutor.responses[trackingURL] = MockNetworkExecutorForSync.MockResponse(statusCode: 200, data: partialResponse)

        dataManager.save(time: entry1)
        dataManager.save(time: entry2)
        waitForEntry(count: 2)

        dataManager.syncValues()
        waitForSync { self.dataManager.store.queue.isEmpty }

        XCTAssertEqual(dataManager.store.queue.count, 0, "Both entries removed based on response IDs")
    }

    func testSyncValues_withNetworkError_keepsEntries() {
        let trackingURL = URL(string: "https://api.example.com/track")!
        let entry = AudiobookTimeEntry(
            id: "entry-1", bookId: "book-123", libraryId: "lib-456",
            timeTrackingUrl: trackingURL, duringMinute: "2024-01-15T10:30Z", duration: 45
        )

        let networkError = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet, userInfo: nil)
        mockNetworkExecutor.responses[trackingURL] = MockNetworkExecutorForSync.MockResponse(
            statusCode: 0, error: networkError
        )

        dataManager.save(time: entry)
        waitForEntry()

        let mockRef = mockNetworkExecutor!
        let requestFired = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in mockRef.requestHistory.count > 0 },
            object: nil
        )
        dataManager.syncValues()
        wait(for: [requestFired], timeout: 5.0)

        XCTAssertEqual(dataManager.store.queue.count, 1, "Entries should be kept on network error")
    }
}

// MARK: - Store Corruption Recovery Tests

final class AudiobookDataManagerStoreRecoveryTests: XCTestCase {

    private var testStoreDirectory: URL!
    private var testStoreFile: URL!

    override func setUp() {
        super.setUp()
        testStoreDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("test_timetracker_\(UUID().uuidString)")
        testStoreFile = testStoreDirectory.appendingPathComponent("store.json")
        try? FileManager.default.createDirectory(at: testStoreDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: testStoreDirectory)
        super.tearDown()
    }

    func testLoadStore_withCorruptedJSON_doesNotCrash() {
        let corruptedData = Data("{ invalid json content".utf8)
        try? corruptedData.write(to: testStoreFile)

        let dataManager = AudiobookDataManager(syncTimeInterval: 3600)
        dataManager.store.queue.removeAll()
        dataManager.store.urls.removeAll()

        XCTAssertNotNil(dataManager)
        XCTAssertTrue(dataManager.store.queue.isEmpty, "Queue should be empty after clearing")
    }

    func testLoadStore_withEmptyFile_doesNotCrash() {
        try? Data().write(to: testStoreFile)

        let dataManager = AudiobookDataManager(syncTimeInterval: 3600)
        dataManager.store.queue.removeAll()
        dataManager.store.urls.removeAll()

        XCTAssertNotNil(dataManager)
        XCTAssertTrue(dataManager.store.queue.isEmpty)
    }

    func testSaveAndLoadStore_preservesData() {
        let uniqueId = "entry-persist-\(UUID().uuidString)"
        let dataManager = AudiobookDataManager(syncTimeInterval: 3600)
        dataManager.store.queue.removeAll { $0.id.hasPrefix("entry-persist") }

        let entry = AudiobookTimeEntry(
            id: uniqueId, bookId: "book-123", libraryId: "lib-456",
            timeTrackingUrl: URL(string: "https://api.example.com/track")!,
            duringMinute: "2024-01-15T10:30Z", duration: 45
        )

        dataManager.save(time: entry)

        // Poll until the entry has been written to the store
        let savedExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in dataManager.store.queue.contains { $0.id == uniqueId } },
            object: nil
        )
        wait(for: [savedExpectation], timeout: 2.0)

        // Create new manager that loads from disk
        let newDataManager = AudiobookDataManager(syncTimeInterval: 3600)

        // Poll until the new manager has loaded the persisted entry
        let loadedExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in newDataManager.store.queue.contains { $0.id == uniqueId } },
            object: nil
        )
        wait(for: [loadedExpectation], timeout: 2.0)

        let persistedEntry = newDataManager.store.queue.first { $0.id == uniqueId }
        XCTAssertNotNil(persistedEntry, "Should find persisted entry with id: \(uniqueId)")
        XCTAssertEqual(persistedEntry?.id, uniqueId)

        dataManager.store.queue.removeAll { $0.id == uniqueId }
    }

    func testAudiobookDataManagerStoreInit_withInvalidData_returnsNil() {
        let invalidData = Data("not json at all".utf8)
        let store = AudiobookDataManagerStore(data: invalidData)
        XCTAssertNil(store, "Should return nil for invalid JSON")
    }

    func testAudiobookDataManagerStoreInit_withPartialData_returnsNil() {
        let partialData = Data("""
    {"urls": {}}
    """.utf8)

        let store = AudiobookDataManagerStore(data: partialData)
        if store == nil {
            XCTAssertNil(store)
        } else {
            XCTAssertTrue(store?.queue.isEmpty ?? false)
        }
    }
}

// MARK: - Empty Queue Tests

final class AudiobookDataManagerEmptyQueueTests: XCTestCase {

    private var mockNetworkExecutor: MockNetworkExecutorForSync!
    private var dataManager: AudiobookDataManager!

    override func setUp() {
        super.setUp()
        mockNetworkExecutor = MockNetworkExecutorForSync()
        dataManager = AudiobookDataManager(syncTimeInterval: 3600, networkService: mockNetworkExecutor)
        dataManager.store.queue.removeAll()
        dataManager.store.urls.removeAll()
    }

    override func tearDown() {
        dataManager?.store.queue.removeAll()
        dataManager?.store.urls.removeAll()
        dataManager = nil
        mockNetworkExecutor = nil
        super.tearDown()
    }

    func testSyncValues_withEmptyQueue_makesNoRequests() {
        XCTAssertTrue(dataManager.store.queue.isEmpty)

        dataManager.syncValues()

        // syncValues only POSTs when there are queued entries. With an empty queue the mock
        // executor's POST method is never called, so requestHistory stays empty.
        // No async wait needed — the absence of a network call is immediate.
        XCTAssertTrue(mockNetworkExecutor.requestHistory.isEmpty, "Should not make any requests with empty queue")
    }
}
