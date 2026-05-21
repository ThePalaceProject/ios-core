//
//  PersistentLoggerTests.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import os.log
import PalaceLogging
@testable import Palace

final class PersistentLoggerTests: XCTestCase {

    private var sut: PersistentLogger!
    private var testLogsRoot: URL!

    override func setUp() {
        super.setUp()
        testLogsRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-persistent-\(UUID().uuidString)")
        sut = PersistentLogger(logsRootURL: testLogsRoot)
    }

    override func tearDown() {
        Task { [sut, testLogsRoot] in
            await sut?.clearLogs()
            if let root = testLogsRoot {
                try? FileManager.default.removeItem(at: root)
            }
        }
        sut = nil
        testLogsRoot = nil
        super.tearDown()
    }

    // MARK: - Init injection seam

    /// Replaces the `testShared_returnsSameInstance` tautology. Pins the
    /// new `init(logsRootURL:)` surface: a log written via the injected
    /// instance lands in the injected directory, NOT in the production
    /// Documents/Logs path. A mutant that silently ignores `logsRootURL`
    /// (returns the default dir from getLogsDirectory) fails this.
    func testInit_withCustomLogsRoot_writesToProvidedDirectory() async {
        let marker = "INJECTED_DIR_\(UUID().uuidString)"
        await sut.log(level: .error, tag: "InitTest", message: marker)

        let expectedFile = testLogsRoot.appendingPathComponent("palace_error.log")
        // Allow a brief tick for the actor's pending setup to complete.
        for _ in 0..<10 {
            if FileManager.default.fileExists(atPath: expectedFile.path) { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: expectedFile.path),
            "Log must be written to the injected directory at \(expectedFile.path)"
        )

        let contents = (try? String(contentsOf: expectedFile, encoding: .utf8)) ?? ""
        XCTAssertTrue(contents.contains(marker),
                      "Injected directory's log file must contain the logged marker")
    }

    // MARK: - Log and Retrieve

    func testLog_andRetrieve_containsLoggedMessage() async {
        let uniqueMarker = "TEST_MARKER_\(UUID().uuidString)"

        await sut.log(level: .error, tag: "Test", message: uniqueMarker)

        let allLogs = await sut.retrieveAllLogs()
        XCTAssertTrue(allLogs.contains(uniqueMarker), "Retrieved logs should contain the marker we logged")
    }

    func testLog_errorLevel_isRecorded() async {
        let marker = "ERROR_LEVEL_\(UUID().uuidString)"
        await sut.log(level: .error, tag: "ErrorTag", message: marker)

        let logs = await sut.retrieveAllLogs()
        XCTAssertTrue(logs.contains(marker))
        XCTAssertTrue(logs.contains("ErrorTag"))
        // Level tag must be rendered as the literal "ERROR" by levelToString.
        XCTAssertTrue(logs.contains("[ERROR]"),
                      "Error-level entries must render the [ERROR] level token")
    }

    func testLog_faultLevel_isRecorded() async {
        let marker = "FAULT_LEVEL_\(UUID().uuidString)"
        await sut.log(level: .fault, tag: "FaultTag", message: marker)

        let logs = await sut.retrieveAllLogs()
        XCTAssertTrue(logs.contains(marker))
        XCTAssertTrue(logs.contains("[FAULT]"),
                      "Fault-level entries must render the [FAULT] level token")
    }

    // MARK: - Multiple Log Entries

    func testLog_multipleEntries_allAppear() async {
        let prefix = UUID().uuidString
        let messages = (0..<5).map { "\(prefix)_entry_\($0)" }

        for msg in messages {
            await sut.log(level: .error, tag: "MultiTest", message: msg)
        }

        let logs = await sut.retrieveAllLogs()
        for msg in messages {
            XCTAssertTrue(logs.contains(msg), "Logs should contain: \(msg)")
        }
    }

    // MARK: - Timestamp Format

    func testLog_containsTimestamp() async {
        let marker = "TIMESTAMP_CHECK_\(UUID().uuidString)"
        await sut.log(level: .error, tag: "TimeTest", message: marker)

        let logs = await sut.retrieveAllLogs()
        // ISO8601 dates contain the current year.
        let currentYear = Calendar.current.component(.year, from: Date())
        XCTAssertTrue(logs.contains("\(currentYear)"), "Logs should contain current year in timestamps")
    }

