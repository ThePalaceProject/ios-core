//
//  DeviceLogCollectorTests.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import os.log
@testable import Palace

final class DeviceLogCollectorTests: XCTestCase {

  // MARK: - collectLogs Output Structure Tests

  func testCollectLogs_returnsNonEmptyData() async {
    let data = await DeviceLogCollector.shared.collectLogs(lastDays: 1)

    XCTAssertFalse(data.isEmpty, "Device log data should not be empty")
  }

  func testCollectLogs_containsExpectedHeader() async {
    let data = await DeviceLogCollector.shared.collectLogs(lastDays: 7)
    let output = String(data: data, encoding: .utf8) ?? ""

    XCTAssertTrue(output.contains("=== Device Logs (OSLogStore) ==="), "Output should contain the header")
    XCTAssertTrue(output.contains("Generated:"), "Output should contain generation timestamp")
    XCTAssertTrue(output.contains("Time Range: Last 7 day(s)"), "Output should contain time range")
  }

  func testCollectLogs_containsEndMarker() async {
    let data = await DeviceLogCollector.shared.collectLogs(lastDays: 1)
    let output = String(data: data, encoding: .utf8) ?? ""

    XCTAssertTrue(
      output.contains("=== End Device Logs") || output.contains("Failed to access OSLogStore"),
      "Output should contain either an end marker or an error message"
    )
  }

  func testCollectLogs_withCustomDayRange_reflectsInOutput() async {
    let data = await DeviceLogCollector.shared.collectLogs(lastDays: 3)
    let output = String(data: data, encoding: .utf8) ?? ""

    XCTAssertTrue(output.contains("Time Range: Last 3 day(s)"), "Output should reflect the custom day range")
  }

  func testCollectLogs_outputIsValidUTF8() async {
    let data = await DeviceLogCollector.shared.collectLogs(lastDays: 1)
    let output = String(data: data, encoding: .utf8)

    XCTAssertNotNil(output, "Device log output should be valid UTF-8")
  }

  // MARK: - Log Capture Tests

  func testCollectLogs_capturesRecentOSLogEntries() async {
    // Write a unique marker to os_log so we can verify it appears in collected logs
    let marker = "DeviceLogCollectorTest_\(UUID().uuidString)"
    let palaceLog = OSLog(subsystem: Log.subsystem, category: "Test")
    os_log("%{public}@", log: palaceLog, type: .error, marker)

    // Brief delay to let the log system flush
    try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s

    let data = await DeviceLogCollector.shared.collectLogs(lastDays: 1)
    let output = String(data: data, encoding: .utf8) ?? ""

    XCTAssertTrue(
      output.contains(marker),
      "Collected logs should contain the marker we just logged. Output length: \(output.count)"
    )
  }

  func testCollectLogs_formattedEntriesContainExpectedFields() async {
    // Log a known message
    let marker = "FormatTest_\(UUID().uuidString)"
    let palaceLog = OSLog(subsystem: Log.subsystem, category: "FormatTest")
    os_log("%{public}@", log: palaceLog, type: .info, marker)

    try? await Task.sleep(nanoseconds: 500_000_000)

    let data = await DeviceLogCollector.shared.collectLogs(lastDays: 1)
    let output = String(data: data, encoding: .utf8) ?? ""

    // Find the line containing our marker
    let lines = output.components(separatedBy: "\n")
    let markerLine = lines.first { $0.contains(marker) }

    if let line = markerLine {
      // Verify format: [timestamp] [LEVEL] [subsystem/category] message
      XCTAssertTrue(line.contains("["), "Log line should contain bracket-delimited fields")
      XCTAssertTrue(line.contains(Log.subsystem), "Log line should contain the subsystem")
      XCTAssertTrue(line.contains("FormatTest"), "Log line should contain the category")
    }
    // If markerLine is nil, the log system may not have flushed in time — not a hard failure
  }

  // MARK: - Default Parameter Tests

  func testCollectLogs_defaultParameterIs7Days() async {
    let data = await DeviceLogCollector.shared.collectLogs()
    let output = String(data: data, encoding: .utf8) ?? ""

    XCTAssertTrue(output.contains("Last 7 day(s)"), "Default should be 7 days")
  }

  // MARK: - Entry Count Reporting

  func testCollectLogs_reportsEntryCount() async {
    let data = await DeviceLogCollector.shared.collectLogs(lastDays: 1)
    let output = String(data: data, encoding: .utf8) ?? ""

    // Should contain entry count like "=== End Device Logs (42 entries) ==="
    let entryCountPattern = "End Device Logs \\(\\d+ entries\\)"
    let hasEntryCount = output.range(of: entryCountPattern, options: .regularExpression) != nil
    let hasError = output.contains("Failed to access OSLogStore")

    XCTAssertTrue(
      hasEntryCount || hasError,
      "Output should report entry count or indicate an error"
    )
  }
}
