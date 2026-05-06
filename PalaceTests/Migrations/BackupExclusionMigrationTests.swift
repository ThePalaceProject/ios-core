//
//  BackupExclusionMigrationTests.swift
//  PalaceTests
//
//  Tests the iCloud backup exclusion helpers used by the 3.1.0 migration
//  (PP-4179): downloaded books, audiobook chapter mp3s, logs, network queue,
//  and accounts state must not be replicated into the patron's iCloud quota.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

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

    // MARK: - excludeFromBackup(_:)

    func test_excludeFromBackup_setsFlag_onExistingDirectory() throws {
        let dir = sandbox.appendingPathComponent("subdir")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertEqual(try isExcluded(dir), false,
                       "Pre-state: a freshly created directory must not be excluded from backup")

        XCTAssertTrue(BackupExclusionMigration.excludeFromBackup(dir),
                      "excludeFromBackup must return true on success")

        XCTAssertEqual(try isExcluded(dir), true,
                       "Directory must report isExcludedFromBackup == true after the helper runs")
    }

    func test_excludeFromBackup_setsFlag_onExistingFile() throws {
        let file = sandbox.appendingPathComponent("file.txt")
        try Data("hello".utf8).write(to: file)
        XCTAssertEqual(try isExcluded(file), false)

        XCTAssertTrue(BackupExclusionMigration.excludeFromBackup(file))

        XCTAssertEqual(try isExcluded(file), true)
    }

    func test_excludeFromBackup_returnsFalse_whenURLDoesNotExist() {
        let missing = sandbox.appendingPathComponent("does-not-exist-\(UUID())")
        XCTAssertFalse(BackupExclusionMigration.excludeFromBackup(missing),
                       "Missing URLs must report failure rather than silently succeed")
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

    func test_run_handlesNonexistentRoot_withoutCrashing() {
        let missing = sandbox.appendingPathComponent("missing-root")
        // Must not throw, must not crash. If a root doesn't exist (e.g. a fresh
        // install with no audiobook downloads), the migration is simply a no-op
        // for that root.
        BackupExclusionMigration.run(directories: [missing])
    }

    func test_run_isIdempotent() throws {
        let file = sandbox.appendingPathComponent("payload.bin")
        try Data().write(to: file)

        BackupExclusionMigration.run(directories: [sandbox])
        BackupExclusionMigration.run(directories: [sandbox])

        XCTAssertEqual(try isExcluded(file), true)
    }

    // MARK: - makeDirectoryExcluded(at:) — forward-fix helper

    /// Forward-fix helper used at every `createDirectory` call site in the
    /// app. It must (a) create the directory if missing, and (b) set the
    /// exclusion flag whether the directory is new or pre-existing.
    func test_makeDirectoryExcluded_createsDirAndSetsFlag() throws {
        let dir = sandbox.appendingPathComponent("created-by-helper")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path),
                       "Pre-state: dir must not exist before the helper runs")

        XCTAssertTrue(BackupExclusionMigration.makeDirectoryExcluded(at: dir))

        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path),
                      "Helper must create the directory if missing")
        XCTAssertEqual(try isExcluded(dir), true,
                       "Newly-created directory must be flagged at creation time")
    }

    func test_makeDirectoryExcluded_isIdempotent_onPreExistingDirectory() throws {
        let dir = sandbox.appendingPathComponent("existing")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Note: pre-existing dir starts unflagged. The helper must flip it.

        XCTAssertTrue(BackupExclusionMigration.makeDirectoryExcluded(at: dir))
        XCTAssertTrue(BackupExclusionMigration.makeDirectoryExcluded(at: dir),
                      "Second call must succeed and remain idempotent")

        XCTAssertEqual(try isExcluded(dir), true)
    }

    func test_makeDirectoryExcluded_failsCleanly_whenPathBlockedByFile() throws {
        // If something else has already written a regular file at the target
        // path, the helper must not crash. It should report failure so the
        // caller can decide how to handle it.
        let blocker = sandbox.appendingPathComponent("blocked")
        try Data().write(to: blocker)

        XCTAssertFalse(BackupExclusionMigration.makeDirectoryExcluded(at: blocker),
                       "Helper must fail cleanly when a file blocks the target path")
    }

    // MARK: - Helpers

    private func isExcluded(_ url: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
        return values.isExcludedFromBackup ?? false
    }
}
