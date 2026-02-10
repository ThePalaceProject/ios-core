//
//  AudiobookFileLoggerTests.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class AudiobookFileLoggerTests: XCTestCase {

  private let testBookId = "test-audiobook-\(UUID().uuidString)"

  override func tearDown() {
    // Clean up test logs
    if let logsDir = AudiobookFileLogger.shared.getLogsDirectoryUrl() {
      let testLogFile = logsDir.appendingPathComponent("\(testBookId).log")
      try? FileManager.default.removeItem(at: testLogFile)
    }
    super.tearDown()
  }

  // MARK: - Shared Instance

  func testShared_isNotNil() {
    XCTAssertNotNil(AudiobookFileLogger.shared)
  }

  // MARK: - Logs Directory

  func testGetLogsDirectoryUrl_returnsURL() {
    let url = AudiobookFileLogger.shared.getLogsDirectoryUrl()
    XCTAssertNotNil(url, "Logs directory URL should not be nil")
  }

  func testGetLogsDirectoryUrl_directoryExists() {
    guard let url = AudiobookFileLogger.shared.getLogsDirectoryUrl() else {
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
    AudiobookFileLogger.shared.logEvent(forBookId: testBookId, event: "Test playback started")

    let log = AudiobookFileLogger.shared.retrieveLog(forBookId: testBookId)
    XCTAssertNotNil(log, "Log should be retrievable after logging an event")
    XCTAssertTrue(log!.contains("Test playback started"))
  }

  func testLogEvent_multipleEvents_allAppear() {
    AudiobookFileLogger.shared.logEvent(forBookId: testBookId, event: "Event 1")
    AudiobookFileLogger.shared.logEvent(forBookId: testBookId, event: "Event 2")
    AudiobookFileLogger.shared.logEvent(forBookId: testBookId, event: "Event 3")

    let log = AudiobookFileLogger.shared.retrieveLog(forBookId: testBookId)
    XCTAssertNotNil(log)
    XCTAssertTrue(log!.contains("Event 1"))
    XCTAssertTrue(log!.contains("Event 2"))
    XCTAssertTrue(log!.contains("Event 3"))
  }

  // MARK: - Retrieve Logs

  func testRetrieveLog_nonexistentBook_returnsNil() {
    let log = AudiobookFileLogger.shared.retrieveLog(forBookId: "nonexistent-book-\(UUID().uuidString)")
    XCTAssertNil(log)
  }

  func testRetrieveLogs_multipleBooks() {
    let bookId1 = "test-book-1-\(UUID().uuidString)"
    let bookId2 = "test-book-2-\(UUID().uuidString)"

    AudiobookFileLogger.shared.logEvent(forBookId: bookId1, event: "Book 1 event")
    AudiobookFileLogger.shared.logEvent(forBookId: bookId2, event: "Book 2 event")

    let logs = AudiobookFileLogger.shared.retrieveLogs(forBookIds: [bookId1, bookId2])

    XCTAssertNotNil(logs[bookId1])
    XCTAssertNotNil(logs[bookId2])
    XCTAssertTrue(logs[bookId1]!.contains("Book 1 event"))
    XCTAssertTrue(logs[bookId2]!.contains("Book 2 event"))

    // Cleanup
    if let logsDir = AudiobookFileLogger.shared.getLogsDirectoryUrl() {
      try? FileManager.default.removeItem(at: logsDir.appendingPathComponent("\(bookId1).log"))
      try? FileManager.default.removeItem(at: logsDir.appendingPathComponent("\(bookId2).log"))
    }
  }

  func testRetrieveLogs_emptyBookIds_returnsEmptyDict() {
    let logs = AudiobookFileLogger.shared.retrieveLogs(forBookIds: [])
    XCTAssertTrue(logs.isEmpty)
  }

  // MARK: - Log Content Format

  func testLogEvent_containsTimestamp() {
    AudiobookFileLogger.shared.logEvent(forBookId: testBookId, event: "Timestamp test")

    let log = AudiobookFileLogger.shared.retrieveLog(forBookId: testBookId)
    XCTAssertNotNil(log)

    // Logs should contain a date/time component
    let currentYear = Calendar.current.component(.year, from: Date())
    XCTAssertTrue(log!.contains("\(currentYear)"), "Log should contain current year in timestamp")
  }
}
