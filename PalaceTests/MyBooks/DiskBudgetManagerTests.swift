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

@MainActor
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
        // 1.2 GB == 1_200 * 1024 * 1024. Pair-assert that the value is strictly
        // less than the large-device value AND that calling twice returns the
        // same value (pure function) so a mutation that introduces caching
        // bugs or copies the large-device branch into both arms is caught.
        let manager = makeManager(isSmallDevice: true)
        let large = makeManager(isSmallDevice: false)
        let first = manager.defaultDiskBudgetBytes()
        let second = manager.defaultDiskBudgetBytes()
        XCTAssertEqual(first, 1_200 * 1024 * 1024,
                       "Small-device default budget must be exactly 1.2 GB")
        XCTAssertEqual(first, second,
                       "defaultDiskBudgetBytes must be deterministic — repeated calls must agree")
        XCTAssertLessThan(first, large.defaultDiskBudgetBytes(),
                          "Small-device quota must be strictly less than large-device quota")
    }

    func testDefaultBudget_onLargeDevice_returnsRelaxedLargeDeviceQuota() {
        // 2.5 GB == 2_500 * 1024 * 1024. Pair-assert that the value is strictly
        // greater than the small-device value so a mutation that copies the
        // small-device branch into both arms is caught.
        let manager = makeManager(isSmallDevice: false)
        let small = makeManager(isSmallDevice: true)
        XCTAssertEqual(manager.defaultDiskBudgetBytes(), 2_500 * 1024 * 1024,
                       "Large-device default budget must be exactly 2.5 GB")
        XCTAssertGreaterThan(manager.defaultDiskBudgetBytes(), small.defaultDiskBudgetBytes(),
                             "Large-device quota must be strictly greater than small-device quota")
    }

    // MARK: - directoryUsageBytes

    func testDirectoryUsageBytes_emptyDirectory_returnsZero() throws {
        // Pair-assert that the directory IS empty before and after the call
        // (no side-effects), and that the bytes returned are exactly zero.
        // A mutation that returns 1, -1, or a magic number would fail.
        let manager = makeManager()
        let before = try FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
        XCTAssertEqual(before.count, 0, "Precondition: tempDir is empty")
        XCTAssertEqual(manager.directoryUsageBytes(at: tempDir), 0,
                       "Empty directory must report 0 bytes used")
        let after = try FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
        XCTAssertEqual(after.count, 0, "Postcondition: tempDir is still empty — no side-effect")
    }

    func testDirectoryUsageBytes_sumsAllNonHiddenFiles() throws {
        try writeFile(named: "a", extension: "epub", bytes: 1_000)
        try writeFile(named: "b", extension: "epub", bytes: 500)
        try writeFile(named: "c", extension: "epub", bytes: 250)

        let manager = makeManager()
        XCTAssertEqual(manager.directoryUsageBytes(at: tempDir), 1_750)
    }

    func testDirectoryUsageBytes_missingDirectory_returnsZero() throws {
        // Pair-assert that we DO confirm the directory is missing first, and
        // that the call still doesn't create it as a side-effect. A mutation
        // that throws instead of returning 0 would crash the test process.
        let bogus = tempDir.appendingPathComponent("does-not-exist")
        XCTAssertFalse(FileManager.default.fileExists(atPath: bogus.path),
                       "Precondition: bogus directory does not exist")
        let manager = makeManager()
        XCTAssertEqual(manager.directoryUsageBytes(at: bogus), 0,
                       "Missing directory must report 0 bytes used — defensive default-deny")
        XCTAssertFalse(FileManager.default.fileExists(atPath: bogus.path),
                       "Postcondition: directoryUsageBytes must not accidentally create the directory")
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
        // Pair-assert the missing-directory precondition AND that the call
        // doesn't create the directory as a side-effect. Also call twice to
        // pin idempotency — a mutation that lazily creates the directory
        // and then lists it would fail the second-call assertion.
        let bogus = tempDir.appendingPathComponent("missing")
        XCTAssertFalse(FileManager.default.fileExists(atPath: bogus.path),
                       "Precondition: bogus directory does not exist")
        let manager = makeManager()
        XCTAssertEqual(manager.listContentFilesSortedByLRU(in: bogus), [],
                       "Missing directory must list as empty — defensive default-deny")
        XCTAssertEqual(manager.listContentFilesSortedByLRU(in: bogus), [],
                       "Second call must also be empty — call must not create the directory as a side-effect")
        XCTAssertFalse(FileManager.default.fileExists(atPath: bogus.path),
                       "Postcondition: bogus directory still does not exist")
    }
}
