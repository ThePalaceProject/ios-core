//
//  DownloadCancellationHandlerTests.swift
//  PalaceTests
//
//  Coverage for DownloadCancellationHandler — the state machine that
//  handles both the no-task cancellation path (state-based, e.g.
//  cancelling during a borrow request before the URL session task
//  exists) and the with-task path (real URLSessionDownloadTask.cancel
//  + dictionary cleanup). Critical-path per CLAUDE.md (cancel/borrow
//  flows touch user money/access).
//

import XCTest
@testable import Palace
import PalaceBookModel

@MainActor
final class DownloadCancellationHandlerTests: XCTestCase {

    private var stateManager: DownloadStateManager!
    private var bookRegistry: TPPBookRegistryMock!
    private var spyDelegate: SpyDelegate!
    private var handler: DownloadCancellationHandler!
    private var book: TPPBook!
    private var reporter: DownloadProgressReporter!

    override func setUpWithError() throws {
        try super.setUpWithError()
        stateManager = DownloadStateManager()
        bookRegistry = TPPBookRegistryMock()
        spyDelegate = SpyDelegate()
        book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        bookRegistry.addBook(book, state: .downloadNeeded)

        // Palace target compiles with FEATURE_DRM_CONNECTOR; the DRM-on
        // init is what's exported to tests via @testable import Palace.
        handler = DownloadCancellationHandler(
            stateManager: stateManager,
            bookRegistry: bookRegistry,
            adobeDRMService: AdobeDRMService.shared
        )
        handler.delegate = spyDelegate
        reporter = DownloadProgressReporter()
        handler.progressReporter = reporter
    }

    override func tearDownWithError() throws {
        stateManager = nil
        bookRegistry = nil
        spyDelegate = nil
        handler = nil
        book = nil
        reporter = nil
        try super.tearDownWithError()
    }

    // MARK: - LCP content-transfer release on cancel
    //
    // Readium never reports a cancelled fulfillment: LicensesService swallows
    // NSURLErrorCancelled WITHOUT calling the completion handler, so the
    // registration is released here or not at all. Left behind it pins the book at
    // `.downloading` and, because the half-sheet reads that flag ahead of book
    // state, leaves a determinate progress bar frozen on screen forever.

    func testCancel_releasesTheLCPContentTransferRegistration() {
        bookRegistry.setState(.downloading, for: book.identifier)
        reporter.sendLCPContentDownloadActive(bookIdentifier: book.identifier, active: true)
        XCTAssertTrue(reporter.isLCPContentTransferActive(for: book.identifier), "precondition")

        handler.cancelDownload(for: book.identifier)

        XCTAssertFalse(
            reporter.isLCPContentTransferActive(for: book.identifier),
            "cancel must release the registration — Readium never reports the cancelled transfer, so nothing else will"
        )
    }

    /// A cancel the handler REJECTS must not mutate transfer state. `.holding` is
    /// not a cancellable no-task state, so this request does nothing at all.
    func testRejectedCancel_leavesTheRegistrationAlone() {
        bookRegistry.setState(.holding, for: book.identifier)
        reporter.sendLCPContentDownloadActive(bookIdentifier: book.identifier, active: true)

        handler.cancelDownload(for: book.identifier)

        XCTAssertTrue(
            reporter.isLCPContentTransferActive(for: book.identifier),
            "a nonsensical cancel is ignored; it must not tear down a live transfer's registration"
        )
    }

    /// Thin wrapper around the shared `awaitConditionAsync` helper.
    /// `file`/`line` forwarded so timeout XCTFail blames the call site.
    private func waitForAsync(
        timeout: TimeInterval = 10.0,
        file: StaticString = #file,
        line: UInt = #line,
        _ predicate: @escaping () -> Bool
    ) async {
        await awaitConditionAsync(timeout: timeout, file: file, line: line, predicate)
    }
    // MARK: - No task: nonsensical state

    func testCancel_unknownIdentifierWithNonCancellableState_isNoOp() async {
        bookRegistry.setState(.downloadSuccessful, for: book.identifier)

        handler.cancelDownload(for: book.identifier)

        // Nonsensical cancel returns BEFORE spawning any teardown Task, so
        // lastCancelTeardownTask stays nil — joining it is a no-op that
        // deterministically confirms no async cleanup was scheduled (rather
        // than sleeping and hoping).
        await handler.lastCancelTeardownTask?.value

        XCTAssertEqual(spyDelegate.broadcastCount, 0,
                       "Nonsensical cancel must NOT broadcast an update")
        XCTAssertEqual(spyDelegate.scheduleCount, 0,
                       "Nonsensical cancel must NOT schedule pending starts")
        XCTAssertEqual(bookRegistry.state(for: book.identifier), .downloadSuccessful,
                       "Nonsensical cancel must NOT change state")
    }

    // MARK: - No task: cancellable state

