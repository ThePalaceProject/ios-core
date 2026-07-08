//
//  DownloadTransferRetryTests.swift
//  PalaceTests
//
//  Reliability WS-A #4 — transient content-transfer retry decision logic, plus
//  the launch-reconciliation registry-loaded gate (INV-4 ordering). Drives the
//  MyBooksDownloadCenter decision seams directly with an injected hermetic
//  session (NoNetworkURLProtocol) so no real network is touched. INV-6: these
//  exercise the plain content-transfer path only — no DRM fulfillment.
//

import XCTest
@testable import Palace

final class DownloadTransferRetryTests: XCTestCase {

    private var mockRegistry: TPPBookRegistryMock!
    private var stateManager: DownloadStateManager!
    private var center: MyBooksDownloadCenter!
    private var tempURL: URL!

    override func setUp() {
        super.setUp()
        tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("TransferRetry-\(UUID().uuidString).json")
        mockRegistry = TPPBookRegistryMock()
        stateManager = DownloadStateManager(taskPersistence: DownloadTaskPersistence(fileURL: tempURL))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [NoNetworkURLProtocol.self]
        let session = URLSession(configuration: config)
        center = MyBooksDownloadCenter(
            bookRegistry: mockRegistry,
            stateManager: stateManager,
            reachability: MockReachability(initiallyConnected: true),
            urlSession: session
        )
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempURL)
        center = nil
        stateManager = nil
        mockRegistry = nil
        tempURL = nil
        super.tearDown()
    }

    private func urlError(_ code: Int) -> NSError {
        NSError(domain: NSURLErrorDomain, code: code)
    }

    private func task(_ id: Int) -> MockURLSessionDownloadTask {
        MockURLSessionDownloadTask(
            taskIdentifier: id,
            request: URLRequest(url: URL(string: "https://palace-test.invalid/retry")!))
    }

    // MARK: - maybeRetryTransientTransfer (INV-6: content transfer only)

    func testTransientError_underCap_retriesAndIncrementsCounter() async {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        await stateManager.taskIdentifierToBook.set(42, value: book)

        let retried = await center.maybeRetryTransientTransfer(task: task(42), error: urlError(NSURLErrorTimedOut))

        XCTAssertTrue(retried, "a transient transfer error under the cap must schedule a retry")
        let count = await stateManager.transferRetryAttempts(for: book.identifier)
        XCTAssertEqual(count, 1, "retry must bump the per-book attempt counter")
    }

    func testNonTransientError_isNotRetried() async {
        // Auth-required is in the classifier's never-retry set — must fail fast
        // into the existing alert path, not loop.
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        await stateManager.taskIdentifierToBook.set(7, value: book)

        let retried = await center.maybeRetryTransientTransfer(
            task: task(7), error: urlError(NSURLErrorUserAuthenticationRequired))

        XCTAssertFalse(retried)
        let count = await stateManager.transferRetryAttempts(for: book.identifier)
        XCTAssertEqual(count, 0, "a non-retryable error must not touch the retry counter")
    }

    func testCancelledError_isNotRetried() async {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        await stateManager.taskIdentifierToBook.set(8, value: book)

        let retried = await center.maybeRetryTransientTransfer(task: task(8), error: urlError(NSURLErrorCancelled))

        XCTAssertFalse(retried, "user/navigation cancellation must never be retried")
    }

    func testNoMappedBook_isNotRetried() async {
        // No taskIdentifierToBook entry for this id -> nothing to retry.
        let retried = await center.maybeRetryTransientTransfer(task: task(999), error: urlError(NSURLErrorTimedOut))
        XCTAssertFalse(retried)
    }

    func testTransientError_atCap_stopsRetryingAndResetsCounter() async {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        await stateManager.taskIdentifierToBook.set(9, value: book)
        // Exhaust the cap (maxTransferRetries == 3).
        for _ in 0..<3 { await stateManager.incrementTransferRetryAttempts(for: book.identifier) }

        let retried = await center.maybeRetryTransientTransfer(task: task(9), error: urlError(NSURLErrorTimedOut))

        XCTAssertFalse(retried, "at the attempt cap the retry stops and the normal failure path runs")
        let count = await stateManager.transferRetryAttempts(for: book.identifier)
        XCTAssertEqual(count, 0, "exhausting the cap resets the counter for future independent failures")
    }

    // MARK: - Launch reconciliation gate (INV-4 ordering)

    func testIsRegistryLoadedForReconcile_trueOnlyAfterLoad() {
        mockRegistry.state = .unloaded
        XCTAssertFalse(center.isRegistryLoadedForReconcile, "must not reconcile before the registry loads")
        mockRegistry.state = .loading
        XCTAssertFalse(center.isRegistryLoadedForReconcile)
        mockRegistry.state = .loaded
        XCTAssertTrue(center.isRegistryLoadedForReconcile)
        mockRegistry.state = .syncing
        XCTAssertTrue(center.isRegistryLoadedForReconcile)
        mockRegistry.state = .synced
        XCTAssertTrue(center.isRegistryLoadedForReconcile)
    }
}
