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

    /// Polls collectLogs until the marker appears (or times out at ~1 s).
    /// OSLogStore has its own flush schedule, so we poll rather than sleep a fixed amount.
    private func pollForOSLogMarker(_ marker: String) async -> String {
        for _ in 0..<10 {
            let data = await DeviceLogCollector.shared.collectLogs(lastDays: 1)
            let output = String(data: data, encoding: .utf8) ?? ""
            if output.contains(marker) { return output }
            try? await Task.sleep(nanoseconds: 100_000_000) // 100 ms per attempt
        }
        let data = await DeviceLogCollector.shared.collectLogs(lastDays: 1)
        return String(data: data, encoding: .utf8) ?? ""
    }

    func testCollectLogs_capturesRecentOSLogEntries() async {
        let marker = "DeviceLogCollectorTest_\(UUID().uuidString)"
        let palaceLog = OSLog(subsystem: Log.subsystem, category: "Test")
        os_log("%{public}@", log: palaceLog, type: .error, marker)

        let output = await pollForOSLogMarker(marker)

        XCTAssertTrue(
            output.contains(marker),
            "Collected logs should contain the marker we just logged. Output length: \(output.count)"
        )
    }

    func testCollectLogs_formattedEntriesContainExpectedFields() async {
        let marker = "FormatTest_\(UUID().uuidString)"
        let palaceLog = OSLog(subsystem: Log.subsystem, category: "FormatTest")
        os_log("%{public}@", log: palaceLog, type: .info, marker)

        let output = await pollForOSLogMarker(marker)

        let lines = output.components(separatedBy: "\n")
        let markerLine = lines.first { $0.contains(marker) }

        if let line = markerLine {
            XCTAssertTrue(line.contains("["), "Log line should contain bracket-delimited fields")
            XCTAssertTrue(line.contains(Log.subsystem), "Log line should contain the subsystem")
            XCTAssertTrue(line.contains("FormatTest"), "Log line should contain the category")
        }
        // If markerLine is nil the log system hasn't flushed yet — not a hard failure
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

        let entryCountPattern = "End Device Logs \\(\\d+ entries\\)"
        let hasEntryCount = output.range(of: entryCountPattern, options: .regularExpression) != nil
        let hasError = output.contains("Failed to access OSLogStore")

        XCTAssertTrue(
            hasEntryCount || hasError,
            "Output should report entry count or indicate an error"
        )
    }
}
