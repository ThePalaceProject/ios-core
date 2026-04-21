//
//  AudiobookEventsTests.swift
//  PalaceTests
//
//  AudiobookDataManager save-queue tests. The former AudiobookEvents
//  publish/subscribe tests were removed alongside the AudiobookEvents
//  global pub/sub — audiobook lifecycle is now owned directly by
//  AudiobookSessionManager (see AudiobookLoader + AudiobookSessionManager).
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

// MARK: - AudiobookDataManager Save Tests

/// SRS: AUDIO-004 -- Time entries are queued and persisted correctly
final class AudiobookDataManagerSaveTests: XCTestCase {

    override func setUp() {
        super.setUp()
        if let dir = TPPBookContentMetadataFilesHelper.directory(for: "timetracker") {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("store.json"))
        }
    }

    override func tearDown() {
        if let dir = TPPBookContentMetadataFilesHelper.directory(for: "timetracker") {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("store.json"))
        }
        super.tearDown()
    }

    /// SRS: AUDIO-004 -- Time entries are queued and persisted correctly
    func testSave_addsEntryToQueue() {
        let dataManager = AudiobookDataManager(syncTimeInterval: 3600)
        dataManager.store.queue.removeAll()
        dataManager.store.urls.removeAll()

        let entry = AudiobookTimeEntry(
            id: "save-test-\(UUID().uuidString)",
            bookId: "book-save",
            libraryId: "lib-save",
            timeTrackingUrl: URL(string: "https://example.com/track")!,
            duringMinute: "2026-01-01T00:00Z",
            duration: 30
        )

        dataManager.save(time: entry)

        // Wait for async barrier write
        let expectation = XCTestExpectation(description: "Save completes")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)

        XCTAssertTrue(dataManager.store.queue.contains(where: { $0.id == entry.id }),
                       "Entry should be in the queue after save")

        // Cleanup
        dataManager.store.queue.removeAll { $0.id == entry.id }
    }

    /// SRS: AUDIO-004 -- Time entries are queued and persisted correctly
    func testSave_storesURLMapping() {
        let dataManager = AudiobookDataManager(syncTimeInterval: 3600)
        dataManager.store.queue.removeAll()
        dataManager.store.urls.removeAll()

        let trackingURL = URL(string: "https://example.com/track-url")!
        let entry = AudiobookTimeEntry(
            id: "url-test-\(UUID().uuidString)",
            bookId: "book-url",
            libraryId: "lib-url",
            timeTrackingUrl: trackingURL,
            duringMinute: "2026-01-01T00:00Z",
            duration: 15
        )

        dataManager.save(time: entry)

        let expectation = XCTestExpectation(description: "Save completes")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)

        let libraryBook = LibraryBook(time: entry)
        XCTAssertEqual(dataManager.store.urls[libraryBook], trackingURL,
                        "URL mapping should be stored for the library book")

        // Cleanup
        dataManager.store.queue.removeAll { $0.id == entry.id }
        dataManager.store.urls.removeValue(forKey: libraryBook)
    }

    /// SRS: AUDIO-004 -- Time entries are queued and persisted correctly
    func testSave_multipleEntries_allQueued() {
        let dataManager = AudiobookDataManager(syncTimeInterval: 3600)
        dataManager.store.queue.removeAll()
        dataManager.store.urls.removeAll()

        let ids = (0..<5).map { "multi-\(UUID().uuidString)-\($0)" }
        for id in ids {
            let entry = AudiobookTimeEntry(
                id: id,
                bookId: "book-multi",
                libraryId: "lib-multi",
                timeTrackingUrl: URL(string: "https://example.com/track")!,
                duringMinute: "2026-01-01T00:00Z",
                duration: 10
            )
            dataManager.save(time: entry)
        }

        let expectation = XCTestExpectation(description: "Saves complete")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)

        for id in ids {
            XCTAssertTrue(dataManager.store.queue.contains(where: { $0.id == id }),
                           "Entry \(id) should be in queue")
        }

        // Cleanup
        for id in ids {
            dataManager.store.queue.removeAll { $0.id == id }
        }
    }

    /// SRS: AUDIO-004 -- Time entries are queued and persisted correctly
    func testDataManagerConformance_savesViaProtocol() {
        let dataManager = AudiobookDataManager(syncTimeInterval: 3600)
        dataManager.store.queue.removeAll()

        let entry = AudiobookTimeEntry(
            id: "protocol-test-\(UUID().uuidString)",
            bookId: "book-proto",
            libraryId: "lib-proto",
            timeTrackingUrl: URL(string: "https://example.com")!,
            duringMinute: "2026-03-01T00:00Z",
            duration: 20
        )

        // Call through the DataManager protocol
        let dm: DataManager = dataManager
        dm.save(time: entry)

        let expectation = XCTestExpectation(description: "Save completes")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)

        XCTAssertTrue(dataManager.store.queue.contains(where: { $0.id == entry.id }),
                       "Entry saved via protocol should be in queue")

        // Cleanup
        dataManager.store.queue.removeAll { $0.id == entry.id }
    }
}
