//
//  DeviceLogCollectorTests.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceLogging
import os.log
@testable import Palace

/// Hermetic tests for `DeviceLogCollector`.
///
/// These drive an **injected fixture entry source** rather than the live process
/// `OSLogStore`. The prior version called `DeviceLogCollector.shared.collectLogs`,
/// which scans `OSLogStore(scope: .currentProcessIdentifier)` — a process-global
/// accumulator whose entry volume grows with every test that ran before. Under the
/// full ~7k-test suite that scan blew the 120s per-test allowance and hung the run
/// (a different worker each time), while every local subset passed. Injecting the
/// source removes the coupling entirely: the format / count / truncation / error
/// logic is now exercised deterministically against controlled input, so these
/// tests are fast, load-independent, and assert exact behavior instead of merely
/// "non-empty".
final class DeviceLogCollectorTests: XCTestCase {

    private struct SourceError: Error {}

    private func entry(
        _ message: String,
        level: DeviceLogEntry.Level = .info,
        subsystem: String = "org.palace",
        category: String = "Test",
        date: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> DeviceLogEntry {
        DeviceLogEntry(date: date, subsystem: subsystem, category: category, message: message, kind: .log(level: level))
    }

    private func collector(
        _ entries: [DeviceLogEntry] = [],
        maxEntries: Int = 50_000,
        maxOutputBytes: Int = 10_000_000
    ) -> DeviceLogCollector {
        DeviceLogCollector(entrySource: { _, cap in Array(entries.prefix(cap)) },
                           maxEntries: maxEntries,
                           maxOutputBytes: maxOutputBytes)
    }

    private func text(_ data: Data) -> String { String(data: data, encoding: .utf8) ?? "" }

    // MARK: - Structure / header

    func testCollectLogs_headerReflectsDayRange() async {
        let output = text(await collector().collectLogs(lastDays: 3))
        XCTAssertTrue(output.contains("=== Device Logs (OSLogStore) ==="))
        XCTAssertTrue(output.contains("Time Range: Last 3 day(s)"))
        XCTAssertTrue(output.contains("Generated:"))
    }

    func testCollectLogs_defaultDayRangeIsSeven() async {
        let output = text(await collector().collectLogs())
        XCTAssertTrue(output.contains("Time Range: Last 7 day(s)"),
                      "collectLogs() default must be 7 days")
    }

    func testCollectLogs_outputIsValidUTF8() async {
        let data = await collector([entry("hello")]).collectLogs(lastDays: 1)
        XCTAssertNotNil(String(data: data, encoding: .utf8))
    }

    // MARK: - Entry count (the test that used to hang)

    func testCollectLogs_reportsExactEntryCount() async {
        let output = text(await collector([entry("a"), entry("b"), entry("c")]).collectLogs(lastDays: 1))
        XCTAssertTrue(output.contains("=== End Device Logs (3 entries) ==="),
                      "entry count must reflect exactly the entries collected; got:\n\(output)")
    }

    func testCollectLogs_zeroEntries_reportsZeroCountNotError() async {
        let output = text(await collector([]).collectLogs(lastDays: 1))
        XCTAssertTrue(output.contains("=== End Device Logs (0 entries) ==="))
        XCTAssertFalse(output.contains("Failed to access OSLogStore"))
    }

    // MARK: - Per-line formatting

    func testCollectLogs_logEntry_lineCarriesLevelSubsystemCategoryAndMessage() async {
        let output = text(await collector([
            entry("boom", level: .error, subsystem: "org.palace.net", category: "Sync")
        ]).collectLogs(lastDays: 1))

        // The one formatted line between the blank-line header break and the end marker.
        let line = output
            .components(separatedBy: "\n")
            .first { $0.contains("boom") } ?? ""
        XCTAssertTrue(line.contains("[ERROR]"), "line must carry the level token; got: \(line)")
        XCTAssertTrue(line.contains("[org.palace.net/Sync]"), "line must carry subsystem/category; got: \(line)")
        XCTAssertTrue(line.contains("boom"), "line must carry the message; got: \(line)")
        XCTAssertTrue(line.hasPrefix("["), "line must start with a bracketed timestamp; got: \(line)")
    }

    func testCollectLogs_signpost_rendersSignpostTag() async {
        let sp = DeviceLogEntry(date: Date(timeIntervalSince1970: 1_700_000_000),
                                subsystem: "org.palace", category: "Perf",
                                message: "span-start", kind: .signpost)
        let output = text(await collector([sp]).collectLogs(lastDays: 1))
        let line = output.components(separatedBy: "\n").first { $0.contains("span-start") } ?? ""
        XCTAssertTrue(line.contains("[SIGNPOST]"), "signpost lines must carry the SIGNPOST tag; got: \(line)")
        XCTAssertTrue(line.contains("[org.palace/Perf]"))
    }

    func testCollectLogs_emptySubsystemAndCategory_renderDashes() async {
        let output = text(await collector([entry("uniquemsg", subsystem: "", category: "")]).collectLogs(lastDays: 1))
        let line = output.components(separatedBy: "\n").first { $0.contains("uniquemsg") } ?? ""
        XCTAssertTrue(line.contains("[-/-]"), "empty subsystem/category must render as -/-; got: \(line)")
    }

    func testCollectLogs_levelStrings_mapEachLevelDistinctly() async {
        let cases: [(DeviceLogEntry.Level, String)] = [
            (.debug, "[DEBUG]"), (.info, "[INFO ]"), (.notice, "[NOTE ]"),
            (.error, "[ERROR]"), (.fault, "[FAULT]")
        ]
        for (level, token) in cases {
            let marker = "lvlmarker\(token.filter { $0.isLetter })"
            let output = text(await collector([entry(marker, level: level)]).collectLogs(lastDays: 1))
            let line = output.components(separatedBy: "\n").first { $0.contains(marker) } ?? ""
            XCTAssertTrue(line.contains(token), "level \(level) must render \(token); got: \(line)")
        }
    }

    // MARK: - Truncation

    func testCollectLogs_truncatesWhenSourceHitsEntryCap() async {
        // Source returns exactly maxEntries → more existed than collected.
        let output = text(await collector([entry("x"), entry("y")], maxEntries: 2).collectLogs(lastDays: 1))
        XCTAssertTrue(output.contains("[Log output truncated at 2 entries"),
                      "hitting the entry cap must emit the truncation note; got:\n\(output)")
        XCTAssertTrue(output.contains("=== End Device Logs (2 entries) ==="))
    }

    func testCollectLogs_underEntryCap_doesNotTruncate() async {
        let output = text(await collector([entry("x")], maxEntries: 50).collectLogs(lastDays: 1))
        XCTAssertFalse(output.contains("[Log output truncated"),
                       "collecting fewer than the cap must not claim truncation")
    }

    func testCollectLogs_truncatesAtByteBudget() async {
        // Each formatted line is well over 5 bytes, so the second entry trips the cap.
        let entries = [entry("first-line-message"), entry("second-line-message"), entry("third")]
        let output = text(await collector(entries, maxOutputBytes: 5).collectLogs(lastDays: 1))
        XCTAssertTrue(output.contains("[Log output truncated at 1 entries"),
                      "byte budget must cut off after the first line; got:\n\(output)")
        XCTAssertTrue(output.contains("=== End Device Logs (1 entries) ==="))
    }

    // MARK: - Error path

    func testCollectLogs_sourceThrows_reportsAccessError() async {
        let failing = DeviceLogCollector(entrySource: { _, _ in throw SourceError() })
        let output = text(await failing.collectLogs(lastDays: 1))
        XCTAssertTrue(output.contains("Failed to access OSLogStore"),
                      "a throwing source must surface the access-error branch; got:\n\(output)")
        XCTAssertFalse(output.contains("=== End Device Logs"),
                       "the end marker must not print when collection failed")
    }
}
