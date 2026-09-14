//
//  MyBooksDownloadCenterCachePurgeTests.swift
//  PalaceTests
//
//  PP-5127 — decrypted audiobook chapters outlived the loan.
//
//  Protected (LCP) audiobooks are decrypted chapter-by-chapter into flat files
//  in the app's Caches directory, named for a hash of each track's path. Once
//  the licence is gone those paths cannot be reconstructed, so
//  `LocalBookContentService` cannot delete them per track and skips the
//  toolkit cleanup that would have.
//
//  The in-app Return path got away with that because `BookReturnService` also
//  fires a forced `purgeAllAudiobookCaches`. Every OTHER way a loan ends —
//  expiry, a return from another device, a librarian revoking it, any
//  server-driven reconciliation — runs only the per-book delete, so the
//  decrypted audio stayed on disk after the book left the shelf.
//
//  Measured 2026-09-14 on an A1QA loan: a title returned outside the app left
//  51 playable MP3 files and 1.1 GB behind. The same shape of title returned
//  inside the app cleared 154 files to zero. Same book, same bytes; the only
//  difference was which code path ended the loan.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace
import PalaceBookModel
@testable import PalaceBookRegistry

@MainActor
final class MyBooksDownloadCenterCachePurgeTests: XCTestCase {

    private var registry: TPPBookRegistryMock!
    private var center: MyBooksDownloadCenter!
    private var cachesDir: URL!
    private var writtenFiles: [URL] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        registry = TPPBookRegistryMock()
        center = MyBooksDownloadCenter(bookRegistry: registry)
        cachesDir = try XCTUnwrap(
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        )
    }

    override func tearDownWithError() throws {
        // Never leave test audio behind: a stray .mp3 in Caches is exactly what
        // the sweep under test deletes, so an orphan here would silently change
        // a later test's starting conditions.
        for url in writtenFiles { try? FileManager.default.removeItem(at: url) }
        writtenFiles = []
        registry = nil
        center = nil
        cachesDir = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    /// Stands in for a decrypted chapter: production writes these as
    /// `sha256(track path).mp3` at the top level of Caches, so only the
    /// extension and the location matter to the sweep.
    @discardableResult
    private func writeDecryptedChapter() throws -> URL {
        let url = cachesDir
            .appendingPathComponent("PP5127-\(UUID().uuidString)")
            .appendingPathExtension("mp3")
        try Data(repeating: 0xAB, count: 64).write(to: url)
        writtenFiles.append(url)
        return url
    }

    @discardableResult
    private func seedAudiobook(state: TPPBookState) -> TPPBook {
        let book = TPPBookMocker.mockBook(distributorType: .OpenAccessAudiobook)
        registry.addBook(book, location: nil, state: state,
                         fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)
        // `myBooks` is the shelf the guard reads; the mock keeps it separate
        // from its identifier-keyed record store, so set it explicitly.
        registry.myBooks = registry.myBooks + [book]
        return book
    }

    // MARK: - The defect

    func testDeleteLocalContent_whenTheDepartingBookIsStillRegistered_purgesItsChapters() throws {
        // The shape that matters most, and the one that nearly shipped broken.
        // Of the three callers on this path only `BookRegistrySync` clears the
        // registry record before deleting; `TPPBookRegistryAsync` and the
        // expired-book eviction in `MyBooksViewModel` both delete while the
        // departing book is still recorded as `.downloadSuccessful`. A guard
        // that simply asks "is any audiobook active?" sees the book being
        // removed, calls it active, and declines — leaving the sweep a no-op
        // on two of the three paths it exists to fix.
        let chapter = try writeDecryptedChapter()
        let departing = seedAudiobook(state: .downloadSuccessful)

        center.deleteLocalContent(for: departing.identifier)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: chapter.path),
            "A book on its way out must not count itself as a reason to keep its own chapters"
        )
    }

    func testDeleteLocalContentForBook_afterTheRecordIsGone_purgesItsChapters() throws {
        // The book-based overload is what `BookRegistrySync` uses, because by
        // then the record has already gone and cannot be looked up by
        // identifier. It is the exact path that leaked 1.1 GB in the field, so
        // it gets its own assertion rather than riding on its sibling's.
        let chapter = try writeDecryptedChapter()
        let departing = TPPBookMocker.mockBook(distributorType: .OpenAccessAudiobook)

        center.deleteLocalContent(forBook: departing)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: chapter.path),
            "The reconciliation path deletes by book, and must take the decrypted audio with it"
        )
    }

    // MARK: - The safety property

    func testDeleteLocalContent_whileAnotherAudiobookIsOnTheShelf_keepsItsChapters() throws {
        // The sweep is deliberately blanket — it cannot tell one book's
        // chapters from another's, because the filenames hash track paths that
        // are unrecoverable once the licence is gone. What stops it evicting a
        // book the patron still has is the guard, so the guard is the thing
        // worth pinning: without it this fix would trade a storage leak for
        // re-downloading someone's current audiobook.
        let chapter = try writeDecryptedChapter()
        seedAudiobook(state: .downloadSuccessful)
        let departing = seedAudiobook(state: .downloadSuccessful)

        center.deleteLocalContent(for: departing.identifier)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: chapter.path),
            "Removing one book must not evict the chapters of an audiobook still on the shelf"
        )
    }

    func testDeleteLocalContent_whileAnotherAudiobookIsDownloading_keepsItsChapters() throws {
        // `.downloading` is in the guard's active set for a reason: chapters
        // are written as they decrypt, so sweeping mid-download would delete
        // work in progress underneath the player.
        let chapter = try writeDecryptedChapter()
        seedAudiobook(state: .downloading)
        let departing = seedAudiobook(state: .downloadSuccessful)

        center.deleteLocalContent(for: departing.identifier)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: chapter.path),
            "A sweep must not race a download that is still writing decrypted chapters"
        )
    }
}
