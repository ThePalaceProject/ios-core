//
//  ButtonStateMonotonicClampTests.swift
//  PalaceTests
//
//  fix/audiobook-first-open-flicker (BUG B) — pins the NARROW "hold Listen
//  against a transient post-success `.downloading` re-read" latch that stops
//  the LCP first-open button flicker (Listen ↔ Cancel ↔ Listen), WITHOUT
//  stranding any real backward transition:
//    - HOLD:  .downloadSuccessful → .downloading  (the LCP early-ready artifact;
//             never a real transition — re-download routes through .downloadNeeded)
//    - PASS:  .downloadSuccessful → .downloadNeeded  (REAL eviction / re-fulfill —
//             DiskBudgetManager LRU sets .downloadNeeded directly; must show
//             Download, not a stranded Listen on an evicted file)
//    - PASS:  .downloading → .downloadNeeded  (real cancel / SAML login-cancel;
//             the optimistic-write #2 flicker is deferred — a state-only latch
//             can't tell it from a real cancel)
//    - DROP:  the latch resets on ANY non-(success/held-downloading) state, so
//             return (.unregistered) / .downloadFailed yield the real label.
//
//  Both the My Books cell (BookCellModel) and the book-detail half-sheet
//  (BookDetailViewModel) are covered. The button pipeline throttles 50ms on
//  RunLoop.main, so each assertion follows a `settleThrottle()` — the real-timing
//  style the existing BookCellModelStateTests use (no virtual-scheduler dep).
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
import Combine
import PalaceCatalog
@testable import Palace

@MainActor
final class ButtonStateMonotonicClampTests: XCTestCase {

    private var appContainer: AppContainer!
    private var mockRegistry: TPPBookRegistryMock!
    private var mockImageCache: MockImageCache!

    override func setUp() {
        super.setUp()
        appContainer = makeTestAppContainer()
        mockRegistry = TPPBookRegistryMock()
        mockImageCache = MockImageCache()
    }

    override func tearDown() {
        appContainer = nil
        mockRegistry = nil
        mockImageCache = nil
        super.tearDown()
    }

    // MARK: - BookCellModel — HOLD (the one safe transient)

    /// HOLD — Listen holds against a transient `.downloading` re-read.
    /// Mutates: removing the latch lets `.downloading` map to `.downloadInProgress`
    /// (Cancel) → fails.
    func testCell_listenHoldsAgainstTransientDownloading() {
        let (model, book) = makeCell(state: .downloadSuccessful)
        settleThrottle()
        XCTAssertEqual(model.stableButtonState, .downloadSuccessful, "precondition: Listen")

        mockRegistry.setState(.downloading, for: book.identifier)   // transient LCP re-read
        settleThrottle()

        XCTAssertEqual(model.stableButtonState, .downloadSuccessful,
                       "A transient .downloading after .downloadSuccessful is the LCP early-ready artifact — hold Listen, don't bounce to Cancel")
    }

    // MARK: - BookCellModel — PASS (real backward transitions must NOT be held)

    /// PASS — eviction (`.downloadSuccessful → .downloadNeeded`, DiskBudgetManager
    /// LRU) must show Download, NOT a stranded Listen on an evicted file.
    /// Mutates: a broad monotonicity clamp that held ANY backward move would keep
    /// `.downloadSuccessful` here → fails. (blast_radius finding.)
    func testCell_evictionToDownloadNeeded_showsDownload_notStrandedListen() {
        let (model, book) = makeCell(state: .downloadSuccessful)
        settleThrottle()
        XCTAssertEqual(model.stableButtonState, .downloadSuccessful, "precondition: Listen")

        mockRegistry.setState(.downloadNeeded, for: book.identifier)   // LRU eviction
        settleThrottle()

        XCTAssertEqual(model.stableButtonState, .downloadNeeded,
                       "A real .downloadSuccessful→.downloadNeeded eviction must surface Download — the narrow latch only holds the .downloading re-read, never .downloadNeeded")
    }

    /// PASS — a real `.downloading → .downloadNeeded` (cancel / SAML login-cancel)
    /// is not held (the optimistic-write #2 flicker is deferred). Documents that
    /// only the post-success re-read is clamped.
    func testCell_downloadingToDownloadNeeded_notClamped_showsDownload() {
        let (model, book) = makeCell(state: .downloading)
        settleThrottle()
        XCTAssertEqual(model.stableButtonState, .downloadInProgress, "precondition: downloading")

        mockRegistry.setState(.downloadNeeded, for: book.identifier)   // real cancel / SAML cancel
        settleThrottle()

        XCTAssertEqual(model.stableButtonState, .downloadNeeded,
                       "A .downloading→.downloadNeeded (real cancel) is NOT clamped — the latch only holds the post-success .downloading re-read")
    }

    // MARK: - BookCellModel — latch DROPS on reset states (proven via re-read)

    /// DROP — after Listen is returned (.unregistered), a SUBSEQUENT `.downloading`
    /// must NOT be held (the latch dropped). This is the mutant-killing reset test:
    /// deleting the `default: listenLatched = false` branch would hold Listen here.
    /// (qa finding — the prior reset tests never drove a post-reset progress read.)
    func testCell_returnThenReDownload_latchDropped_showsDownloading() {
        let (model, book) = makeCell(state: .downloadSuccessful)
        settleThrottle()

        mockRegistry.setState(.unregistered, for: book.identifier)     // return drops the latch
        settleThrottle()
        mockRegistry.setState(.downloading, for: book.identifier)      // fresh re-download
        settleThrottle()

        XCTAssertEqual(model.stableButtonState, .downloadInProgress,
                       "After return, the latch must have dropped — a fresh .downloading must show Cancel/downloadInProgress, NOT a held Listen")
    }

