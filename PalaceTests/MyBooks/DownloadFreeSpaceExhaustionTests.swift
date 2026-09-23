//
//  DownloadFreeSpaceExhaustionTests.swift
//  PalaceTests
//
//  Deep mutation-killing coverage for the disk-exhaustion / LRU
//  eviction policy (PP-4178). Two angles:
//
//    1. **Mid-download disk-out** — when `replaceBook` / `moveFile`
//       cannot write to the destination (read-only directory, full
//       volume simulated by a non-writable parent), the system must
//       surface a clean failure: registry state must NOT advance to
//       .downloadSuccessful, the partial garbage must not survive at
//       the destination, and the failure is logged via the delegate.
//
//    2. **Pre-download LRU eviction** — `DiskBudgetManager` runs the
//       eviction state machine that reclaims least-recently-used
//       content to keep disk usage under budget. We extend the existing
//       eviction suite with edge cases: zero-needed (budget exactly
//       hit), eviction with bytesToAdd overrun, LRU ordering stability,
//       and orphan-file reclamation.
//
//  Hermetic — every test scopes a unique temp dir under
//  NSTemporaryDirectory() and tears it down on exit. No network. No
//  Adobe RMSDK. Production code is read-only.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace
import PalaceBookModel

private let freeSpaceTestSession: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [HTTPStubURLProtocol.self]
    return URLSession(configuration: config)
}()

@MainActor
final class DownloadFreeSpaceExhaustionTests: XCTestCase {

    private var tempDir: URL!
    private var registry: TPPBookRegistryMock!
    private var mockDelegate: MockBackgroundDownloadDelegate!
    private var handler: BackgroundDownloadHandler!
    private var diskBudget: DiskBudgetManager!

    override func setUpWithError() throws {
        try super.setUpWithError()
        HTTPStubURLProtocol.reset()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DiskExhaustion-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        registry = TPPBookRegistryMock()
        mockDelegate = MockBackgroundDownloadDelegate(bookRegistry: registry)
        handler = BackgroundDownloadHandler(delegate: mockDelegate)
        diskBudget = DiskBudgetManager(
            bookRegistry: registry,
            accountsManager: AppContainer.production().accountsManager,
            bookFileManager: BookFileManager(bookRegistry: registry),
            fileManager: .default
        )
    }

    override func tearDownWithError() throws {
        // Restore writability before cleanup in case a test made tempDir
        // read-only to simulate ENOSPC.
        _ = try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempDir.path)
        try? FileManager.default.removeItem(at: tempDir)
        HTTPStubURLProtocol.reset()
        diskBudget = nil
        handler = nil
        mockDelegate = nil
        registry = nil
        tempDir = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func inertTask() -> URLSessionDownloadTask {
        freeSpaceTestSession.downloadTask(with: URL(string: "https://example.com/x")!)
    }

    private func makeBook(_ id: String = UUID().uuidString) -> TPPBook {
        let b = TPPBookMocker.mockBook(identifier: id, title: "T-\(id)", distributorType: .EpubZip)
        registry.addBook(b, state: .downloading)
        registry.myBooks.append(b)
        return b
    }

    @discardableResult
    private func writeFakeFile(for book: TPPBook, ext: String = "epub", bytes: Int, accessedAt: Date? = nil) throws -> URL {
        let name = book.identifier.sha256()
        let url = tempDir.appendingPathComponent(name).appendingPathExtension(ext)
        try Data(repeating: 0xCD, count: bytes).write(to: url)
        if let accessedAt {
            try FileManager.default.setAttributes([.modificationDate: accessedAt], ofItemAtPath: url.path)
        }
        return url
    }

    // MARK: - Disk-out during replaceBook (read-only parent directory)

    /// Simulates ENOSPC by making the destination's parent directory
    /// non-writable. `replaceBook` must NOT advance the registry to
    /// .downloadSuccessful and must surface the failure via the delegate.
    /// Mutation target: catching-and-swallowing the error then returning
    /// true would be caught by both the result and the state assertion.
    func testReplaceBook_destinationParentReadOnly_failsCleanly() throws {
        let book = makeBook()
        let readOnly = tempDir.appendingPathComponent("readonly", isDirectory: true)
        try FileManager.default.createDirectory(at: readOnly, withIntermediateDirectories: true)
        let dest = readOnly.appendingPathComponent("book.epub")
        // Pre-create the destination then strip write permissions on the parent
        try Data(repeating: 0xAA, count: 1_000).write(to: dest)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnly.path)
        mockDelegate.fileUrls[book.identifier] = dest

        let source = tempDir.appendingPathComponent("src.epub")
        try Data(repeating: 0xBB, count: 2_000).write(to: source)

        let result = handler.replaceBook(book, withFileAtURL: source, forDownloadTask: inertTask())

        // Restore so tearDown can clean up.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnly.path)

