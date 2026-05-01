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

    /// Async-safe main-queue drain. The shared `drainMainQueue()` extension
    /// calls synchronous `wait(for:)`, which deadlocks inside an
    /// `@MainActor async` test (the main thread is already running the test;
    /// blocking it via synchronous wait stalls the dispatch the test is
    /// waiting on). Use `await fulfillment(of:)` instead — the async runtime
    /// suspends correctly while the main queue drains.
    private func drainMainQueueAsync(timeout: TimeInterval = 2.0) async {
        let drained = expectation(description: "main queue drained (async)")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: timeout)
    }

    /// Spin until the registry reflects the expected state, or timeout.
    /// Production transition is async (Task in DownloadAlertPresenter).
    private func waitForState(
        _ expected: TPPBookState,
        on identifier: String,
        timeout: TimeInterval = 2.0
    ) async {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while mockRegistry.state(for: identifier) != expected, Date() < deadline {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 20_000_000)  // 20ms
        }
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
        await waitForState(.downloadFailed, on: book.identifier)

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
        await waitForState(.downloadFailed, on: bookA.identifier)
        await waitForState(.downloadFailed, on: bookB.identifier)

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
        await drainMainQueueAsync()
        try? await Task.sleep(nanoseconds: 100_000_000)
        await drainMainQueueAsync()

        XCTAssertEqual(mockRegistry.state(for: book.identifier), .downloading,
                       "Initial replay of connectivityPublisher's true value must NOT trip the failure path")
        _ = center
    }

    /// A reachability transition with no active downloads is a harmless
    /// no-op. Catches a fix that crashes or asserts when the active-set
    /// is empty.
    func testReachabilityDrop_WithNoActiveDownloads_IsNoOp() async {
        let center = MyBooksDownloadCenter(
            bookRegistry: mockRegistry,
            stateManager: stateManager,
            reachability: mockReachability
        )
        await drainMainQueueAsync()

        mockReachability.simulate(connected: false)
        try? await Task.sleep(nanoseconds: 50_000_000)
        await drainMainQueueAsync()
        // No expectations — this test passes if nothing crashes or asserts.
        _ = center
    }
}
