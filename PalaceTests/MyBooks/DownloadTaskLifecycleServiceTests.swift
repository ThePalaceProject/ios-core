//
//  DownloadTaskLifecycleServiceTests.swift
//  PalaceTests
//
//  Coverage for DownloadTaskLifecycleService: registerStartedTask
//  must seed both SafeDictionaries, mark the book as .downloading
//  in the registry, announce the start, and notify-center-changed.
//  handleTaskCompletionError must clear redirect attempts, register
//  completion, and route real errors (not NSURLErrorCancelled) to
//  log+alert; cancellations are silent.
//

import XCTest
@testable import Palace

// Deliberately NOT @MainActor: the object under test is nonisolated and
// non-Sendable — awaiting its async APIs on a @MainActor-held reference is a
// Swift 6 sending error, while from a nonisolated test everything stays in
// one isolation domain. Nothing here touches UI or main-actor state.
final class DownloadTaskLifecycleServiceTests: XCTestCase {

    private var stateManager: DownloadStateManager!
    private var bookRegistry: TPPBookRegistryMock!
    private var spyAnnouncer: SpyAnnouncer!
    private var spyDelegate: SpyDelegate!
    private var service: DownloadTaskLifecycleService!
    private var book: TPPBook!

    override func setUpWithError() throws {
        try super.setUpWithError()
        stateManager = DownloadStateManager()
        bookRegistry = TPPBookRegistryMock()
        spyAnnouncer = SpyAnnouncer()
        spyDelegate = SpyDelegate()

        let announcementService = DownloadAnnouncementService(announcer: spyAnnouncer)
        service = DownloadTaskLifecycleService(
            stateManager: stateManager,
            bookRegistry: bookRegistry,
            downloadAnnouncementService: announcementService
        )
        service.delegate = spyDelegate

        book = TPPBookMocker.mockBook(distributorType: .EpubZip)
    }

    override func tearDownWithError() throws {
        stateManager = nil
        bookRegistry = nil
        spyAnnouncer = nil
        spyDelegate = nil
        service = nil
        book = nil
        try super.tearDownWithError()
    }

    // MARK: - registerStartedTask

    func testRegisterStartedTask_storesDownloadInfoKeyedByBookIdentifier() async {
        let task = StubDownloadTask(taskIdentifier: 7)

        await service.registerStartedTask(task, book: book, maxConcurrentDownloads: 4)

        let info = await stateManager.bookIdentifierToDownloadInfo.get(book.identifier)
        XCTAssertNotNil(info, "registerStartedTask must seed bookIdentifierToDownloadInfo")
        XCTAssertEqual(info?.rightsManagement,
                       MyBooksDownloadInfo.MyBooksDownloadRightsManagement.unknown,
                       "Initial download info has .unknown rights until completion-time MIME detection")
    }

    func testRegisterStartedTask_storesTaskIdentifierToBookMapping() async {
        let task = StubDownloadTask(taskIdentifier: 99)

        await service.registerStartedTask(task, book: book, maxConcurrentDownloads: 4)

        let mapped = await stateManager.taskIdentifierToBook.get(99)
        XCTAssertEqual(mapped?.identifier, book.identifier,
                       "registerStartedTask must seed taskIdentifierToBook for the URL session callback path")
    }

    func testRegisterStartedTask_marksBookAsDownloadingInRegistry() async {
        let task = StubDownloadTask(taskIdentifier: 1)

        await service.registerStartedTask(task, book: book, maxConcurrentDownloads: 4)

        XCTAssertEqual(bookRegistry.state(for: book.identifier), .downloading,
                       "registerStartedTask must mark the book as .downloading")
    }

    func testRegisterStartedTask_announcesDownloadStartedAndNotifiesCenter() async {
        let task = StubDownloadTask(taskIdentifier: 1)

        await service.registerStartedTask(task, book: book, maxConcurrentDownloads: 4)

        XCTAssertEqual(spyAnnouncer.startedAnnouncements.map { $0.title }, [book.title])
        XCTAssertEqual(spyDelegate.notifyCenterChangedCount, 1,
                       "registerStartedTask must broadcast .TPPMyBooksDownloadCenterDidChange via the delegate")
        XCTAssertEqual(spyDelegate.scheduleStartsCount, 1,
                       "registerStartedTask must invoke schedulePendingStartsIfPossible to fill any free slots")
    }

    func testRegisterStartedTask_resumesTheTask() async {
        let task = StubDownloadTask(taskIdentifier: 1)

        await service.registerStartedTask(task, book: book, maxConcurrentDownloads: 4)

        XCTAssertEqual(task.resumeCount, 1,
                       "registerStartedTask must resume() the task AFTER state seeding so URLSession callbacks find it")
    }