        XCTAssertFalse(result, "Disk-write failure must surface as a replaceBook failure")
        XCTAssertNotEqual(registry.state(for: book.identifier), .downloadSuccessful,
                          "Registry must NOT advance to .downloadSuccessful on disk-out")
        XCTAssertFalse(mockDelegate.logBookDownloadFailureCalls.isEmpty,
                       "Disk-write failure must be logged via logBookDownloadFailure for diagnostics")
    }

    /// moveFile (no-existing-dest path): same disk-out contract — failure
    /// is propagated, no phantom success, log surfaces the cause.
    func testMoveFile_destinationParentReadOnly_failsCleanly() throws {
        let book = makeBook()
        let readOnly = tempDir.appendingPathComponent("readonly2", isDirectory: true)
        try FileManager.default.createDirectory(at: readOnly, withIntermediateDirectories: true)
        let dest = readOnly.appendingPathComponent("first.epub")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnly.path)
        mockDelegate.fileUrls[book.identifier] = dest

        let source = tempDir.appendingPathComponent("src.epub")
        try Data(repeating: 0xEE, count: 1_500).write(to: source)

        let result = handler.moveFile(at: source, toDestinationForBook: book, forDownloadTask: inertTask())

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnly.path)

        XCTAssertFalse(result, "Disk-out during moveFile must surface a failure")
        XCTAssertNotEqual(registry.state(for: book.identifier), .downloadSuccessful)
        XCTAssertFalse(mockDelegate.logBookDownloadFailureCalls.isEmpty,
                       "Move failure must be logged via logBookDownloadFailure")
    }

    /// After a disk-out failure on moveFile, the source must be cleanly
    /// reported even if the destination doesn't exist. No partial garbage
    /// at the destination.
    func testMoveFile_disk_out_leavesNoPartialGarbageAtDestination() throws {
        let book = makeBook()
        let readOnly = tempDir.appendingPathComponent("ro3", isDirectory: true)
        try FileManager.default.createDirectory(at: readOnly, withIntermediateDirectories: true)
        let dest = readOnly.appendingPathComponent("garbage.epub")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnly.path)
        mockDelegate.fileUrls[book.identifier] = dest

        let source = tempDir.appendingPathComponent("src.epub")
        try Data(repeating: 0x77, count: 800).write(to: source)

        _ = handler.moveFile(at: source, toDestinationForBook: book, forDownloadTask: inertTask())

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnly.path)

        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path),
                       "Failed move must not leave a partial file at the destination")
    }

    // MARK: - LRU eviction edge cases (DiskBudgetManager)

    /// When current usage + bytesToAdd == budget exactly (delta = 0), no
    /// eviction runs. Mutation target: a `> 0` becoming `>= 0` would
    /// over-evict.
    func testEviction_atExactBudget_doesNothing() throws {
        let book = makeBook()
        let file = try writeFakeFile(for: book, bytes: 5_000)

        // Usage 5_000, adding 0, budget 5_000 -> needed = 0 -> no-op
        diskBudget.performDiskBudgetEviction(in: tempDir, adding: 0, budgetOverrideBytes: 5_000)

        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path),
                      "At-exact-budget (delta = 0) must NOT evict")
        XCTAssertEqual(registry.state(for: book.identifier), .downloading,
                       "At-exact-budget must NOT mutate the registry")
    }

    /// LRU stability: when only the OLDEST file is needed to make room,
    /// the middle/newest stay. Pins the sort order.
    func testEviction_evictsOnlyOldestWhenSufficient() throws {
        let oldest = makeBook("oldest")
        let middle = makeBook("middle")
        let newest = makeBook("newest")
        let now = Date()
        let oldestFile = try writeFakeFile(for: oldest, bytes: 3_000, accessedAt: now.addingTimeInterval(-5_000))
        let middleFile = try writeFakeFile(for: middle, bytes: 3_000, accessedAt: now.addingTimeInterval(-2_500))
        let newestFile = try writeFakeFile(for: newest, bytes: 3_000, accessedAt: now)

        // Total 9_000, budget 7_000 -> need to free 2_000 -> oldest (3_000) suffices.
        diskBudget.performDiskBudgetEviction(in: tempDir, adding: 0, budgetOverrideBytes: 7_000)

        XCTAssertFalse(FileManager.default.fileExists(atPath: oldestFile.path),
                       "Oldest must be evicted first")
        XCTAssertTrue(FileManager.default.fileExists(atPath: middleFile.path),
                      "Middle must survive when oldest alone suffices")
        XCTAssertTrue(FileManager.default.fileExists(atPath: newestFile.path),
                      "Newest must survive when oldest alone suffices")
        XCTAssertEqual(registry.state(for: oldest.identifier), .downloadNeeded)
        XCTAssertEqual(registry.state(for: middle.identifier), .downloading,
                       "Surviving middle must keep its prior state")
        XCTAssertEqual(registry.state(for: newest.identifier), .downloading,
                       "Surviving newest must keep its prior state")
    }

    /// bytesToAdd overrun: even with no existing usage, if the anticipated
    /// add exceeds the budget alone, no eviction happens because there's
    /// nothing to evict. Pin "graceful when bytesToAdd > budget on empty".
    func testEviction_bytesToAddExceedsBudgetButDirectoryEmpty_isNoOp() {
        // Empty directory, adding 100KB, budget 1KB. needed = 99KB but no
        // files. Should complete without crashing or mutating registry.
        diskBudget.performDiskBudgetEviction(in: tempDir, adding: 100_000, budgetOverrideBytes: 1_000)

        let book = makeBook()
        XCTAssertEqual(registry.state(for: book.identifier), .downloading,
                       "Eviction over empty dir must not mutate unrelated registry state")
    }

    /// Orphan files (no matching registry record) are still reclaimed for
    /// space, but the registry is untouched. Pins the hashToIdentifier
    /// lookup branch.
    func testEviction_orphan_reclaimedButRegistryUntouched() throws {
        let validBook = makeBook()
        try writeFakeFile(for: validBook, bytes: 1_000)

        let orphanURL = tempDir.appendingPathComponent("ffeeddccbbaa00").appendingPathExtension("epub")
        try Data(repeating: 0x44, count: 6_000).write(to: orphanURL)
        // Make orphan older so it's evicted first.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-9_000)], ofItemAtPath: orphanURL.path)

        // Budget 2_000 -> need to free 5_000 -> orphan alone suffices (6_000).
        diskBudget.performDiskBudgetEviction(in: tempDir, adding: 0, budgetOverrideBytes: 2_000)

        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanURL.path),
                       "Orphan file must be reclaimed for disk space")
        XCTAssertEqual(registry.state(for: validBook.identifier), .downloading,
                       "Unrelated valid book must keep its state when only the orphan is needed")
    }

    /// Total directory usage is reported even when there are skipped (LCP)
    /// files in it — usage accounting and eviction policy are separate
    /// concerns. Pin: bytes count includes everything, even files the
    /// eviction filter excludes.
    func testDirectoryUsage_countsLCPFilesEvenIfThoseFilesArePreservedDuringEviction() throws {
        let lcpBook = makeBook("lcp")
        let lcpFile = try writeFakeFile(for: lcpBook, ext: "lcpa", bytes: 4_000)

        let totalUsage = diskBudget.directoryUsageBytes(at: tempDir)
        XCTAssertEqual(totalUsage, 4_000,
                       "directoryUsageBytes must include LCP files for accounting")

        // But eviction must preserve them.
        diskBudget.performDiskBudgetEviction(in: tempDir, adding: 0, budgetOverrideBytes: 1_000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: lcpFile.path),
                      "LCP file must be preserved by eviction even though it's accounted in usage")
    }

    /// listContentFilesSortedByLRU must produce a stable oldest-first
    /// ordering when multiple files have distinct modification dates.
    /// Pins the sort direction (a < b → oldest first).
    func testLRUSort_producesOldestFirst() throws {
        let bookA = makeBook("a")
        let bookB = makeBook("b")
        let bookC = makeBook("c")
        let now = Date()
        let fA = try writeFakeFile(for: bookA, bytes: 100, accessedAt: now.addingTimeInterval(-10))
        let fB = try writeFakeFile(for: bookB, bytes: 100, accessedAt: now.addingTimeInterval(-100))
        let fC = try writeFakeFile(for: bookC, bytes: 100, accessedAt: now.addingTimeInterval(-50))

        let sorted = diskBudget.listContentFilesSortedByLRU(in: tempDir)

        XCTAssertEqual(sorted.first?.lastPathComponent, fB.lastPathComponent,
                       "Oldest (B, -100s) must sort first")
        XCTAssertEqual(sorted.last?.lastPathComponent, fA.lastPathComponent,
                       "Newest (A, -10s) must sort last")
        XCTAssertEqual(sorted.dropFirst().first?.lastPathComponent, fC.lastPathComponent,
                       "Middle (C, -50s) must sort between")
    }

    /// `defaultDiskBudgetBytes` flips on the small-device closure. Pin
    /// both branches with explicit injection of the closure. Mutation
    /// target: inverting the ternary would be caught.
    func testDefaultDiskBudget_smallDeviceBranch() {
        let small = DiskBudgetManager(
            bookRegistry: registry,
            accountsManager: AppContainer.production().accountsManager,
            isSmallDevice: { true }
        )
        XCTAssertEqual(small.defaultDiskBudgetBytes(), 1_200 * 1024 * 1024,
                       "Small-device budget must be 1.2 GB")
    }

    func testDefaultDiskBudget_normalDeviceBranch() {
        let normal = DiskBudgetManager(
            bookRegistry: registry,
            accountsManager: AppContainer.production().accountsManager,
            isSmallDevice: { false }
        )
        XCTAssertEqual(normal.defaultDiskBudgetBytes(), 2_500 * 1024 * 1024,
                       "Normal-device budget must be 2.5 GB")
    }
}
