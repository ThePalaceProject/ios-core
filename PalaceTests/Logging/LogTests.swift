//
//  LogTests.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import os.log
import PalaceLogging
@testable import Palace

final class LogTests: XCTestCase {

    override func tearDown() {
        super.tearDown()
    }

    // MARK: - Subsystem Tests

    func testSubsystem_isCorrectValue() {
        XCTAssertEqual(Log.subsystem, "org.thepalaceproject.palace")
        XCTAssertTrue(Log.subsystem.contains("thepalaceproject"), "Subsystem must contain the organization identifier")
        XCTAssertFalse(Log.subsystem.isEmpty, "Log subsystem must not be empty")
    }

    func testSubsystem_isNotEmpty() {
        XCTAssertFalse(Log.subsystem.isEmpty, "Log subsystem should not be empty")
        XCTAssertGreaterThan(Log.subsystem.count, 0, "Subsystem must have at least one character")
        XCTAssertTrue(Log.subsystem.contains("."), "Subsystem must use reverse-DNS notation with dots")
    }

    // MARK: - Log Level Tests

    func testDebug_doesNotCrash() {
        let subsystemBefore = Log.subsystem
        Log.debug("LogTests", "Debug test message")
        let subsystemAfter = Log.subsystem
        XCTAssertEqual(subsystemAfter, subsystemBefore, "Log subsystem must remain stable after debug call")
        XCTAssertEqual(subsystemAfter, "org.thepalaceproject.palace")
    }

    func testInfo_doesNotCrash() {
        let subsystemBefore = Log.subsystem
        Log.info("LogTests", "Info test message")
        let subsystemAfter = Log.subsystem
        XCTAssertFalse(subsystemAfter.isEmpty, "Subsystem must remain valid after info call")
        XCTAssertEqual(subsystemAfter, subsystemBefore, "Info call must not mutate the log subsystem")
    }

    func testWarn_doesNotCrash() {
        let subsystemBefore = Log.subsystem
        Log.warn("LogTests", "Warning test message")
        let subsystemAfter = Log.subsystem
        XCTAssertFalse(subsystemAfter.isEmpty, "Subsystem must remain valid after warn call")
        XCTAssertEqual(subsystemAfter, subsystemBefore, "Warn call must not mutate the log subsystem")
    }

    func testError_doesNotCrash() {
        let subsystemBefore = Log.subsystem
        Log.error("LogTests", "Error test message")
        let subsystemAfter = Log.subsystem
        XCTAssertFalse(subsystemAfter.isEmpty, "Subsystem must remain valid after error call")
        XCTAssertEqual(subsystemAfter, subsystemBefore, "Error call must not mutate the log subsystem")
    }

    func testFault_doesNotCrash() {
        let subsystemBefore = Log.subsystem
        Log.fault("LogTests", "Fault test message")
        let subsystemAfter = Log.subsystem
        XCTAssertFalse(subsystemAfter.isEmpty, "Subsystem must remain valid after fault call")
        XCTAssertEqual(subsystemAfter, subsystemBefore, "Fault call must not mutate the log subsystem")
    }

    func testLog_objcCompatibility_doesNotCrash() {
        let subsystemBefore = Log.subsystem
        Log.log("ObjC compat test message")
        let subsystemAfter = Log.subsystem
        XCTAssertFalse(subsystemAfter.isEmpty, "Subsystem must remain valid after ObjC log call")
        XCTAssertEqual(subsystemAfter, subsystemBefore, "ObjC log call must not mutate the log subsystem")
    }

    // MARK: - Error Persistence Tests

    /// Polls PersistentLogger until the marker appears, with a short interval
    /// and a bounded total wait. Returns the final logs string for the
    /// caller's downstream `XCTAssertTrue(logs.contains(marker))` to fire
    /// a clear failure if the marker never landed — this is the "silent
    /// return with informative downstream assertion" pattern, distinct
    /// from the silent-timeout patterns `awaitConditionAsync` replaces.
    /// 10s timeout — CI runner load + PersistentLogger actor hops can
    /// race past tighter budgets; local runs resolve in <0.1s.
    private func pollForLog(marker: String, timeout: TimeInterval = 10.0) async -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let logs = await PersistentLogger.shared.retrieveAllLogs()
            if logs.contains(marker) { return logs }
            try? await Task.sleep(nanoseconds: 25_000_000) // 25 ms
        }
        return await PersistentLogger.shared.retrieveAllLogs()
    }

    func testError_persistsToLogger() async {
        await PersistentLogger.shared.clearLogs()

        let marker = "PersistenceTest_\(UUID().uuidString)"
        Log.error("LogTests", marker)

        let logs = await pollForLog(marker: marker)

        XCTAssertTrue(
            logs.contains(marker),
            "Error-level messages should be persisted to PersistentLogger"
        )
    }

    func testFault_persistsToLogger() async {
        await PersistentLogger.shared.clearLogs()

        let marker = "FaultPersistenceTest_\(UUID().uuidString)"
        Log.fault("LogTests", marker)

        let logs = await pollForLog(marker: marker)

        XCTAssertTrue(
            logs.contains(marker),
            "Fault-level messages should be persisted to PersistentLogger"
        )
    }

    func testDebug_doesNotPersistToLogger() async {
        await PersistentLogger.shared.clearLogs()

        let marker = "DebugNoPersist_\(UUID().uuidString)"
        Log.debug("LogTests", marker)

        // Short poll to give any erroneous persist attempt time to complete
        try? await Task.sleep(nanoseconds: 100_000_000) // 100 ms

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

        try? await Task.sleep(nanoseconds: 100_000_000) // 100 ms

        let logs = await PersistentLogger.shared.retrieveAllLogs()

        XCTAssertFalse(
            logs.contains(marker),
            "Info-level messages should NOT be persisted to PersistentLogger"
        )
    }

    // MARK: - Tag Trimming Tests

    func testLog_withFilePathTag_trimsProperly() async {
        await PersistentLogger.shared.clearLogs()

        let marker = "TagTrimTest_\(UUID().uuidString)"
        Log.error("/Users/dev/Projects/Palace/Logging/SomeFile.swift", marker)

        let logs = await pollForLog(marker: marker)

        XCTAssertTrue(logs.contains(marker), "Message should be present in logs")
        XCTAssertFalse(logs.isEmpty, "Logs must not be empty after logging an error")
        if logs.contains("Logging/SomeFile.swift") {
            XCTAssertFalse(
                logs.contains("/Users/dev/Projects"),
                "Full file path prefix should be trimmed from tag"
            )
        }
    }

    // Date-format coverage moved to PalaceLogging's own test target
    // (`PalaceLoggingTests.LogFormatTests`) when `Log.dateFormatter` was made
    // private during the Swift 6 concurrency conversion — it was non-Sendable
    // global state, replaced by the internal `Log.formattedTimestamp(_:)` helper.
}
