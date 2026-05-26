//
//  DiskBudgetManagerTests.swift
//  PalaceTests
//
//  Coverage for DiskBudgetManager paths that the in-place
//  MyBooksDownloadCenterEvictionTests don't exercise: the per-device default
//  budget branch (small vs large device) and the inline directory-walk
//  helpers (directoryUsageBytes / listContentFilesSortedByLRU).
//
//  Eviction end-to-end behavior is still covered by
//  MyBooksDownloadCenterEvictionTests, which goes through MyBooksDownload
//  Center's delegators — those tests now exercise this manager.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class DiskBudgetManagerTests: XCTestCase {

    private var tempDir: URL!
    private var registry: TPPBookRegistryMock!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DiskBudgetManagerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        registry = TPPBookRegistryMock()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        registry = nil
        try super.tearDownWithError()
    }

    private func makeManager(isSmallDevice: Bool = false) -> DiskBudgetManager {
        DiskBudgetManager(
            bookRegistry: registry,
            accountsManager: AppContainer.production().accountsManager,
            bookFileManager: BookFileManager(bookRegistry: registry),
            isSmallDevice: { isSmallDevice }
        )
    }

    @discardableResult
    private func writeFile(named name: String, extension ext: String, bytes: Int) throws -> URL {
        let url = tempDir.appendingPathComponent(name).appendingPathExtension(ext)
        try Data(repeating: 0xAA, count: bytes).write(to: url)
        return url
    }

    // MARK: - defaultDiskBudgetBytes branch coverage

    func testDefaultBudget_onSmallDevice_returnsRelaxedSmallDeviceQuota() {
        let manager = makeManager(isSmallDevice: true)
        // 1.2 GB == 1_200 * 1024 * 1024
        XCTAssertEqual(manager.defaultDiskBudgetBytes(), 1_200 * 1024 * 1024)
    }

    func testDefaultBudget_onLargeDevice_returnsRelaxedLargeDeviceQuota() {
        let manager = makeManager(isSmallDevice: false)
        // 2.5 GB == 2_500 * 1024 * 1024
        XCTAssertEqual(manager.defaultDiskBudgetBytes(), 2_500 * 1024 * 1024)
    }

    // MARK: - directoryUsageBytes

    func testDirectoryUsageBytes_emptyDirectory_returnsZero() throws {
        let manager = makeManager()
        XCTAssertEqual(manager.directoryUsageBytes(at: tempDir), 0)
    }

    func testDirectoryUsageBytes_sumsAllNonHiddenFiles() throws {
        try writeFile(named: "a", extension: "epub", bytes: 1_000)
        try writeFile(named: "b", extension: "epub", bytes: 500)
        try writeFile(named: "c", extension: "epub", bytes: 250)

        let manager = makeManager()
        XCTAssertEqual(manager.directoryUsageBytes(at: tempDir), 1_750)
    }

    func testDirectoryUsageBytes_missingDirectory_returnsZero() throws {
        let bogus = tempDir.appendingPathComponent("does-not-exist")
        let manager = makeManager()
        XCTAssertEqual(manager.directoryUsageBytes(at: bogus), 0)
    }

    // MARK: - listContentFilesSortedByLRU

    func testListContentFilesSortedByLRU_returnsOldestFirst() throws {
        let now = Date()
        let oldest = try writeFile(named: "old", extension: "epub", bytes: 100)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-3_000)], ofItemAtPath: oldest.path)
        let middle = try writeFile(named: "mid", extension: "epub", bytes: 100)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-1_000)], ofItemAtPath: middle.path)
        let newest = try writeFile(named: "new", extension: "epub", bytes: 100)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: newest.path)

        let manager = makeManager()
        let sorted = manager.listContentFilesSortedByLRU(in: tempDir)

        XCTAssertEqual(sorted.map(\.lastPathComponent), [
            oldest.lastPathComponent,
            middle.lastPathComponent,
            newest.lastPathComponent
        ])
    }

    func testListContentFilesSortedByLRU_missingDirectory_returnsEmpty() {
        let bogus = tempDir.appendingPathComponent("missing")
        let manager = makeManager()
        XCTAssertEqual(manager.listContentFilesSortedByLRU(in: bogus), [])
    }
}
