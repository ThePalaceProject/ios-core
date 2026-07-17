//
//  DownloadTaskPersistenceTests.swift
//  PalaceTests
//
//  Reliability WS-A — durable download-record store (seam S1): Codable
//  round-trip, upsert-by-bookID, removal, and the DownloadStateManager
//  passthrough + terminal-cleanup contract.
//

import XCTest
@testable import Palace

@MainActor
final class DownloadTaskPersistenceTests: XCTestCase {

    private var tempURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DownloadTaskPersistence-\(UUID().uuidString).json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempURL)
        tempURL = nil
        try super.tearDownWithError()
    }

    private func rec(_ bookID: String, task: Int) -> PersistedDownloadRecord {
        PersistedDownloadRecord(
            bookID: bookID,
            taskIdentifier: task,
            downloadURL: URL(string: "https://example.org/\(bookID)")!,
            account: "acct",
            expectedBytes: 4_096,
            startedAt: Date(timeIntervalSince1970: 1_700_000_123)
        )
    }

    // MARK: - Codable round-trip

    func testRecord_encodeDecode_roundTripsAllFields() throws {
        let original = rec("book-42", task: 17)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PersistedDownloadRecord.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.bookID, "book-42")
        XCTAssertEqual(decoded.taskIdentifier, 17)
        XCTAssertEqual(decoded.expectedBytes, 4_096)
        XCTAssertEqual(decoded.downloadURL, URL(string: "https://example.org/book-42")!)
    }

    func testRecord_nilExpectedBytes_roundTrips() throws {
        let original = PersistedDownloadRecord(
            bookID: "b", taskIdentifier: 1,
            downloadURL: URL(string: "https://x.test/b")!,
            account: "a", expectedBytes: nil, startedAt: Date(timeIntervalSince1970: 0))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PersistedDownloadRecord.self, from: data)
        XCTAssertNil(decoded.expectedBytes)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - Store CRUD

    func testStore_recordThenAll_returnsPersistedAcrossFreshInstances() {
        let store = DownloadTaskPersistence(fileURL: tempURL)
        store.record(rec("b1", task: 1))
        store.record(rec("b2", task: 2))

        // A brand-new instance reads the SAME file -> durability.
        let reopened = DownloadTaskPersistence(fileURL: tempURL)
        let all = reopened.all().sorted { $0.taskIdentifier < $1.taskIdentifier }
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all.map(\.bookID), ["b1", "b2"])
    }

    func testStore_recordSameBookTwice_upsertsNotDuplicates() {
        let store = DownloadTaskPersistence(fileURL: tempURL)
        store.record(rec("b1", task: 1))
        store.record(rec("b1", task: 99)) // same bookID, new task

        let all = store.all()
        XCTAssertEqual(all.count, 1, "upsert by bookID must not duplicate")
        XCTAssertEqual(all.first?.taskIdentifier, 99, "latest record wins")
    }

    func testStore_remove_dropsOnlyThatBook() {
        let store = DownloadTaskPersistence(fileURL: tempURL)
        store.record(rec("b1", task: 1))
        store.record(rec("b2", task: 2))

        store.remove(bookID: "b1")

        let all = store.all()
        XCTAssertEqual(all.map(\.bookID), ["b2"])
    }

    func testStore_removeAbsent_isNoOp() {
        let store = DownloadTaskPersistence(fileURL: tempURL)
        store.record(rec("b1", task: 1))
        store.remove(bookID: "does-not-exist")
        XCTAssertEqual(store.all().count, 1)
    }

    func testStore_removeAll_empties() {
        let store = DownloadTaskPersistence(fileURL: tempURL)
        store.record(rec("b1", task: 1))
        store.record(rec("b2", task: 2))
        store.removeAll()
        XCTAssertTrue(store.all().isEmpty)
    }

    func testStore_missingFile_returnsEmptyNotCrash() {
        let store = DownloadTaskPersistence(fileURL: tempURL) // file never written
        XCTAssertTrue(store.all().isEmpty)
    }

    func testStore_corruptFile_returnsEmptyNotCrash() throws {
        try Data("not json {{{".utf8).write(to: tempURL)
        let store = DownloadTaskPersistence(fileURL: tempURL)
        XCTAssertTrue(store.all().isEmpty, "corrupt store must degrade to empty, never crash launch")
    }

    // MARK: - DownloadStateManager passthrough

    func testStateManager_persistStartedTask_thenList() {
        let store = DownloadTaskPersistence(fileURL: tempURL)
        let manager = DownloadStateManager(taskPersistence: store)

        manager.persistStartedTask(
            bookID: "sm-book", taskIdentifier: 5,
            downloadURL: URL(string: "https://x.test/sm-book")!,
            account: "a", expectedBytes: 10)

        let records = manager.persistedRecords()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.bookID, "sm-book")
        XCTAssertEqual(records.first?.taskIdentifier, 5)
    }

    func testStateManager_removePersistedRecord() {
        let store = DownloadTaskPersistence(fileURL: tempURL)
        let manager = DownloadStateManager(taskPersistence: store)
        manager.persistStartedTask(bookID: "x", taskIdentifier: 1,
            downloadURL: URL(string: "https://x.test/x")!, account: "a", expectedBytes: nil)

        manager.removePersistedRecord(for: "x")

        XCTAssertTrue(manager.persistedRecords().isEmpty)
    }

    func testStateManager_cleanupDownload_alsoDropsPersistedRecord() async {
        let store = DownloadTaskPersistence(fileURL: tempURL)
        let manager = DownloadStateManager(taskPersistence: store)
        manager.persistStartedTask(bookID: "c", taskIdentifier: 8,
            downloadURL: URL(string: "https://x.test/c")!, account: "a", expectedBytes: nil)

        await manager.cleanupDownload(for: "c", taskIdentifier: 8)

        XCTAssertTrue(manager.persistedRecords().isEmpty,
                      "terminal cleanup must drop the durable record so it isn't restarted next launch")
    }

    func testStateManager_resetAll_clearsPersistence() async {
        let store = DownloadTaskPersistence(fileURL: tempURL)
        let manager = DownloadStateManager(taskPersistence: store)
        manager.persistStartedTask(bookID: "r", taskIdentifier: 2,
            downloadURL: URL(string: "https://x.test/r")!, account: "a", expectedBytes: nil)

        await manager.resetAll()

        XCTAssertTrue(manager.persistedRecords().isEmpty)
    }

    // MARK: - Transfer-retry counters

    func testStateManager_transferRetryCounter_incrementsAndResets() async {
        let manager = DownloadStateManager(taskPersistence: DownloadTaskPersistence(fileURL: tempURL))
        let start = await manager.transferRetryAttempts(for: "t")
        XCTAssertEqual(start, 0)

        await manager.incrementTransferRetryAttempts(for: "t")
        await manager.incrementTransferRetryAttempts(for: "t")
        let after = await manager.transferRetryAttempts(for: "t")
        XCTAssertEqual(after, 2)

        await manager.resetTransferRetryAttempts(for: "t")
        let reset = await manager.transferRetryAttempts(for: "t")
        XCTAssertEqual(reset, 0)
    }
}