    func testCancel_noTaskInDownloadingState_setsDownloadNeededAndCleansUp() async {
        bookRegistry.setState(.downloading, for: book.identifier)

        handler.cancelDownload(for: book.identifier)

        // Join the teardown Task (its last step is schedulePendingStartsIfPossible)
        // instead of polling scheduleCount against a deadline.
        await handler.lastCancelTeardownTask?.value

        XCTAssertEqual(bookRegistry.state(for: book.identifier), .downloadNeeded,
                       "No-task cancel from .downloading must drop back to .downloadNeeded")
        XCTAssertEqual(spyDelegate.broadcastCount, 1,
                       "No-task cancel must broadcastUpdate so UI reflects the rollback")
        XCTAssertEqual(spyDelegate.scheduleCount, 1,
                       "No-task cancel must schedulePending so the freed slot is reused")
    }

    func testCancel_noTaskInSAMLStartedState_treatedAsCancellable() async {
        bookRegistry.setState(.SAMLStarted, for: book.identifier)

        handler.cancelDownload(for: book.identifier)

        await handler.lastCancelTeardownTask?.value

        XCTAssertEqual(bookRegistry.state(for: book.identifier), .downloadNeeded,
                       "SAMLStarted is in the cancellable-states list — cancel must drop back to .downloadNeeded")
    }

    // MARK: - With task: real cancellation

    func testCancel_withTask_setsDownloadNeededAndCancelsTask() async throws {
        let task = StubDownloadTask(taskIdentifier: 5)
        let info = MyBooksDownloadInfo(
            downloadProgress: 0.4,
            downloadTask: task,
            rightsManagement: .none
        )
        await stateManager.bookIdentifierToDownloadInfo.set(book.identifier, value: info)
        await stateManager.taskIdentifierToBook.set(5, value: book)
        bookRegistry.setState(.downloading, for: book.identifier)

        handler.cancelDownload(for: book.identifier)

        // The StubDownloadTask fires its cancel completion synchronously, which
        // spawns the teardown Task; join it via the retained handle instead of
        // polling. The teardown clears both maps and fires schedulePending as
        // its final step.
        await handler.lastCancelTeardownTask?.value

        XCTAssertEqual(bookRegistry.state(for: book.identifier), .downloadNeeded,
                       "With-task cancel must set state to .downloadNeeded BEFORE cancelling the task so UI updates immediately")
        XCTAssertEqual(task.cancelByProducingResumeDataCount, 1,
                       "With-task cancel must call URLSessionDownloadTask.cancel(byProducingResumeData:)")

        // Cleanup ran — both maps cleared.
        let cachedInfo = await stateManager.bookIdentifierToDownloadInfo.get(book.identifier)
        XCTAssertNil(cachedInfo, "bookIdentifierToDownloadInfo must be cleared after cancel completion")
        let mappedBook = await stateManager.taskIdentifierToBook.get(5)
        XCTAssertNil(mappedBook, "taskIdentifierToBook must be cleared after cancel completion")
    }

    // MARK: - Adobe DRM short-circuit (#if FEATURE_DRM_CONNECTOR)

    func testCancel_adobeDRMRights_shortCircuitsToAdobeCancel() async throws {
        let task = StubDownloadTask(taskIdentifier: 6)
        let info = MyBooksDownloadInfo(
            downloadProgress: 0.0,
            downloadTask: task,
            rightsManagement: .adobe
        )
        await stateManager.bookIdentifierToDownloadInfo.set(book.identifier, value: info)
        await stateManager.taskIdentifierToBook.set(6, value: book)
        bookRegistry.setState(.downloading, for: book.identifier)

        handler.cancelDownload(for: book.identifier)

        // Adobe path returns early (before the URLSession cancel + teardown),
        // so no teardown Task is spawned — lastCancelTeardownTask stays nil and
        // joining it is a no-op that deterministically confirms nothing async
        // was scheduled.
        await handler.lastCancelTeardownTask?.value

        // Adobe path returns early — does NOT cancel the URLSessionDownloadTask
        // and does NOT clear the dictionaries (Adobe handles its own lifecycle).
        XCTAssertEqual(task.cancelByProducingResumeDataCount, 0,
                       "Adobe-DRM short-circuit must NOT cancel the URL session task — adobeDRMService.cancelFulfillment owns it")
        XCTAssertEqual(spyDelegate.broadcastCount, 0,
                       "Adobe-DRM short-circuit must NOT broadcastUpdate from this path")
        XCTAssertEqual(bookRegistry.state(for: book.identifier), .downloading,
                       "Adobe-DRM short-circuit must NOT touch registry state — Adobe's own callbacks drive transitions")
    }
}

// MARK: - Stubs

private final class SpyDelegate: DownloadCancellationHandlerDelegate {
    private(set) var broadcastCount = 0
    private(set) var scheduleCount = 0

    func broadcastUpdate() { broadcastCount += 1 }
    func schedulePendingStartsIfPossible() { scheduleCount += 1 }
}

private final class StubDownloadTask: URLSessionDownloadTask, @unchecked Sendable {
    private let _taskIdentifier: Int
    private(set) var cancelByProducingResumeDataCount = 0

    init(taskIdentifier: Int) {
        self._taskIdentifier = taskIdentifier
        super.init()
    }

    override var taskIdentifier: Int { _taskIdentifier }
    override func cancel() {}
    override func cancel(byProducingResumeData completionHandler: @escaping (Data?) -> Void) {
        cancelByProducingResumeDataCount += 1
        // Call the completion synchronously with nil resume data so the
        // dictionary cleanup runs deterministically.
        completionHandler(nil)
    }
    override func resume() {}
    override func suspend() {}
}
