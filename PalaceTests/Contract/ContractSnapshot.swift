//
//  ContractSnapshot.swift
//  PalaceTests
//
//  Snapshot-test helper for the contract-snapshot pattern. Pairs with
//  `CallLog` to give refactor PRs a structural safety net: when you extract a
//  class, the contract test asserts that the call sequence into its
//  dependencies stays identical pre/post-refactor.
//
//  See PalaceTests/Contract/README.md for usage.
//
//  WHY THIS EXISTS:
//
//  3.1.0's Phase 7 PR #890 extracted ~1,524 LOC from MyBooksDownloadCenter
//  into BorrowReducer + BorrowOperation + BookReturnService + ... The
//  extraction leaked 4 silent regressions (F-011, F-014, F-016, F-017).
//  Existing unit tests caught zero of them, because the regressions were
//  changes-to-call-sequences (a missing arm in a switch, an inverted
//  conditional in an auto-download chain, a missed observation dependency)
//  that the per-case unit tests weren't sensitive to.
//
//  A contract snapshot records "for input X, dependency Y is called with
//  args Z, then dependency W with args V". When the extraction changes ANY
//  of those calls, the snapshot diff fires — pinpointing the call-sequence
//  drift instead of letting it ship.
//

import Foundation
import XCTest

public enum ContractSnapshotError: Error, CustomStringConvertible {
    case snapshotMissing(path: String)
    case snapshotMismatch(diff: String, expectedPath: String)
    case encodingFailed(reason: String)

    public var description: String {
        switch self {
        case let .snapshotMissing(path):
            return """
            Contract snapshot missing at \(path). To record the initial baseline,
            re-run with environment variable CONTRACT_SNAPSHOT_RECORD=1 set.
            """
        case let .snapshotMismatch(diff, expectedPath):
            return """
            Contract snapshot drift detected.

            Expected (from \(expectedPath)):
            \(diff)

            If this drift is intentional (e.g. you reviewed the call-sequence
            change and accepted it), re-record with CONTRACT_SNAPSHOT_RECORD=1.
            Otherwise the refactor has introduced an unintended call-sequence
            regression — review the diff before adjusting the snapshot.
            """
        case let .encodingFailed(reason):
            return "Contract snapshot encoding failed: \(reason)"
        }
    }
}

public enum ContractSnapshot {

    /// Assert that the given call log matches the snapshot stored at
    /// `__Snapshots__/<testFile>/<name>.json` (relative to the test file).
    ///
    /// **First run / re-record:** Set `CONTRACT_SNAPSHOT_RECORD=1` in the
    /// scheme's environment OR pass `record: true` to write the snapshot
    /// instead of asserting. Commit the resulting JSON file to source
    /// control — the snapshot IS the contract.
    public static func assert(
        _ log: CallLog,
        named name: String,
        record: Bool = false,
        // `#filePath`, NOT `#file`: this value is resolved as a filesystem path
        // below (to locate the sibling `__Snapshots__` dir). Under Swift 6's
        // default-on ConciseMagicFile, `#file` yields a concise "Module/Base.swift"
        // that resolves against CWD — on CI that becomes the read-only filesystem
        // root (`/PalaceTests/__Snapshots__/…`), which is exactly the "volume is
        // read only" failure. `#filePath` always yields the true absolute path.
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let testFileURL = URL(fileURLWithPath: "\(file)")
        let testFileBaseName = testFileURL.deletingPathExtension().lastPathComponent
        let snapshotDir = testFileURL
            .deletingLastPathComponent()
            .appendingPathComponent("__Snapshots__")
            .appendingPathComponent(testFileBaseName)
        let snapshotURL = snapshotDir.appendingPathComponent("\(name).json")

        let recordMode = record
            || (ProcessInfo.processInfo.environment["CONTRACT_SNAPSHOT_RECORD"] == "1")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let entries = log.snapshot()
        let actualData: Data
        do {
            actualData = try encoder.encode(entries)
        } catch {
            XCTFail("Contract snapshot encoding failed: \(error)", file: file, line: line)
            return
        }

        if recordMode || !FileManager.default.fileExists(atPath: snapshotURL.path) {
            do {
                try FileManager.default.createDirectory(
                    at: snapshotDir,
                    withIntermediateDirectories: true
                )
                try actualData.write(to: snapshotURL)
                if !recordMode {
                    // First run — record but mark as new so author knows to commit.
                    XCTFail("""
                        Contract snapshot recorded at \(snapshotURL.path).
                        Commit this file to lock the contract. Re-run the test
                        and it will pass (or fail with a diff if the captured
                        sequence drifts).
                        """,
                        file: file, line: line)
                }
                return
            } catch {
                XCTFail("Failed to write contract snapshot: \(error)", file: file, line: line)
                return
            }
        }

        let expectedData: Data
        do {
            expectedData = try Data(contentsOf: snapshotURL)
        } catch {
            XCTFail("Failed to read contract snapshot at \(snapshotURL.path): \(error)",
                    file: file, line: line)
            return
        }

        if actualData != expectedData {
            // Render a human-readable diff. JSONEncoder + sortedKeys above
            // gives us deterministic output; a simple line-by-line diff is
            // enough for the typical small-N case-log.
            let actualText = String(data: actualData, encoding: .utf8) ?? "<binary>"
            let expectedText = String(data: expectedData, encoding: .utf8) ?? "<binary>"
            let diff = renderDiff(expected: expectedText, actual: actualText)
            XCTFail("""
                Contract drift in \(name):
                \(diff)

                Expected snapshot: \(snapshotURL.path)
                If the new sequence is the intended behavior, re-record with
                CONTRACT_SNAPSHOT_RECORD=1 and commit the updated file.
                """,
                file: file, line: line)
        }
    }

    /// Best-effort textual diff. For most contract drift the JSON pretty-printed
    /// form is short enough that side-by-side is readable directly. We render
    /// expected and actual as labeled blocks rather than a per-line diff so the
    /// author can eyeball the change.
    private static func renderDiff(expected: String, actual: String) -> String {
        return """
            --- expected ---
            \(expected)
            --- actual ---
            \(actual)
            ---
            """
    }
}
