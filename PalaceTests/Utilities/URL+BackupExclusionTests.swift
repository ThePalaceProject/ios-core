//
//  URL+BackupExclusionTests.swift
//  PalaceTests
//
//  Tests the URL.excludeFromBackup() primitive used at directory-creation
//  sites and by the 3.1.0 upgrade pass (PP-4179).
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class URLBackupExclusionTests: XCTestCase {

    private var sandbox: URL!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("URLBackupExclusionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
        sandbox = nil
    }

    func test_excludeFromBackup_setsFlag_onExistingDirectory() throws {
        let dir = sandbox.appendingPathComponent("subdir")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertEqual(try isExcluded(dir), false,
                       "Pre-state: a freshly created directory must not be excluded from backup")

        XCTAssertTrue(dir.excludeFromBackup(),
                      "excludeFromBackup must return true on success")

        XCTAssertEqual(try isExcluded(dir), true,
                       "Directory must report isExcludedFromBackup == true after the helper runs")
    }

    func test_excludeFromBackup_setsFlag_onExistingFile() throws {
        let file = sandbox.appendingPathComponent("file.txt")
        try Data("hello".utf8).write(to: file)
        XCTAssertEqual(try isExcluded(file), false)

        XCTAssertTrue(file.excludeFromBackup())

        XCTAssertEqual(try isExcluded(file), true)
    }

    func test_excludeFromBackup_returnsFalse_whenURLDoesNotExist() {
        let missing = sandbox.appendingPathComponent("does-not-exist-\(UUID())")
        XCTAssertFalse(missing.excludeFromBackup(),
                       "Missing URLs must report failure rather than silently succeed")
    }

    // MARK: - Helpers

    /// Reads `isExcludedFromBackupKey` from disk via a freshly-constructed
    /// `URL` so that prior `resourceValues(forKeys:)` calls on the input URL
    /// instance cannot leak a stale cached value into the assertion.
    private func isExcluded(_ url: URL) throws -> Bool {
        let fresh = URL(fileURLWithPath: url.path)
        let values = try fresh.resourceValues(forKeys: [.isExcludedFromBackupKey])
        return values.isExcludedFromBackup ?? false
    }
}
