//
//  AudiobookFileLoggerTests.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

@MainActor
final class AudiobookFileLoggerTests: XCTestCase {

    // SUT and test-local logs root — injected via init to isolate from
    // production `.shared` global state and parallel-test pollution.
    private var sut: AudiobookFileLogger!
    private var testLogsRoot: URL!
    private var testBookId: String!

    override func setUp() {
        super.setUp()
        testLogsRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-audiobook-logs-\(UUID().uuidString)")
        sut = AudiobookFileLogger(logsRootURL: testLogsRoot)
        testBookId = "test-audiobook-\(UUID().uuidString)"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: testLogsRoot)
        sut = nil
        testLogsRoot = nil
        testBookId = nil
        super.tearDown()
    }

    // MARK: - Init injection seam

    /// Replaces the `testShared_isNotNil` tautology. Pins the new ctor
    /// surface: a custom logs URL is what `getLogsDirectoryUrl()` returns,
    /// AND a file written through `logEvent` lands at that URL — proving
    /// the override is wired all the way through, not just stored.
    func testInit_withCustomLogsRoot_usesProvidedDirectory() {
        let resolved = sut.getLogsDirectoryUrl()
        XCTAssertEqual(
            resolved?.standardizedFileURL,
            testLogsRoot.standardizedFileURL,
            "Custom logsRootURL must be returned verbatim by getLogsDirectoryUrl()"
        )

        sut.logEvent(forBookId: testBookId, event: "init-injection probe")
        let written = testLogsRoot.appendingPathComponent("\(testBookId!).log")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: written.path),
            "logEvent must write into the injected directory, not the default Documents path"
        )
    }

    // MARK: - Logs Directory

    func testGetLogsDirectoryUrl_returnsURL() {
        let url = sut.getLogsDirectoryUrl()
        XCTAssertNotNil(url, "Logs directory URL should not be nil")
        if let url = url {
            XCTAssertTrue(url.isFileURL, "Logs directory URL must be a file URL")
            // hasDirectoryPath depends on trailing-slash presence in the URL
            // string, which the override path may not carry. The behavior
            // we actually care about — that a directory exists on disk — is
            // exercised by `testGetLogsDirectoryUrl_directoryExists`.
        }
    }

    func testGetLogsDirectoryUrl_directoryExists() {
        guard let url = sut.getLogsDirectoryUrl() else {
            XCTFail("Logs directory URL is nil")
            return
        }

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        XCTAssertTrue(exists, "Logs directory should exist")
        XCTAssertTrue(isDirectory.boolValue, "Should be a directory")
    }

    // MARK: - Log Events

    func testLogEvent_createsLogFile() {
        sut.logEvent(forBookId: testBookId, event: "Test playback started")

        let log = sut.retrieveLog(forBookId: testBookId)
        XCTAssertNotNil(log, "Log should be retrievable after logging an event")
        XCTAssertTrue(log!.contains("Test playback started"))
    }

    func testLogEvent_multipleEvents_allAppear() {
        sut.logEvent(forBookId: testBookId, event: "Event 1")
        sut.logEvent(forBookId: testBookId, event: "Event 2")
        sut.logEvent(forBookId: testBookId, event: "Event 3")

        let log = sut.retrieveLog(forBookId: testBookId)
        XCTAssertNotNil(log)
        XCTAssertTrue(log!.contains("Event 1"))
        XCTAssertTrue(log!.contains("Event 2"))
        XCTAssertTrue(log!.contains("Event 3"))
    }

    // MARK: - Retrieve Logs

    func testRetrieveLog_nonexistentBook_returnsNil() {
        let nonExistentId = "nonexistent-book-\(UUID().uuidString)"
        let log = sut.retrieveLog(forBookId: nonExistentId)
        XCTAssertNil(log)
        // Retrieving a second unknown id must also return nil (no shared state between IDs)
        let anotherMissingId = "another-nonexistent-\(UUID().uuidString)"
        XCTAssertNil(sut.retrieveLog(forBookId: anotherMissingId),
                     "Any unknown book ID must return nil log")
    }

    func testRetrieveLogs_multipleBooks() {
        let bookId1 = "test-book-1-\(UUID().uuidString)"
        let bookId2 = "test-book-2-\(UUID().uuidString)"

        sut.logEvent(forBookId: bookId1, event: "Book 1 event")
        sut.logEvent(forBookId: bookId2, event: "Book 2 event")

        let logs = sut.retrieveLogs(forBookIds: [bookId1, bookId2])

        XCTAssertNotNil(logs[bookId1])
        XCTAssertNotNil(logs[bookId2])
        XCTAssertTrue(logs[bookId1]!.contains("Book 1 event"))
        XCTAssertTrue(logs[bookId2]!.contains("Book 2 event"))
    }

    func testRetrieveLogs_emptyBookIds_returnsEmptyDict() {
        let logs = sut.retrieveLogs(forBookIds: [])
        XCTAssertTrue(logs.isEmpty, "Empty ID list must produce empty result dictionary")
        XCTAssertEqual(logs.count, 0, "Result must have zero entries for empty input")
    }

    // MARK: - Log Content Format

    func testLogEvent_containsTimestamp() {
        sut.logEvent(forBookId: testBookId, event: "Timestamp test")

        let log = sut.retrieveLog(forBookId: testBookId)
        XCTAssertNotNil(log)

        // Logs should contain a date/time component
        let currentYear = Calendar.current.component(.year, from: Date())
        XCTAssertTrue(log!.contains("\(currentYear)"), "Log should contain current year in timestamp")
    }

    // MARK: - New edge-case tests enabled by isolation

    /// Concurrent writes to the same book file: the singleton-coupled
    /// version of this test could not exist (cross-test pollution).
    /// `cleanupOldLogsIfNeeded` + `FileHandle` writes happen under no lock,
    /// so this is a genuine probe — but each event is at least one
    /// distinct line, so even with last-writer-wins the COUNT-of-distinct
    /// markers we see is the live behaviour we want to pin.
    func testLogEvent_concurrentWritesToSameBook_atLeastSomeEventsAppear() {
        let writeCount = 50
        DispatchQueue.concurrentPerform(iterations: writeCount) { index in
            sut.logEvent(forBookId: testBookId, event: "marker-\(index)-payload")
        }

        let log = sut.retrieveLog(forBookId: testBookId) ?? ""
        // We can't promise all 50 land (no internal lock), but the file must
        // exist and contain more than one event — a mutant that no-ops
        // logEvent or only writes the first call would fail.
        let markerHits = (0..<writeCount).filter { log.contains("marker-\($0)-payload") }.count
        XCTAssertGreaterThanOrEqual(
            markerHits, 2,
            "Concurrent writes must persist at least 2 distinct events; got \(markerHits)"
        )
    }

    /// `retrieveLog` truncates content above 1MB and prepends a marker.
    /// Singleton-bound test couldn't write 1.5MB reliably (file would leak
    /// across tests). With injected dir, this is hermetic.
    func testRetrieveLog_truncatesAbove1MBAndPrependsMarker() {
        guard let logsDir = sut.getLogsDirectoryUrl() else {
            XCTFail("logs directory unavailable")
            return
        }

        // Write 1.5MB of `A` characters directly to bypass the 2MB rotate-on-write
        // path. The retrieve path's 1MB truncation triggers when fileSize > 1_000_000.
        let bigPayload = String(repeating: "A", count: 1_500_000)
        let target = logsDir.appendingPathComponent("\(testBookId!).log")
        try? bigPayload.write(to: target, atomically: true, encoding: .utf8)

        guard let log = sut.retrieveLog(forBookId: testBookId) else {
            XCTFail("retrieveLog returned nil for known oversized file")
            return
        }
        XCTAssertTrue(
            log.hasPrefix("...[truncated"),
            "Oversized retrieval must be prefixed with truncation marker; got prefix: \(String(log.prefix(40)))"
        )
        XCTAssertLessThanOrEqual(
            log.utf8.count, 1_000_000 + 100,
            "Truncated payload must fit inside ~1MB + the prefix marker"
        )
    }

    /// Pins the EXACT 1MB truncation boundary in `retrieveLog`. At
    /// exactly 1,000,000 bytes the `>` comparison must be false (no
    /// truncation, returns full file). A `>=` mutant would incorrectly
    /// truncate, yielding the "...[truncated" prefix.
    func testRetrieveLog_atExact1MBBoundary_doesNotTruncate() {
        guard let logsDir = sut.getLogsDirectoryUrl() else {
            XCTFail("logs directory unavailable")
            return
        }
        // Write EXACTLY 1,000,000 bytes (the maxLogSize cap).
        let payload = String(repeating: "B", count: 1_000_000)
        let target = logsDir.appendingPathComponent("\(testBookId!).log")
        try? payload.write(to: target, atomically: true, encoding: .utf8)
        // Verify file is exactly the boundary size.
        let actualSize = (try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int64) ?? -1
        XCTAssertEqual(actualSize, 1_000_000, "Precondition: file must be exactly 1MB")

        let log = sut.retrieveLog(forBookId: testBookId)
        XCTAssertNotNil(log)
        XCTAssertFalse(log?.hasPrefix("...[truncated") ?? true,
                       "At exactly 1MB the > comparison is false; no truncation marker should appear")
        XCTAssertEqual(log?.count, 1_000_000,
                       "Full 1MB payload must be returned unchanged at the boundary")
    }

    /// Pins the EXACT 2MB rotation boundary in `logEvent`. At exactly
    /// 2,000,000 bytes the `fileSize > maxLogFileSize` is false (no
    /// rotation; append in place). A `>=` mutant would erroneously
    /// rotate, dropping the existing content under the "previous log
    /// truncated" prefix.
    func testLogEvent_atExact2MBBoundary_appendsRatherThanRotates() {
        guard let logsDir = sut.getLogsDirectoryUrl() else {
            XCTFail("logs directory unavailable")
            return
        }
        // Seed file at exactly 2MB.
        let payload = String(repeating: "C", count: 2_000_000)
        let target = logsDir.appendingPathComponent("\(testBookId!).log")
        try? payload.write(to: target, atomically: true, encoding: .utf8)
        let preSize = (try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int64) ?? -1
        XCTAssertEqual(preSize, 2_000_000, "Precondition: seed file must be exactly 2MB")

        sut.logEvent(forBookId: testBookId, event: "boundary-append-marker")

        let log = sut.retrieveLog(forBookId: testBookId) ?? ""
        XCTAssertFalse(log.contains("previous log truncated"),
                       "At exactly 2MB rotation must NOT trigger; truncation marker indicates a > → >= mutation")
        XCTAssertTrue(log.contains("boundary-append-marker"),
                      "New event must be appended (not start a fresh file) when file is exactly at limit")
    }

    /// `cleanupOldLogsIfNeeded` deletes the OLDEST file first once total
    /// disk use exceeds 10MB. Build > 10MB across multiple books, then
    /// trigger cleanup by logging one more event. The first-written file
    /// (oldest mtime) must be gone.
    func testCleanup_whenOverSizeLimit_deletesOldestFileFirst() {
        guard let logsDir = sut.getLogsDirectoryUrl() else {
            XCTFail("logs directory unavailable")
            return
        }

        let oldestBook = "book-oldest-\(UUID().uuidString)"
        let chunk = String(repeating: "Z", count: 2_500_000) // 2.5MB
        // Write 5 files of 2.5MB each = 12.5MB > 10MB cap.
        for idx in 0..<5 {
            let bookId = idx == 0 ? oldestBook : "book-\(idx)-\(UUID().uuidString)"
            let target = logsDir.appendingPathComponent("\(bookId).log")
            try? chunk.write(to: target, atomically: true, encoding: .utf8)
            // Force a distinct mtime so the oldest is unambiguous.
            let backdate = Date(timeIntervalSinceNow: Double(-100 + idx))
            try? FileManager.default.setAttributes(
                [.modificationDate: backdate],
                ofItemAtPath: target.path
            )
        }

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: logsDir.appendingPathComponent("\(oldestBook).log").path),
            "Precondition: oldest file must exist before cleanup is triggered"
        )

        // Trigger cleanup via a new logEvent call.
        sut.logEvent(forBookId: "trigger-\(UUID().uuidString)", event: "cleanup trigger")

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: logsDir.appendingPathComponent("\(oldestBook).log").path),
            "Cleanup must delete the oldest log file once total size > 10MB"
        )
    }
}