    /// Pins the `i == 0` filename-selection branch in `retrieveAllLogs`.
    /// At index 0 the active file is named `palace_error.log`; at i>0
    /// it's the rotated `palace_error.<i>.log`. A `i == 0` → `i != 0`
    /// mutant would invert the selection and emit the wrong filename in
    /// the per-file header, OR list the active file's header zero times
    /// when only the active file exists.
    func testRetrieveAllLogs_includesActiveFileHeaderExactlyOnce() async {
        let marker = "HEADER_PROBE_\(UUID().uuidString)"
        await sut.log(level: .error, tag: "Header", message: marker)

        let logs = await sut.retrieveAllLogs()
        // The active file's header must appear exactly once.
        let activeHeader = "=== Log File: palace_error.log ==="
        let occurrences = logs.components(separatedBy: activeHeader).count - 1
        XCTAssertEqual(
            occurrences, 1,
            "Active log file header must appear exactly once; got \(occurrences) (mutant: i==0 → i!=0 would change count)"
        )
        // Rotated palace_error.1.log header must NOT appear when no
        // rotation has occurred — a mutant that emits it would fail.
        XCTAssertFalse(
            logs.contains("=== Log File: palace_error.1.log ==="),
            "No rotated file exists yet; mutant emitting palace_error.1.log header indicates filename-selection bug"
        )
    }

    // MARK: - Rotation + clear (new edge cases enabled by isolation)

    /// `log` rotates the active file when its size exceeds 5MB. Singleton
    /// version of this test would have polluted every later run with the
    /// rotated files. With the injected dir, write > 5MB and assert
    /// `palace_error.1.log` appears alongside the active file.
    func testLog_rotatesAtMaxFileSize() async {
        // ~5KB per line × 1100 lines ~= 5.5MB. Use a fixed payload to keep
        // wall time bounded but exceed the 5MB threshold reliably.
        let payload = String(repeating: "x", count: 5_000)
        for i in 0..<1_100 {
            await sut.log(level: .error, tag: "Rotate", message: "line-\(i)-\(payload)")
        }

        // Active file path + rotated #1 path.
        let active = testLogsRoot.appendingPathComponent("palace_error.log")
        let rotated = testLogsRoot.appendingPathComponent("palace_error.1.log")

        // After rotation, both files exist (the rotated one carries the
        // older lines, the active one carries the post-rotation lines).
        XCTAssertTrue(FileManager.default.fileExists(atPath: active.path),
                      "Active log file must exist after rotation")
        XCTAssertTrue(FileManager.default.fileExists(atPath: rotated.path),
                      "Rotated palace_error.1.log must appear once active exceeds 5MB")
    }

    /// `clearLogs` removes the active file AND all numbered rotated
    /// files. Build at least one rotation, then clear, then assert the
    /// injected directory contains no log files.
    func testClearLogs_removesAllRotatedFiles() async {
        let payload = String(repeating: "y", count: 5_000)
        for i in 0..<1_100 {
            await sut.log(level: .error, tag: "Clear", message: "pre-\(i)-\(payload)")
        }

        // Wait for at least one rotated file to appear before clearing.
        let rotated = testLogsRoot.appendingPathComponent("palace_error.1.log")
        XCTAssertTrue(FileManager.default.fileExists(atPath: rotated.path),
                      "Precondition: rotation must have occurred")

        await sut.clearLogs()

        // After clear, neither the active nor any rotated file should remain.
        let active = testLogsRoot.appendingPathComponent("palace_error.log")
        let activeExists = FileManager.default.fileExists(atPath: active.path)
        // The implementation recreates the active file on setup after clear, so
        // its size should be 0 even if the file is recreated. The numbered
        // rotated files must be gone.
        XCTAssertFalse(FileManager.default.fileExists(atPath: rotated.path),
                       "clearLogs must delete palace_error.1.log")
        if activeExists {
            let attrs = try? FileManager.default.attributesOfItem(atPath: active.path)
            let size = (attrs?[.size] as? Int64) ?? -1
            XCTAssertEqual(size, 0,
                           "Recreated active log after clearLogs must be empty (was \(size) bytes)")
        }
    }
}
