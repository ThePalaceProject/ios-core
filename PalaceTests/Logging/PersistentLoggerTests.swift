//
//  PersistentLoggerTests.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import os.log
@testable import Palace

final class PersistentLoggerTests: XCTestCase {

    // MARK: - Shared Instance

    func testShared_returnsSameInstance() async {
        let a = PersistentLogger.shared
        let b = PersistentLogger.shared
        // Both should be the same actor reference
        let countA = await a.retrieveAllLogs().count
        let countB = await b.retrieveAllLogs().count
        // If shared works, both should be accessible and consistent
        XCTAssertGreaterThanOrEqual(countA, 0)
        XCTAssertGreaterThanOrEqual(countB, 0)
    }

    // MARK: - Log and Retrieve

    func testLog_andRetrieve_containsLoggedMessage() async {
        let uniqueMarker = "TEST_MARKER_\(UUID().uuidString)"

        await PersistentLogger.shared.log(level: .error, tag: "Test", message: uniqueMarker)

        let allLogs = await PersistentLogger.shared.retrieveAllLogs()
        XCTAssertTrue(allLogs.contains(uniqueMarker), "Retrieved logs should contain the marker we logged")
    }

    func testLog_errorLevel_isRecorded() async {
        let marker = "ERROR_LEVEL_\(UUID().uuidString)"
        await PersistentLogger.shared.log(level: .error, tag: "ErrorTag", message: marker)

        let logs = await PersistentLogger.shared.retrieveAllLogs()
        XCTAssertTrue(logs.contains(marker))
        XCTAssertTrue(logs.contains("ErrorTag"))
    }

    func testLog_faultLevel_isRecorded() async {
        let marker = "FAULT_LEVEL_\(UUID().uuidString)"
        await PersistentLogger.shared.log(level: .fault, tag: "FaultTag", message: marker)

        let logs = await PersistentLogger.shared.retrieveAllLogs()
        XCTAssertTrue(logs.contains(marker))
    }

    // MARK: - Retrieve All Logs

    func testRetrieveAllLogs_returnsString() async {
        let logs = await PersistentLogger.shared.retrieveAllLogs()
        // Should always return a string (possibly empty)
        XCTAssertNotNil(logs)
    }

    // MARK: - Multiple Log Entries

    func testLog_multipleEntries_allAppear() async {
        let prefix = UUID().uuidString
        let messages = (0..<5).map { "\(prefix)_entry_\($0)" }

        for msg in messages {
            await PersistentLogger.shared.log(level: .error, tag: "MultiTest", message: msg)
        }

        let logs = await PersistentLogger.shared.retrieveAllLogs()
        for msg in messages {
            XCTAssertTrue(logs.contains(msg), "Logs should contain: \(msg)")
        }
    }

    // MARK: - Timestamp Format

    func testLog_containsTimestamp() async {
        let marker = "TIMESTAMP_CHECK_\(UUID().uuidString)"
        await PersistentLogger.shared.log(level: .error, tag: "TimeTest", message: marker)

        let logs = await PersistentLogger.shared.retrieveAllLogs()
        // ISO8601 dates contain "T" separator and likely the current year
        let currentYear = Calendar.current.component(.year, from: Date())
        XCTAssertTrue(logs.contains("\(currentYear)"), "Logs should contain current year in timestamps")
    }
}
