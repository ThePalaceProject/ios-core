//
//  BackupExclusionMigrationTests.swift
//  PalaceTests
//
//  Tests the 3.1.0 upgrade-pass walker (PP-4179) that recursively flags
//  every existing entry under Application Support and Documents as
//  excluded from iCloud backup. URL.excludeFromBackup() primitive has
//  its own tests in URL+BackupExclusionTests.swift.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

@MainActor
final class BackupExclusionMigrationTests: XCTestCase {

    private var sandbox: URL!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackupExclusionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
        sandbox = nil
    }

    // MARK: - run(directories:)

    func test_run_recursivelyFlagsEveryFileAndDirectory() throws {
        // sandbox/
        //   sub1/file-a.txt
        //   sub2/sub3/file-b.txt
        //   file-c.txt
        let sub1 = sandbox.appendingPathComponent("sub1")
        let sub2 = sandbox.appendingPathComponent("sub2")
        let sub3 = sub2.appendingPathComponent("sub3")
        try FileManager.default.createDirectory(at: sub1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sub3, withIntermediateDirectories: true)
        let fileA = sub1.appendingPathComponent("file-a.txt")
        let fileB = sub3.appendingPathComponent("file-b.txt")
        let fileC = sandbox.appendingPathComponent("file-c.txt")
        try Data().write(to: fileA)
        try Data().write(to: fileB)
        try Data().write(to: fileC)

        BackupExclusionMigration.run(directories: [sandbox])

        for url in [sandbox!, sub1, sub2, sub3, fileA, fileB, fileC] {
            XCTAssertEqual(try isExcluded(url), true,
                           "\(url.lastPathComponent) must be flagged after a recursive run")
        }
    }

    func test_run_continuesAfterMissingRoot_doesNotPoisonSubsequentRoots() throws {
        // Multi-root call where the first root does not exist (e.g. a fresh
        // install with no audiobook downloads yet). The walk must skip the
        // missing root cleanly AND still flag entries under the next root.
        // This replaces a no-positive-assertion "doesn't crash" test that
        // could not catch a mutant that stripped the missing-root guard.
        let missingRoot = sandbox.appendingPathComponent("does-not-exist-\(UUID())")
        let file = sandbox.appendingPathComponent("file.txt")
        try Data().write(to: file)

        BackupExclusionMigration.run(directories: [missingRoot, sandbox])

        XCTAssertEqual(try isExcluded(file), true,
                       "Subsequent roots must still be processed after a missing root — proves the missing-root guard short-circuits one root only, not the whole call")
    }

    func test_run_flagsFilesAddedBetweenInvocations() throws {
        // The thin "isIdempotent" assertion (run twice, check final state)
        // had limited mutation surface because the flag is monotonic. This
        // tightens it: add a NEW file between runs and verify the second
        // run flags it. A mutant that cached "already done" state on the
        // first invocation would leave the new file unflagged and fail.
        // This is more reliable than clearing-and-reflagging because
        // setResourceValues(.isExcludedFromBackup = false) does not
        // consistently remove the underlying xattr across iOS versions.
        let firstFile = sandbox.appendingPathComponent("first.bin")
        try Data().write(to: firstFile)

        BackupExclusionMigration.run(directories: [sandbox])
        XCTAssertEqual(try isExcluded(firstFile), true,
                       "Pre-condition: first run must flag the file present at run time")

        let secondFile = sandbox.appendingPathComponent("second.bin")
        try Data().write(to: secondFile)
        XCTAssertEqual(try isExcluded(secondFile), false,
                       "Pre-condition for second run: newly written file is unflagged")

        BackupExclusionMigration.run(directories: [sandbox])

        XCTAssertEqual(try isExcluded(secondFile), true,
                       "Second run must flag the file added between runs — proves run() does real work on every invocation, not just the first")
        XCTAssertEqual(try isExcluded(firstFile), true,
                       "Second run must not regress the first file's flag")
    }

    // MARK: - Helpers

    /// Reads `isExcludedFromBackupKey` from disk via a freshly-constructed
    /// `URL` so that prior `resourceValues(forKeys:)` calls on the input URL
    /// instance cannot leak a stale cached value into the assertion.
    /// Found via test_run_flagsFilesAddedBetweenInvocations: querying
    /// before-and-after on the same URL was returning the pre-flip cache.
    private func isExcluded(_ url: URL) throws -> Bool {
        let fresh = URL(fileURLWithPath: url.path)
        let values = try fresh.resourceValues(forKeys: [.isExcludedFromBackupKey])
        return values.isExcludedFromBackup ?? false
    }
}
