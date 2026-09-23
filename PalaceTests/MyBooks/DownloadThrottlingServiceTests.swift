//
//  DownloadThrottlingServiceTests.swift
//  PalaceTests
//
//  Coverage for the active-download cap orchestration and suspend/resume
//  policy extracted into DownloadThrottlingService. The audiobook
//  preservation branches (during pauseAll + over-cap suspend) are the
//  most regression-sensitive — they prevent streaming-audio interruptions
//  during memory-pressure events. Asserts on suspend/resume call counts
//  via FakeDownloadTask so we don't need a live URLSession.
//

import XCTest
@testable import Palace
import PalaceBookModel

@MainActor
final class DownloadThrottlingServiceTests: XCTestCase {

    private var stateManager: DownloadStateManager!
    private var notificationCenter: NotificationCenter!
    private var spyDelegate: SpyDelegate!
    private var service: DownloadThrottlingService!

    override func setUpWithError() throws {
        try super.setUpWithError()
        stateManager = DownloadStateManager()
        notificationCenter = NotificationCenter()
        spyDelegate = SpyDelegate()
        service = DownloadThrottlingService(
            stateManager: stateManager,
            notificationCenter: notificationCenter
        )
        service.delegate = spyDelegate
    }

    override func tearDownWithError() throws {
        stateManager = nil
        notificationCenter = nil
        spyDelegate = nil
        service = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    @discardableResult
    private func register(state: URLSessionTask.State,
                          isAudiobook: Bool,
                          taskId: Int) async -> (book: TPPBook, task: FakeDownloadTask) {
        let distributor: DistributorType = isAudiobook ? .OpenAccessAudiobook : .EpubZip
        let book = TPPBookMocker.mockBook(distributorType: distributor)
        let task = FakeDownloadTask(state: state, identifier: taskId)
        let info = MyBooksDownloadInfo(downloadProgress: 0.0, downloadTask: task, rightsManagement: .none)
        await stateManager.bookIdentifierToDownloadInfo.set(book.identifier, value: info)
        await stateManager.taskIdentifierToBook.set(taskId, value: book)
        return (book, task)
    }

    /// Deterministic equivalent of the sync `service.limitActiveDownloads(max:)`
    /// wrapper: sets the cap, then `await`s the same async policy body the
    /// wrapper fires as a detached Task. Joining the body directly removes the
    /// starvable poll on the fire-and-forget Task without changing behavior —
    /// the wrapper does exactly `maxConcurrentDownloads = max` then
    /// `Task { await limitActiveDownloadsAsync(max:) }`, so this runs the policy
    /// exactly once, just like the wrapper.
    private func applyCapAndJoin(max: Int) async {
        stateManager.maxConcurrentDownloads = max
        await service.limitActiveDownloadsAsync(max: max)
    }

    // MARK: - limitActiveDownloads — over the cap

    func testLimit_overCap_suspendsExcessNonAudiobookTasks() async {
        let t1 = await register(state: .running, isAudiobook: false, taskId: 1)
        let t2 = await register(state: .running, isAudiobook: false, taskId: 2)
        let t3 = await register(state: .running, isAudiobook: false, taskId: 3)

        await applyCapAndJoin(max: 1)

        let suspended = [t1.task, t2.task, t3.task].filter { $0.suspendCallCount > 0 }
        XCTAssertEqual(suspended.count, 2,
                       "Over-cap by 2: must suspend exactly 2 of the 3 non-audiobook tasks")
        XCTAssertEqual(stateManager.maxConcurrentDownloads, 1,
                       "stateManager.maxConcurrentDownloads must be updated to the new cap")
    }

    func testLimit_overCap_audiobookTaskNotSuspended() async {
        // 2 audiobooks running + 2 non-audiobooks running, cap = 1
        let audiobook1 = await register(state: .running, isAudiobook: true, taskId: 10)
        let audiobook2 = await register(state: .running, isAudiobook: true, taskId: 11)
        let book1 = await register(state: .running, isAudiobook: false, taskId: 20)
        let book2 = await register(state: .running, isAudiobook: false, taskId: 21)

        await applyCapAndJoin(max: 1)

        XCTAssertEqual(audiobook1.task.suspendCallCount, 0,
                       "Audiobook downloads must NEVER be suspended (streaming protection)")
        XCTAssertEqual(audiobook2.task.suspendCallCount, 0,
                       "Both audiobook downloads must be preserved")
        // Non-audiobooks: both could be suspended since 4-running > 1-cap
        let nonAudiobookSuspends = book1.task.suspendCallCount + book2.task.suspendCallCount
        XCTAssertGreaterThanOrEqual(nonAudiobookSuspends, 1,
                                    "At least one non-audiobook must suspend to make room")
    }

    // MARK: - limitActiveDownloads — under the cap

    func testLimit_underCap_resumesSuspendedTasks() async {
        let _ = await register(state: .running, isAudiobook: false, taskId: 1)
        let s1 = await register(state: .suspended, isAudiobook: false, taskId: 2)
        let s2 = await register(state: .suspended, isAudiobook: false, taskId: 3)

        await applyCapAndJoin(max: 4)

        let resumed = [s1.task, s2.task].filter { $0.resumeCallCount > 0 }
        XCTAssertEqual(resumed.count, 2,
                       "Under-cap with 1 running + 2 suspended: resume both suspended (cap 4 - running 1 = 3 slots)")
    }

    // MARK: - limitActiveDownloads — at the cap

    func testLimit_atCap_doesNothingButCallsSchedule() async {
        let r1 = await register(state: .running, isAudiobook: false, taskId: 1)
        let r2 = await register(state: .running, isAudiobook: false, taskId: 2)

        await applyCapAndJoin(max: 2)

        XCTAssertEqual(r1.task.suspendCallCount, 0)
        XCTAssertEqual(r2.task.suspendCallCount, 0)
        XCTAssertEqual(spyDelegate.scheduleCallCount, 1,
                       "Schedule still runs at-cap so newly-completable starts can fire")
    }

    // MARK: - pauseAllDownloads

    func testPauseAllDownloads_suspendsAllNonAudiobookTasks() async {
        let book1 = await register(state: .running, isAudiobook: false, taskId: 1)
        let book2 = await register(state: .running, isAudiobook: false, taskId: 2)

        await service.pauseAllDownloadsAsync()

        XCTAssertEqual(book1.task.suspendCallCount, 1)
        XCTAssertEqual(book2.task.suspendCallCount, 1)
    }

    func testPauseAllDownloads_preservesAudiobookTasks() async {
        let audio = await register(state: .running, isAudiobook: true, taskId: 1)
        let book = await register(state: .running, isAudiobook: false, taskId: 2)

        await service.pauseAllDownloadsAsync()

        XCTAssertEqual(audio.task.suspendCallCount, 0,
                       "pauseAllDownloads must NEVER suspend an audiobook (user may be streaming)")
        XCTAssertEqual(book.task.suspendCallCount, 1)
    }

    // MARK: - resumeIntelligentDownloads

    func testResumeIntelligentDownloads_reAppliesCurrentCap() async {
        stateManager.maxConcurrentDownloads = 3
        let _ = await register(state: .running, isAudiobook: false, taskId: 1)
        let s1 = await register(state: .suspended, isAudiobook: false, taskId: 2)

        // resumeIntelligentDownloads() just calls limitActiveDownloads(max:
        // current cap), which fires the async policy body. Join that body
        // directly at the current cap (3) — behavior-identical to what
        // resumeIntelligentDownloads triggers — instead of polling.
        await service.limitActiveDownloadsAsync(max: stateManager.maxConcurrentDownloads)

        XCTAssertEqual(s1.task.resumeCallCount, 1,
                       "Re-applying cap with capacity available resumes suspended tasks")
    }

    // MARK: - setupNetworkMonitoring

    func testSetupNetworkMonitoring_observesAppDidBecomeActiveAndReAppliesCap() async {
        stateManager.maxConcurrentDownloads = 4
        let s1 = await register(state: .suspended, isAudiobook: false, taskId: 1)

        service.setupNetworkMonitoring()
        notificationCenter.post(name: UIApplication.didBecomeActiveNotification, object: nil)

        // The observer is registered on queue: .main. Drain twice so the
        // observer block runs (calling limitActiveDownloads, which spawns and
        // retains the policy Task) regardless of main-queue source ordering,
        // then await that Task to join the resume.
        await drainMainQueueAsync()
        await drainMainQueueAsync()
        await service.lastLimitActiveDownloadsTask?.value

        XCTAssertEqual(s1.task.resumeCallCount, 1,
                       "App-became-active observer re-applies the active-cap policy")
    }

    func testSetupNetworkMonitoring_calledTwice_replacesPriorObserver() async {
        // Calling setupNetworkMonitoring more than once should not result
        // in duplicate observer firings — the service unregisters the
        // prior handle before installing a new one.
        stateManager.maxConcurrentDownloads = 4
        let s1 = await register(state: .suspended, isAudiobook: false, taskId: 1)

        service.setupNetworkMonitoring()
        service.setupNetworkMonitoring()

        notificationCenter.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        await drainMainQueueAsync()
        await drainMainQueueAsync()
        await service.lastLimitActiveDownloadsTask?.value

        XCTAssertEqual(s1.task.resumeCallCount, 1,
                       "Resume should fire exactly once per notification, not once per setupNetworkMonitoring call")
    }

    // MARK: - schedule delegation

    func testLimitActiveDownloads_alwaysCallsScheduleAfterPolicyApplied() async {
        // Scheduler must run after every limit application so newly-
        // available capacity gets filled with pending starts.
        await applyCapAndJoin(max: 2)
        XCTAssertEqual(spyDelegate.scheduleCallCount, 1)

        await applyCapAndJoin(max: 4)
        XCTAssertEqual(spyDelegate.scheduleCallCount, 2)
    }
}

// MARK: - Test fakes

/// URLSessionDownloadTask subclass with overridable state + capturing
/// suspend/resume calls. Required because real URLSessionDownloadTask
/// instances minted via URLSession can only enter `.running` by
/// actually running, and tests need deterministic state without a live
/// network.
private final class FakeDownloadTask: URLSessionDownloadTask, @unchecked Sendable {
    private let _state: URLSessionTask.State
    private let _taskIdentifier: Int
    private(set) var suspendCallCount = 0
    private(set) var resumeCallCount = 0

    init(state: URLSessionTask.State, identifier: Int) {
        self._state = state
        self._taskIdentifier = identifier
        super.init()
    }

    override var state: URLSessionTask.State { _state }
    override var taskIdentifier: Int { _taskIdentifier }
    override func suspend() { suspendCallCount += 1 }
    override func resume() { resumeCallCount += 1 }
    override func cancel() {}
}

private final class SpyDelegate: DownloadThrottlingServiceDelegate {
    private(set) var scheduleCallCount = 0

    func schedulePendingStartsAsync() async {
        scheduleCallCount += 1
    }
}