    // MARK: - handleTaskCompletionError

    func testHandleTaskCompletionError_unknownTask_isNoOp() async {
        let task = StubDownloadTask(taskIdentifier: 999)

        await service.handleTaskCompletionError(task: task, error: nil)

        XCTAssertEqual(spyDelegate.logCalls.count, 0)
        XCTAssertEqual(spyDelegate.failDownloadCalls.count, 0)
        XCTAssertEqual(spyDelegate.scheduleStartsCount, 0,
                       "Unknown task must NOT trigger schedulePending — there's nothing to schedule against")
    }

    func testHandleTaskCompletionError_successPath_registersCompletionAndSchedules() async {
        let task = StubDownloadTask(taskIdentifier: 42)
        await stateManager.taskIdentifierToBook.set(42, value: book)

        await service.handleTaskCompletionError(task: task, error: nil)

        XCTAssertEqual(spyDelegate.logCalls.count, 0,
                       "Success path must NOT log a download failure")
        XCTAssertEqual(spyDelegate.failDownloadCalls.count, 0,
                       "Success path must NOT trigger failDownloadWithAlert")
        XCTAssertEqual(spyDelegate.scheduleStartsCount, 1,
                       "Success path must schedule pending starts to fill the now-free slot")
    }

    func testHandleTaskCompletionError_realError_logsFailureAndAlerts() async {
        let task = StubDownloadTask(taskIdentifier: 42)
        await stateManager.taskIdentifierToBook.set(42, value: book)
        let netError = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)

        await service.handleTaskCompletionError(task: task, error: netError)

        XCTAssertEqual(spyDelegate.logCalls.map { $0.reason }, ["networking error"])
        XCTAssertEqual(spyDelegate.failDownloadCalls.map { $0.identifier }, [book.identifier])
        XCTAssertEqual(spyDelegate.scheduleStartsCount, 0,
                       "Real-error path returns BEFORE schedulePending — letting the alert tail run first")
    }

    func testHandleTaskCompletionError_cancelledError_doesNotAlert() async {
        let task = StubDownloadTask(taskIdentifier: 42)
        await stateManager.taskIdentifierToBook.set(42, value: book)
        let cancelled = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)

        await service.handleTaskCompletionError(task: task, error: cancelled)

        XCTAssertEqual(spyDelegate.logCalls.count, 0,
                       "User-initiated cancellation must NOT log a failure")
        XCTAssertEqual(spyDelegate.failDownloadCalls.count, 0,
                       "User-initiated cancellation must NOT trigger an alert")
        XCTAssertEqual(spyDelegate.scheduleStartsCount, 1,
                       "Cancellation falls through to schedulePending — the slot is free for next start")
    }
}

// MARK: - Stubs

private final class SpyDelegate: DownloadTaskLifecycleServiceDelegate {
    private(set) var logCalls: [(book: TPPBook, reason: String)] = []
    private(set) var failDownloadCalls: [TPPBook] = []
    private(set) var notifyCenterChangedCount = 0
    private(set) var scheduleStartsCount = 0

    func logBookDownloadFailure(_ book: TPPBook, reason: String, downloadTask: URLSessionTask, metadata: [String: Any]?) {
        logCalls.append((book, reason))
    }

    func failDownloadWithAlert(for book: TPPBook, withMessage message: String?) {
        failDownloadCalls.append(book)
    }

    func notifyDownloadCenterDidChange() {
        notifyCenterChangedCount += 1
    }

    func schedulePendingStartsIfPossible() {
        scheduleStartsCount += 1
    }
}

private final class SpyAnnouncer: DownloadLifecycleAnnouncing {
    private(set) var startedAnnouncements: [(title: String, identifier: String?)] = []

    func announceDownloadStarted(title: String, identifier: String?) {
        startedAnnouncements.append((title, identifier))
    }

    func announceDownloadProgress(title: String, identifier: String, progress: Double) {}
    func announceDownloadCompleted(title: String) {}
    func announceDownloadFailed(title: String) {}
    func announceBorrowStarted(title: String) {}
    func announceBorrowSucceeded(title: String) {}
    func announceBorrowFailed(title: String) {}
    func announceReturnStarted(title: String) {}
    func announceReturnSucceeded(title: String) {}
    func announceReturnFailed(title: String) {}
    func resetProgress(identifier: String) {}
}

private final class StubDownloadTask: URLSessionDownloadTask, @unchecked Sendable {
    private let _taskIdentifier: Int
    private(set) var resumeCount = 0

    init(taskIdentifier: Int) {
        self._taskIdentifier = taskIdentifier
        super.init()
    }

    override var taskIdentifier: Int { _taskIdentifier }
    override func cancel() {}
    override func resume() { resumeCount += 1 }
    override func suspend() {}
}
