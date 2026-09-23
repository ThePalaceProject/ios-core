//
//  MyBooksDownloadCenterOfflineTests.swift
//  PalaceTests
//
//  PP-4114 follow-up coverage. PR #901 fixed the BORROW path's reachability
//  handling on `BookCellModel` (pre-flight check + dropFirst() subscription
//  on `connectivityPublisher`) so a network drop while waiting on the borrow
//  response clears the spinner and surfaces a retryable alert.
//
//  This suite covers the parallel gap on `MyBooksDownloadCenter`: when a
//  download is ALREADY IN PROGRESS and reachability drops, the URLSession
//  download task can sit in flight indefinitely. The background session is
//  configured with `waitsForConnectivity = false`, but no explicit
//  `timeoutIntervalForRequest` (defaults to 60s) and no
//  `timeoutIntervalForResource` (defaults to 7 days) — and on simulators /
//  Wi-Fi-to-Wi-Fi-loss transitions the OS may not surface
//  `didCompleteWithError` for the entire 60s window. Pre-fix UX: spinner
//  spins forever, no alert.
//
//  Fix mirrors the BookCellModel pattern from PR #901: subscribe MBDC to
//  `reachability.connectivityPublisher.dropFirst().filter { !$0 }` and on
//  drop, fail every active download (state → .downloadFailed, retryable
//  alert via DownloadAlertPresenter) and cancel the URLSession task.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import Combine
import XCTest
@testable import Palace
import PalaceBookModel

@MainActor
final class MyBooksDownloadCenterOfflineTests: XCTestCase {

    private var mockRegistry: TPPBookRegistryMock!
    private var mockReachability: MockReachability!
    private var stateManager: DownloadStateManager!

    override func setUp() {
        super.setUp()
        mockRegistry = TPPBookRegistryMock()
        mockReachability = MockReachability(initiallyConnected: true)
        stateManager = DownloadStateManager()
    }

