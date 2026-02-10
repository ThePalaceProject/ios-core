//
//  LogTests.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import os.log
@testable import Palace

final class LogTests: XCTestCase {

  // MARK: - Subsystem Tests

  func testSubsystem_isCorrectValue() {
    XCTAssertEqual(Log.subsystem, "org.thepalaceproject.palace")
  }

  func testSubsystem_isNotEmpty() {
    XCTAssertFalse(Log.subsystem.isEmpty, "Log subsystem should not be empty")
  }

  // MARK: - Log Level Tests

  func testDebug_doesNotCrash() {
    // Verify debug logging completes without error
    Log.debug("LogTests", "Debug test message")
  }

  func testInfo_doesNotCrash() {
    Log.info("LogTests", "Info test message")
  }

  func testWarn_doesNotCrash() {
    Log.warn("LogTests", "Warning test message")
  }

  func testError_doesNotCrash() {
    Log.error("LogTests", "Error test message")
  }

  func testFault_doesNotCrash() {
    Log.fault("LogTests", "Fault test message")
  }

  func testLog_objcCompatibility_doesNotCrash() {
    Log.log("ObjC compat test message")
  }

  // MARK: - Error Persistence Tests

  func testError_persistsToLogger() async {
    // Clear existing logs to start fresh
    await PersistentLogger.shared.clearLogs()

    // Log an error with a unique marker
    let marker = "PersistenceTest_\(UUID().uuidString)"
    Log.error("LogTests", marker)

    // Allow async Task to complete
    try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s

    // Retrieve persisted logs
    let logs = await PersistentLogger.shared.retrieveAllLogs()

    XCTAssertTrue(
      logs.contains(marker),
      "Error-level messages should be persisted to PersistentLogger"
    )
  }

  func testFault_persistsToLogger() async {
    await PersistentLogger.shared.clearLogs()

    let marker = "FaultPersistenceTest_\(UUID().uuidString)"
    Log.fault("LogTests", marker)

    try? await Task.sleep(nanoseconds: 500_000_000)

    let logs = await PersistentLogger.shared.retrieveAllLogs()

    XCTAssertTrue(
      logs.contains(marker),
      "Fault-level messages should be persisted to PersistentLogger"
    )
  }

  func testDebug_doesNotPersistToLogger() async {
    await PersistentLogger.shared.clearLogs()

    let marker = "DebugNoPersist_\(UUID().uuidString)"
    Log.debug("LogTests", marker)

    try? await Task.sleep(nanoseconds: 500_000_000)

    let logs = await PersistentLogger.shared.retrieveAllLogs()

    XCTAssertFalse(
      logs.contains(marker),
      "Debug-level messages should NOT be persisted to PersistentLogger"
    )
  }

  func testInfo_doesNotPersistToLogger() async {
    await PersistentLogger.shared.clearLogs()

    let marker = "InfoNoPersist_\(UUID().uuidString)"
    Log.info("LogTests", marker)

    try? await Task.sleep(nanoseconds: 500_000_000)

    let logs = await PersistentLogger.shared.retrieveAllLogs()

    XCTAssertFalse(
      logs.contains(marker),
      "Info-level messages should NOT be persisted to PersistentLogger"
    )
  }

  // MARK: - Tag Trimming Tests

  func testLog_withFilePathTag_trimsProperly() async {
    await PersistentLogger.shared.clearLogs()

    // Simulate the common pattern where #file is passed as tag
    let marker = "TagTrimTest_\(UUID().uuidString)"
    Log.error("/Users/dev/Projects/Palace/Logging/SomeFile.swift", marker)

    try? await Task.sleep(nanoseconds: 500_000_000)

    let logs = await PersistentLogger.shared.retrieveAllLogs()

    // The tag should be trimmed to just "Logging/SomeFile.swift"
    XCTAssertTrue(logs.contains(marker), "Message should be present in logs")
    if logs.contains("Logging/SomeFile.swift") {
      XCTAssertFalse(
        logs.contains("/Users/dev/Projects"),
        "Full file path prefix should be trimmed from tag"
      )
    }
  }

  // MARK: - Date Formatter Tests

  func testDateFormatter_isConfigured() {
    let formatter = Log.dateFormatter
    let formatted = formatter.string(from: Date())

    // Should match "yyyy-MM-dd HH:mm:ss" format
    XCTAssertFalse(formatted.isEmpty, "Date formatter should produce non-empty output")
    XCTAssertEqual(formatted.count, 19, "Date format 'yyyy-MM-dd HH:mm:ss' should be 19 characters")
  }
}