    /// DROP — same, via a terminal `.downloadFailed` reset then a re-download.
    func testCell_downloadFailedThenReDownload_latchDropped_showsDownloading() {
        let (model, book) = makeCell(state: .downloadSuccessful)
        settleThrottle()

        mockRegistry.setState(.downloadFailed, for: book.identifier)   // terminal — drops latch
        settleThrottle()
        XCTAssertEqual(model.stableButtonState, .downloadFailed, "downloadFailed must surface (not held)")

        mockRegistry.setState(.downloading, for: book.identifier)
        settleThrottle()
        XCTAssertEqual(model.stableButtonState, .downloadInProgress,
                       "After a terminal failure the latch must have dropped — a fresh .downloading must not be held as Listen")
    }

    /// Forward progression still advances (the latch never blocks forward moves).
    func testCell_forwardProgressionStillAdvances() {
        let (model, book) = makeCell(state: .downloadNeeded)
        settleThrottle()
        XCTAssertEqual(model.stableButtonState, .downloadNeeded, "precondition")
        mockRegistry.setState(.downloading, for: book.identifier)
        settleThrottle()
        XCTAssertEqual(model.stableButtonState, .downloadInProgress, "advances to downloading")
        mockRegistry.setState(.downloadSuccessful, for: book.identifier)
        settleThrottle()
        XCTAssertEqual(model.stableButtonState, .downloadSuccessful, "advances to Listen")
    }

    // MARK: - BookDetailViewModel — parity

    func testDetail_listenHoldsAgainstTransientDownloading() {
        let (vm, book) = makeDetail(state: .downloadSuccessful)
        settleThrottle()
        XCTAssertEqual(vm.stableButtonState, .downloadSuccessful, "precondition: Listen")
        mockRegistry.setState(.downloading, for: book.identifier)
        settleThrottle()
        XCTAssertEqual(vm.stableButtonState, .downloadSuccessful,
                       "Half-sheet: a transient .downloading after Listen holds Listen")
    }

    func testDetail_evictionToDownloadNeeded_showsDownload() {
        let (vm, book) = makeDetail(state: .downloadSuccessful)
        settleThrottle()
        mockRegistry.setState(.downloadNeeded, for: book.identifier)
        settleThrottle()
        XCTAssertEqual(vm.stableButtonState, .downloadNeeded,
                       "Half-sheet: a real eviction to .downloadNeeded must show Download, not a stranded Listen")
    }

    func testDetail_returnThenReDownload_latchDropped_showsDownloading() {
        let (vm, book) = makeDetail(state: .downloadSuccessful)
        settleThrottle()
        mockRegistry.setState(.unregistered, for: book.identifier)
        settleThrottle()
        mockRegistry.setState(.downloading, for: book.identifier)
        settleThrottle()
        XCTAssertEqual(vm.stableButtonState, .downloadInProgress,
                       "Half-sheet: after return the latch must drop — fresh .downloading shows Cancel, not held Listen")
    }

    func testDetail_forwardProgressionStillAdvances() {
        let (vm, book) = makeDetail(state: .downloadNeeded)
        settleThrottle()
        mockRegistry.setState(.downloading, for: book.identifier)
        settleThrottle()
        XCTAssertEqual(vm.stableButtonState, .downloadInProgress, "advances to downloading")
        mockRegistry.setState(.downloadSuccessful, for: book.identifier)
        settleThrottle()
        XCTAssertEqual(vm.stableButtonState, .downloadSuccessful, "advances to Listen")
    }

    // MARK: - Helpers

    private func makeBook(id: String = "clamp-book-1") -> TPPBook {
        TPPBook(dictionary: [
            "acquisitions": [TPPFake.genericAcquisition.dictionaryRepresentation()],
            "title": "Clamp Test Book",
            "categories": ["Fiction"],
            "id": id,
            "updated": "2024-01-01T00:00:00Z"
        ])!
    }

    private func makeCell(state: TPPBookState) -> (BookCellModel, TPPBook) {
        let book = makeBook()
        mockRegistry.addBook(book, state: state)
        let model = BookCellModel(book: book, imageCache: mockImageCache, bookRegistry: mockRegistry, downloadCenter: appContainer.downloadCenter, accountsManager: appContainer.accountsManager, samplePreviewManager: appContainer.samplePreviewManager, readerService: appContainer.readerService)
        return (model, book)
    }

    private func makeDetail(state: TPPBookState) -> (BookDetailViewModel, TPPBook) {
        let book = makeBook()
        mockRegistry.addBook(book, state: state)
        let vm = BookDetailViewModel(book: book, registry: mockRegistry, downloadCenter: appContainer.downloadCenter, accountsManager: appContainer.accountsManager, settings: TPPSettings(), opdsFeedService: appContainer.opdsFeedService, samplePreviewManager: appContainer.samplePreviewManager, readerService: appContainer.readerService)
        return (vm, book)
    }

    /// Lets the 50ms button-state throttle (RunLoop.main) emit.
    private func settleThrottle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.12))
    }
}