    override func tearDown() {
        stateManager = nil
        mockReachability = nil
        mockRegistry = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeBook(id: String = "pp-4114-active") -> TPPBook {
        TPPBook(dictionary: [
            "acquisitions": [TPPFake.genericAcquisition.dictionaryRepresentation()],
            "title": "Mid-flight Drop",
            "categories": ["Fiction"],
            "id": id,
            "updated": "2024-01-01T00:00:00Z"
        ])!
    }

    /// Populate the state manager with a fake in-flight download. Mirrors
    /// what production wiring does inside addDownloadTask + the URLSession
    /// progress callbacks — without involving an actual network task.
    private func registerActiveDownload(book: TPPBook, taskIdentifier: Int = 42) async -> MockURLSessionDownloadTask {
        let task = MockURLSessionDownloadTask(taskIdentifier: taskIdentifier)
        let info = MyBooksDownloadInfo(
            downloadProgress: 0.3,
            downloadTask: task,
            rightsManagement: .none
        )
        await stateManager.taskIdentifierToBook.set(taskIdentifier, value: book)
        await stateManager.bookIdentifierToDownloadInfo.set(book.identifier, value: info)
        return task
    }

    /// Deterministically joins the network-loss failure handling instead of
    /// polling the registry against a wall-clock deadline (which starves under
    /// CI oversubscription). The reachability sink is scheduled on
    /// `RunLoop.main` (`.receive(on:)`), so one main-queue drain flushes the
    /// sink → `failActiveDownloadsForNetworkLoss()` spawns its Task and
    /// retains it on `lastNetworkLossFailureTask`; awaiting that Task's
    /// `.value` joins the state-transition + alert work to completion.
    private func awaitNetworkLossHandling(on center: MyBooksDownloadCenter) async {
        // Two drains: the reachability sink is delivered via
        // `.receive(on: RunLoop.main)` (a RunLoop.perform source), scheduled by
        // `simulate(...)` BEFORE this helper's own DispatchQueue.main.async
        // fulfill block. Run-loop ordering between the two source types isn't
        // strictly FIFO, so the first drain may return before the sink has run
        // and spawned the failure Task. The second drain guarantees the run
        // loop has turned again after the sink was scheduled, so the Task is
        // retained by the time we read it. Then join it to completion.
        await drainMainQueueAsync()
        await drainMainQueueAsync()
        await center.lastNetworkLossFailureTask?.value
    }

    // MARK: - Mid-flight drop

    /// PP-4114 mid-flight regression: with a download in progress, a
    /// reachability transition to offline must mark the book .downloadFailed
    /// within a deterministic window — not wait on iOS's URLSession defaults
    /// (60s per-request, 7 days per-resource).
    func testReachabilityDrop_DuringActiveDownload_FailsBookWithinDeterministicWindow() async {
        let book = makeBook()
        mockRegistry.addBook(book, state: .downloading)
        let task = await registerActiveDownload(book: book)

        let center = MyBooksDownloadCenter(
            bookRegistry: mockRegistry,
            stateManager: stateManager,
            reachability: mockReachability
        )
        await drainMainQueueAsync()
        XCTAssertEqual(mockRegistry.state(for: book.identifier), .downloading,
                       "precondition: book starts downloading")

        mockReachability.simulate(connected: false)
        await awaitNetworkLossHandling(on: center)

        XCTAssertEqual(mockRegistry.state(for: book.identifier), .downloadFailed,
                       "PP-4114: mid-flight network drop must transition active downloads to .downloadFailed")
        XCTAssertEqual(task.state, .canceling,
                       "Active URLSession task must be cancelled so iOS frees the connection")
        _ = center  // retain through the test
    }

    /// Multiple active downloads must all transition. Catches a fix that
    /// only handles the first task in the dictionary.
    func testReachabilityDrop_DuringMultipleActiveDownloads_FailsEach() async {
        let bookA = makeBook(id: "active-a")
        let bookB = makeBook(id: "active-b")
        mockRegistry.addBook(bookA, state: .downloading)
        mockRegistry.addBook(bookB, state: .downloading)
        let taskA = await registerActiveDownload(book: bookA, taskIdentifier: 100)
        let taskB = await registerActiveDownload(book: bookB, taskIdentifier: 101)

        let center = MyBooksDownloadCenter(
            bookRegistry: mockRegistry,
            stateManager: stateManager,
            reachability: mockReachability
        )
        await drainMainQueueAsync()

        mockReachability.simulate(connected: false)
        await awaitNetworkLossHandling(on: center)

        XCTAssertEqual(mockRegistry.state(for: bookA.identifier), .downloadFailed)
        XCTAssertEqual(mockRegistry.state(for: bookB.identifier), .downloadFailed)
        XCTAssertEqual(taskA.state, .canceling)
        XCTAssertEqual(taskB.state, .canceling)
        _ = center
    }

    /// dropFirst() guard: the CurrentValueSubject's initial-value replay
    /// must not be treated as a drop, so a freshly-created center on a
    /// fully-online sim doesn't immediately fail any active downloads.
    func testInit_WithReachabilityConnected_DoesNotFailExistingDownloads() async {
        let book = makeBook(id: "stays-downloading")
        mockRegistry.addBook(book, state: .downloading)
        _ = await registerActiveDownload(book: book)

        let center = MyBooksDownloadCenter(
            bookRegistry: mockRegistry,
            stateManager: stateManager,
            reachability: mockReachability
        )
        // dropFirst() suppresses the CurrentValueSubject's initial `true`, so
        // NO failure Task is ever spawned — assert the absence of the effect
        // by draining the main queue (flushes any RunLoop.main-scheduled sink)
        // and joining any spawned failure Task (nil here → no-op). No fixed
        // sleep: if the guard regressed and a Task WAS spawned, the join would
        // run it and the assertion would then catch the flip.
        await drainMainQueueAsync()
        await center.lastNetworkLossFailureTask?.value

        XCTAssertEqual(mockRegistry.state(for: book.identifier), .downloading,
                       "Initial replay of connectivityPublisher's true value must NOT trip the failure path")
        _ = center
    }

    // MARK: - Retry-while-offline pre-flight

    /// PP-4114 follow-up: tapping Retry on the failure alert while still
    /// offline must error out IMMEDIATELY, not start a fresh URLSession task
    /// that spins until iOS surfaces a timeout. The Retry button routes
    /// through DownloadAlertPresenter.makeRetryAction → MBDC.startDownload,
    /// which bypasses BookCellModel.bindReachability's pre-flight. Without
    /// the guard added in MBDC.startDownload, tapping Retry from an
    /// already-offline state reproduces the original bug: spinner forever,
    /// no alert.
    func testStartDownload_WhenOffline_FailsImmediatelyWithoutSpawningTask() async {
        let offlineReachability = MockReachability(initiallyConnected: false)
        let book = makeBook(id: "retry-while-offline")
        mockRegistry.addBook(book, state: .downloadFailed)

        let center = MyBooksDownloadCenter(
            bookRegistry: mockRegistry,
            stateManager: stateManager,
            reachability: offlineReachability
        )
        await drainMainQueueAsync()

        // Simulate the Retry-button path — direct call to startDownload.
        // The offline pre-flight fails the book SYNCHRONOUSLY:
        // startDownload → failDownloadWithAlert → bookRegistry.addBook(state:
        // .downloadFailed) runs before any Task hop and before addDownloadTask,
        // so both the state and the empty-active-dict assertions hold with no
        // wait.
        center.startDownload(for: book, withRequest: nil)

        XCTAssertEqual(mockRegistry.state(for: book.identifier), .downloadFailed,
                       "PP-4114: startDownload while offline must short-circuit to .downloadFailed, not spawn a hanging URLSession task")
        // Active dictionaries must remain empty — the pre-flight short-circuit
        // bails out BEFORE addDownloadTask runs, so no task is registered.
        let activeCount = await stateManager.taskIdentifierToBook.values().count
        XCTAssertEqual(activeCount, 0,
                       "Pre-flight bail must not register any URLSession task")
    }

    /// A reachability transition with no active downloads is a harmless
    /// no-op. Catches a fix that crashes or asserts when the active-set
    /// is empty.
    func testReachabilityDrop_WithNoActiveDownloads_IsNoOp() async {
        // MISSING-001-OK: crash-guard — verifies the empty-active-set branch
        // is a no-op (does NOT crash on empty dictionary lookup). Observable
        // contract is "no crash, no state mutation".
        let center = MyBooksDownloadCenter(
            bookRegistry: mockRegistry,
            stateManager: stateManager,
            reachability: mockReachability
        )
        await drainMainQueueAsync()

        mockReachability.simulate(connected: false)
        // Join the failure handling (drains the sink, then awaits the spawned
        // Task which early-returns on the empty active set) instead of sleeping.
        await awaitNetworkLossHandling(on: center)
        // No expectations — this test passes if nothing crashes or asserts.
        _ = center
    }

    // MARK: - Stale-entry regression (airplane-mode flips downloaded books)

    /// Regression of PP-4114's airplane-mode handler.
    ///
    /// Reproduces the user-visible iPad bug: previously-downloaded books
    /// show "The download could not be completed." and the Read button
    /// disappears the moment airplane mode is toggled.
    ///
    /// Root cause: `taskIdentifierToBook` is never cleaned up on download
    /// success, so completed books leave stale `(taskId, book)` entries.
    /// `failActiveDownloadsForNetworkLoss()` iterates that map and calls
    /// `failDownloadWithAlert` on every entry — regardless of whether the
    /// book is actually downloading. A `.downloadSuccessful` book with a
    /// stale entry gets flipped to `.downloadFailed`.
    ///
    /// Defensive fix: the handler must consult the registry's current state
    /// for each book and skip those not in {.downloading, .SAMLStarted}.
    func testReachabilityDrop_WithStaleTaskEntryForDownloadedBook_DoesNotFlipToFailed() async {
        let book = makeBook(id: "previously-downloaded")
        mockRegistry.addBook(book, state: .downloadSuccessful)

        // Stage the leak: a stale taskId entry for a book that has already
        // finished downloading. `bookIdentifierToDownloadInfo` is correctly
        // empty (post-success cleanup), but `taskIdentifierToBook` retains
        // the entry — exactly what production looks like today after any
        // successful download.
        await stateManager.taskIdentifierToBook.set(7, value: book)

        let center = MyBooksDownloadCenter(
            bookRegistry: mockRegistry,
            stateManager: stateManager,
            reachability: mockReachability
        )
        await drainMainQueueAsync()
        XCTAssertEqual(mockRegistry.state(for: book.identifier), .downloadSuccessful,
                       "precondition: book is downloaded and readable offline")

        mockReachability.simulate(connected: false)
        // Join the failure handler to completion (rather than sleeping and
        // hoping it ran): the handler must consult the registry state and skip
        // the .downloadSuccessful book. If the defensive filter regressed, the
        // joined Task would flip the state and the assertion below would catch
        // it — deterministically, not on a timing guess.
        await awaitNetworkLossHandling(on: center)

        XCTAssertEqual(mockRegistry.state(for: book.identifier), .downloadSuccessful,
                       "Airplane mode must NOT flip a previously-downloaded book to .downloadFailed just because a stale taskIdentifierToBook entry exists")
        _ = center
    }

    /// Coexistence: a stale-entry book AND a genuinely-downloading book.
    /// The handler must fail the latter (PP-4114's intent) but leave the
    /// former alone (this hotfix's intent).
    func testReachabilityDrop_StaleAndActive_FailsOnlyTheActiveDownload() async {
        let downloadedBook = makeBook(id: "previously-downloaded-mix")
        let activeBook = makeBook(id: "actively-downloading-mix")
        mockRegistry.addBook(downloadedBook, state: .downloadSuccessful)
        mockRegistry.addBook(activeBook, state: .downloading)

        // Stale entry for the completed book.
        await stateManager.taskIdentifierToBook.set(11, value: downloadedBook)
        // Genuine in-flight download for the active one.
        _ = await registerActiveDownload(book: activeBook, taskIdentifier: 12)

        let center = MyBooksDownloadCenter(
            bookRegistry: mockRegistry,
            stateManager: stateManager,
            reachability: mockReachability
        )
        await drainMainQueueAsync()

        mockReachability.simulate(connected: false)
        await awaitNetworkLossHandling(on: center)

        XCTAssertEqual(mockRegistry.state(for: activeBook.identifier), .downloadFailed,
                       "PP-4114 intent preserved: genuinely in-flight downloads still fail on network loss")
        XCTAssertEqual(mockRegistry.state(for: downloadedBook.identifier), .downloadSuccessful,
                       "Hotfix: previously-downloaded books with stale taskId entries are NOT touched by the airplane-mode handler")
        _ = center
    }

    /// Cleanup-on-success contract: once we wire up `cleanupDownload`, a book
    /// that transitions through the success path must not leave a stale
    /// `taskIdentifierToBook` entry. This is the root-cause fix; even
    /// without the defensive filter above, this prevents the bug from
    /// occurring in the first place because there are no stale entries
    /// for the airplane-mode handler to misinterpret.
    ///
    /// We exercise it via `DownloadStateManager.cleanupDownload` directly
    /// (which is the seam production code uses for terminal-state cleanup).
    func testCleanupDownload_RemovesTaskIdentifierToBookEntry() async {
        let book = makeBook(id: "cleanup-contract")
        await stateManager.taskIdentifierToBook.set(99, value: book)
        await stateManager.bookIdentifierToDownloadInfo.set(book.identifier, value: MyBooksDownloadInfo(
            downloadProgress: 1.0,
            downloadTask: MockURLSessionDownloadTask(taskIdentifier: 99),
            rightsManagement: .none
        ))

        await stateManager.cleanupDownload(for: book.identifier, taskIdentifier: 99)

        let taskEntry = await stateManager.taskIdentifierToBook.get(99)
        let infoEntry = await stateManager.bookIdentifierToDownloadInfo.get(book.identifier)
        XCTAssertNil(taskEntry,
                     "cleanupDownload(for:taskIdentifier:) must remove the taskIdentifierToBook entry — root-cause fix for the airplane-mode regression")
        XCTAssertNil(infoEntry,
                     "cleanupDownload must also remove the bookIdentifierToDownloadInfo entry")
    }
}
