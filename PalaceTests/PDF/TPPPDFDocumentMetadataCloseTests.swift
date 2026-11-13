//
//  TPPPDFDocumentMetadataCloseTests.swift
//  PalaceTests
//
//  Leaving the PDF reader saves a page the one-second debounce has not saved
//  yet, then asks the position writer to post its queued page now (PP-5595).
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceReadingPosition
import PalaceBookModel
@testable import Palace

@MainActor
final class TPPPDFDocumentMetadataCloseTests: XCTestCase {

    private var registry: TPPBookRegistryMock!
    private var writer: CloseRecordingWriter!
    private var sync: SyncSwitch!
    private var book: TPPBook!

    override func setUp() {
        super.setUp()
        registry = TPPBookRegistryMock()
        writer = CloseRecordingWriter()
        sync = SyncSwitch()
        book = TPPBookMocker.snapshotEPUB()
        registry.addBook(book, state: .downloadSuccessful)
    }

    /// Sync stays off during init so the server fetches in init do not run;
    /// tests turn it on afterwards when they need the server path.
    private func makeMetadata() -> TPPPDFDocumentMetadata {
        let sync = self.sync!
        return TPPPDFDocumentMetadata(
            with: book,
            bookRegistry: registry,
            positionWriter: writer,
            syncPermitted: { sync.isOn }
        )
    }

    /// A page turned just before close is posted, then the writer is flushed.
    func testStoreFinalPositionAndFlush_unsavedPageChange_postsItThenFlushes() async {
        let metadata = makeMetadata()
        sync.isOn = true
        metadata.currentPage = 9

        await metadata.storeFinalPositionAndFlush().value

        let events = await writer.events
        XCTAssertEqual(events, ["save", "flush:\(book.identifier)"])
        XCTAssertEqual(registry.location(forIdentifier: book.identifier)?.pageNumber, 9)
    }

    /// A page already saved is not posted again; close only flushes.
    func testStoreFinalPositionAndFlush_pageAlreadySaved_onlyFlushes() async {
        let metadata = makeMetadata()
        sync.isOn = true

        await metadata.storeFinalPositionAndFlush().value

        let events = await writer.events
        XCTAssertEqual(events, ["flush:\(book.identifier)"])
    }

    /// A page the debounce already saved is not posted again on close.
    func testStoreFinalPositionAndFlush_pageSavedByDebounce_onlyFlushes() async {
        let metadata = makeMetadata()
        sync.isOn = true
        metadata.currentPage = 9
        metadata.setCurrentPage(9)
        // The debounced save posts from its own task; wait until it reached the writer.
        for _ in 0..<200 where await !writer.events.contains("save") {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        await metadata.storeFinalPositionAndFlush().value

        let events = await writer.events
        XCTAssertEqual(events, ["save", "flush:\(book.identifier)"], "close must not post the debounced page again")
    }

    /// With sync off the page is saved on the device only, and the flush finds nothing to send.
    func testStoreFinalPositionAndFlush_syncOff_savesLocallyAndPostsNothing() async {
        let metadata = makeMetadata()
        metadata.currentPage = 9

        await metadata.storeFinalPositionAndFlush().value

        let events = await writer.events
        XCTAssertEqual(events, ["flush:\(book.identifier)"])
        XCTAssertEqual(registry.location(forIdentifier: book.identifier)?.pageNumber, 9)
    }
}

private final class SyncSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false
    var isOn: Bool {
        get { lock.lock(); defer { lock.unlock() }; return on }
        set { lock.lock(); defer { lock.unlock() }; on = newValue }
    }
}

/// Records saves and flushes in call order.
private actor CloseRecordingWriter: PositionWriter {
    private(set) var events: [String] = []

    func save(_ snapshot: PositionSnapshot) async throws -> ServerPositionID? {
        events.append("save")
        return nil
    }

    func load(for bookID: String) async throws -> PositionSnapshot? { nil }

    func cancel(for bookID: String) async {}

    func flush(for bookID: String) async {
        events.append("flush:\(bookID)")
    }
}
