//
//  MyBooksDownloadCenterEvictionTests.swift
//  PalaceTests
//
//  Coverage for the LRU eviction path in MyBooksDownloadCenter that previously
//  deleted downloaded book files without updating the registry. Pre-fix,
//  evicted books reverted to .downloadNeeded only on the next cold launch or
//  library switch (when BookRegistrySync.load() ran file-existence
//  reconciliation), leaving users confused.
//
//  These tests pin down the new contract:
//   - Evicting a file atomically flips the registry record to .downloadNeeded.
//   - LCP license/audiobook files (.lcpl/.lcpa) are preserved during eviction.
//   - Orphan files (no matching registry record) are still reclaimed but
//     don't mutate the registry.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace
import PalaceBookModel
@testable import PalaceBookRegistry

@MainActor
final class MyBooksDownloadCenterEvictionTests: XCTestCase {

    private var tempDir: URL!
    private var registry: TPPBookRegistryMock!
    private var center: MyBooksDownloadCenter!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("EvictionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        registry = TPPBookRegistryMock()
        center = MyBooksDownloadCenter(bookRegistry: registry)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        registry = nil
        center = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    @discardableResult
    private func writeFakeFile(
        for book: TPPBook,
        extension ext: String,
        bytes: Int,
        accessedAt: Date? = nil
    ) throws -> URL {
        let hashedName = book.identifier.sha256()
        let url = tempDir.appendingPathComponent(hashedName).appendingPathExtension(ext)
        let payload = Data(repeating: 0xAB, count: bytes)
        try payload.write(to: url)
        if let accessedAt {
            try FileManager.default.setAttributes(
                [.modificationDate: accessedAt],
                ofItemAtPath: url.path
            )
        }
        return url
    }

    @discardableResult
    private func writeOrphanFile(named name: String, extension ext: String, bytes: Int) throws -> URL {
        let url = tempDir.appendingPathComponent(name).appendingPathExtension(ext)
        try Data(repeating: 0x77, count: bytes).write(to: url)
        return url
    }

    private func seedRegistered(_ book: TPPBook) {
        registry.addBook(book, location: nil, state: .downloadSuccessful,
                         fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)
        // TPPBookRegistryMock.myBooks is a standalone stored property (not derived
        // from the registry dict) to preserve compatibility with other tests that
        // assign it directly. Our eviction code under test reads myBooks to build
        // the hashedIdentifier → bookIdentifier lookup, so we mirror the addBook
        // side-effect here.
        registry.myBooks.append(book)
    }

    // MARK: - Tests

    func testEviction_whenUnderBudget_doesNothing() throws {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        seedRegistered(book)
        let file = try writeFakeFile(for: book, extension: "epub", bytes: 2_000)

        // Budget is far above file size — no eviction needed
        center.performDiskBudgetEviction(in: tempDir, adding: 0, budgetOverrideBytes: 10_000_000)

        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path),
                      "File must not be evicted when usage is under budget")
        XCTAssertEqual(registry.state(for: book.identifier), .downloadSuccessful,
                       "Registry state must remain .downloadSuccessful when no eviction runs")
    }

    func testEviction_whenOverBudget_deletesFileAndFlipsRegistryToDownloadNeeded() throws {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        seedRegistered(book)
        let file = try writeFakeFile(for: book, extension: "epub", bytes: 5_000)

        // Budget of 1000 bytes forces the 5KB file out
        center.performDiskBudgetEviction(in: tempDir, adding: 0, budgetOverrideBytes: 1_000)

        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path),
                       "Evicted file must be deleted from disk")
        XCTAssertEqual(registry.state(for: book.identifier), .downloadNeeded,
                       "Registry must atomically flip to .downloadNeeded when file is evicted")
    }

    func testEviction_preservesLcpLicense() throws {
        // .lcpl is a license file; losing it means the user cannot unlock
        // subsequent re-downloads of the protected content. It must never
        // be a candidate for LRU eviction.
        let book = TPPBookMocker.mockBook(distributorType: .ReadiumLCP)
        seedRegistered(book)
        let license = try writeFakeFile(for: book, extension: "lcpl", bytes: 9_000)

        center.performDiskBudgetEviction(in: tempDir, adding: 0, budgetOverrideBytes: 1_000)

        XCTAssertTrue(FileManager.default.fileExists(atPath: license.path),
                      ".lcpl license must be preserved during eviction")
        XCTAssertEqual(registry.state(for: book.identifier), .downloadSuccessful,
                       "Registry state must stay .downloadSuccessful when license is preserved")
    }

    func testEviction_preservesLcpAudiobook_butEvictsEpubCompanion() throws {
        // .lcpa (LCP audiobook) is protected; a sibling .epub in the same
        // budget pass should be evicted and its registry record updated,
        // while the .lcpa survives. Documents the asymmetric file-type filter.
        let audiobookBook = TPPBookMocker.mockBook(distributorType: .AudiobookLCP)
        let epubBook = TPPBookMocker.mockBook(distributorType: .EpubZip)
        seedRegistered(audiobookBook)
        seedRegistered(epubBook)

        let audiobookFile = try writeFakeFile(for: audiobookBook, extension: "lcpa", bytes: 6_000)
        let epubFile = try writeFakeFile(for: epubBook, extension: "epub", bytes: 6_000)

        center.performDiskBudgetEviction(in: tempDir, adding: 0, budgetOverrideBytes: 5_000)

        XCTAssertTrue(FileManager.default.fileExists(atPath: audiobookFile.path),
                      ".lcpa must be preserved (file-type filter)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: epubFile.path),
                       ".epub must be evicted to reclaim space")
        XCTAssertEqual(registry.state(for: audiobookBook.identifier), .downloadSuccessful,
                       "Preserved audiobook stays .downloadSuccessful")
        XCTAssertEqual(registry.state(for: epubBook.identifier), .downloadNeeded,
                       "Evicted epub flips to .downloadNeeded")
    }

    func testEviction_withOrphanFile_deletesButSkipsRegistryMutation() throws {
        // A stray file with no corresponding registry record can happen after
        // a reset(account:) that partially ran, or a crash during download
        // cleanup. It should still be reclaimed for disk space but the
        // registry must not be touched (there's nothing to flip).
        let orphan = try writeOrphanFile(named: "deadbeef_no_book", extension: "epub", bytes: 5_000)
        let validBook = TPPBookMocker.mockBook(distributorType: .EpubZip)
        seedRegistered(validBook)

        center.performDiskBudgetEviction(in: tempDir, adding: 0, budgetOverrideBytes: 1_000)

        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path),
                       "Orphan file must be reclaimed")
        XCTAssertEqual(registry.state(for: validBook.identifier), .downloadSuccessful,
                       "Unrelated registry records must not be affected by orphan eviction")
    }

    func testEviction_multipleBooksOverBudget_evictsLRUFirstAndFlipsAllAffected() throws {
        // Three books, oldest-first by modification date. Budget forces two
        // out; the newest survives. Regression guard: the LRU order must
        // drive which books get flipped to .downloadNeeded.
        let oldest = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let middle = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let newest = TPPBookMocker.mockBook(distributorType: .EpubZip)
        for b in [oldest, middle, newest] { seedRegistered(b) }

        let now = Date()
        let oldestFile = try writeFakeFile(for: oldest, extension: "epub", bytes: 4_000,
                                           accessedAt: now.addingTimeInterval(-3_000))
        let middleFile = try writeFakeFile(for: middle, extension: "epub", bytes: 4_000,
                                           accessedAt: now.addingTimeInterval(-2_000))
        let newestFile = try writeFakeFile(for: newest, extension: "epub", bytes: 4_000,
                                           accessedAt: now)

        // Total 12KB, budget 5KB → must free ~7KB → oldest + middle (8KB) evicted
        center.performDiskBudgetEviction(in: tempDir, adding: 0, budgetOverrideBytes: 5_000)

        XCTAssertFalse(FileManager.default.fileExists(atPath: oldestFile.path),
                       "Oldest file must be evicted first")
        XCTAssertFalse(FileManager.default.fileExists(atPath: middleFile.path),
                       "Middle file must be evicted second to meet budget")
        XCTAssertTrue(FileManager.default.fileExists(atPath: newestFile.path),
                      "Newest file must survive eviction")

        XCTAssertEqual(registry.state(for: oldest.identifier), .downloadNeeded)
        XCTAssertEqual(registry.state(for: middle.identifier), .downloadNeeded)
        XCTAssertEqual(registry.state(for: newest.identifier), .downloadSuccessful,
                       "Surviving book must retain .downloadSuccessful")
    }

    func testEviction_whenAddingAnticipatedBytesPushesOverBudget_makesRoom() throws {
        // Caller plans to add a large file next; enforce must free room to
        // accommodate it. This exercises the `adding:` parameter which the
        // previous pre-download call-gate depended on.
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        seedRegistered(book)
        let file = try writeFakeFile(for: book, extension: "epub", bytes: 2_000)

        // Current usage 2KB; adding 4KB hypothetical; budget 3KB. Over by 3KB.
        center.performDiskBudgetEviction(in: tempDir, adding: 4_000, budgetOverrideBytes: 3_000)

        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path),
                       "Eviction must also consider bytesToAdd when computing overrun")
        XCTAssertEqual(registry.state(for: book.identifier), .downloadNeeded)
    }
}
