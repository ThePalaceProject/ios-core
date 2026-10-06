//
//  DownloadNetworkLossContractTests.swift
//  PalaceTests
//
//  Call order of the mid-download network-loss handler (PP-4114): on an
//  offline transition it reads registry state for every mapped task, cancels
//  every active task, then fails only the books still downloading.
//

import Combine
import XCTest
@testable import Palace
import PalaceBookModel

@MainActor
final class DownloadNetworkLossContractTests: XCTestCase {

    // XCTest builds one instance per test method, so these are fresh per test.
    private let log = CallLog()
    private lazy var registry = SpyNetworkLossRegistry(log: log)
    private let stateManager = DownloadStateManager(
        taskPersistence: DownloadTaskPersistence(fileURL: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("NetworkLossContract-\(UUID().uuidString).json")))
    private let tracker = ErrorActivityTracker()

    // MARK: - Subject

    /// Builds the production network-loss wiring around a download center that
    /// shares this test's registry and state manager.
    private func makeSubject(reachability: MockReachability) -> NetworkLossSubject {
        let center = MyBooksDownloadCenter(
            bookRegistry: registry,
            stateManager: stateManager,
            errorActivityTracker: tracker,
            reachability: reachability
        )
        let monitor = AppContainer.makeDownloadNetworkLossMonitor(
            for: center,
            connectivity: reachability.connectivityPublisher
        )
        return NetworkLossSubject(center: center, monitor: monitor, join: { await monitor.lastFailureTask?.value })
    }

    /// The sink is delivered via `RunLoop.main`; two drains let it run and
    /// spawn its Task, then the join awaits that Task to completion.
    private func awaitHandling(_ subject: NetworkLossSubject) async {
        await drainMainQueueAsync()
        await drainMainQueueAsync()
        await subject.join()
    }

    private func makeBook(_ id: String) -> TPPBook {
        TPPBook(dictionary: [
            "acquisitions": [TPPFake.genericAcquisition.dictionaryRepresentation()],
            "title": "Network Loss \(id)",
            "categories": ["Fiction"],
            "id": id,
            "updated": "2024-01-01T00:00:00Z"
        ])!
    }

    @discardableResult
    private func mapTask(_ taskID: Int, to book: TPPBook) async -> Int {
        await stateManager.taskIdentifierToBook.set(taskID, value: book)
        return taskID
    }

    @discardableResult
    private func addActiveInfo(taskID: Int, for book: TPPBook) async -> SpyCancelTask {
        let task = SpyCancelTask(taskIdentifier: taskID, log: log)
        await stateManager.bookIdentifierToDownloadInfo.set(
            book.identifier,
            value: MyBooksDownloadInfo(downloadProgress: 0.4, downloadTask: task, rightsManagement: .none))
        return task
    }

    // MARK: - Contracts

    /// Downloading and SAML-started books fail; a stale mapping for a finished
    /// book is read but left alone; an info with no task mapping is still
    /// cancelled. Every cancel precedes every failure.
    func testOfflineTransition_readsStateCancelsEveryTaskThenFailsOnlyInFlightBooks() async {
        let downloading = makeBook("a-downloading")
        let saml = makeBook("b-saml")
        let finished = makeBook("c-finished")
        let unmapped = makeBook("d-unmapped")
        registry.addBook(downloading, state: .downloading)
        registry.addBook(saml, state: .SAMLStarted)
        registry.addBook(finished, state: .downloadSuccessful)
        registry.addBook(unmapped, state: .downloading)
        await mapTask(1, to: downloading)
        await addActiveInfo(taskID: 1, for: downloading)
        await mapTask(2, to: saml)
        await addActiveInfo(taskID: 2, for: saml)
        await mapTask(3, to: finished)
        let unmappedTask = await addActiveInfo(taskID: 4, for: unmapped)

        let reachability = MockReachability(initiallyConnected: true)
        let subject = makeSubject(reachability: reachability)
        await drainMainQueueAsync()
        registry.isRecording = true

        reachability.simulate(connected: false)
        await awaitHandling(subject)

        ContractSnapshot.assert(canonical(log), named: "offlineTransition_mixedActiveSet")
        XCTAssertEqual(registry.state(for: downloading.identifier), .downloadFailed)
        XCTAssertEqual(registry.state(for: saml.identifier), .downloadFailed)
        XCTAssertEqual(registry.state(for: finished.identifier), .downloadSuccessful)
        XCTAssertEqual(registry.state(for: unmapped.identifier), .downloading,
                       "a book with no task mapping is cancelled but not failed")
        XCTAssertEqual(unmappedTask.state, .canceling)
        _ = subject
    }

    /// With no task mappings at all the handler returns before cancelling,
    /// even when download infos exist.
    func testOfflineTransition_withNoTaskMappings_cancelsAndFailsNothing() async {
        let book = makeBook("info-only")
        registry.addBook(book, state: .downloading)
        let task = await addActiveInfo(taskID: 9, for: book)

        let reachability = MockReachability(initiallyConnected: true)
        let subject = makeSubject(reachability: reachability)
        await drainMainQueueAsync()
        registry.isRecording = true

        reachability.simulate(connected: false)
        await awaitHandling(subject)

        XCTAssertEqual(log.snapshot(), [], "no registry read, cancel or failure without a task mapping")
        XCTAssertEqual(task.state, .suspended)
        XCTAssertEqual(registry.state(for: book.identifier), .downloading)
        _ = subject
    }

    /// Only stale mappings: tasks are cancelled, no book is failed.
    func testOfflineTransition_withOnlyStaleMappings_cancelsWithoutFailing() async {
        let finished = makeBook("stale-only")
        registry.addBook(finished, state: .downloadSuccessful)
        await mapTask(5, to: finished)
        await addActiveInfo(taskID: 5, for: finished)

        let reachability = MockReachability(initiallyConnected: true)
        let subject = makeSubject(reachability: reachability)
        await drainMainQueueAsync()
        registry.isRecording = true

        reachability.simulate(connected: false)
        await awaitHandling(subject)

        ContractSnapshot.assert(canonical(log), named: "offlineTransition_staleOnly")
        XCTAssertEqual(registry.state(for: finished.identifier), .downloadSuccessful)
        _ = subject
    }

    /// An online transition is not a loss: nothing is read, cancelled or failed.
    func testOnlineTransition_doesNothing() async {
        let book = makeBook("comes-online")
        registry.addBook(book, state: .downloading)
        await mapTask(6, to: book)
        let task = await addActiveInfo(taskID: 6, for: book)

        let reachability = MockReachability(initiallyConnected: false)
        let subject = makeSubject(reachability: reachability)
        await drainMainQueueAsync()
        registry.isRecording = true

        reachability.simulate(connected: true)
        await awaitHandling(subject)

        XCTAssertEqual(log.snapshot(), [])
        XCTAssertEqual(task.state, .suspended)
        XCTAssertEqual(registry.state(for: book.identifier), .downloading)
        _ = subject
    }

    /// Each offline transition is handled: a download restarted after
    /// reconnecting fails again on the next loss.
    func testSecondOfflineTransition_failsTheRestartedDownloadAgain() async {
        let book = makeBook("fails-twice")
        registry.addBook(book, state: .downloading)
        await mapTask(7, to: book)
        await addActiveInfo(taskID: 7, for: book)

        let reachability = MockReachability(initiallyConnected: true)
        let subject = makeSubject(reachability: reachability)
        await drainMainQueueAsync()
        registry.isRecording = true

        reachability.simulate(connected: false)
        await awaitHandling(subject)
        XCTAssertEqual(registry.state(for: book.identifier), .downloadFailed)

        registry.isRecording = false
        // Let the first failure's cleanup drop task 7's mapping, so the
        // second pass sees exactly one mapped task.
        var polls = 0
        while await stateManager.taskIdentifierToBook.get(7) != nil, polls < 100 {
            polls += 1
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let staleMapping = await stateManager.taskIdentifierToBook.get(7)
        XCTAssertNil(staleMapping, "precondition: the first failure's cleanup removed task 7's mapping")
        registry.addBook(book, state: .downloading)
        await mapTask(8, to: book)
        await addActiveInfo(taskID: 8, for: book)
        reachability.simulate(connected: true)
        await awaitHandling(subject)
        registry.isRecording = true

        reachability.simulate(connected: false)
        await awaitHandling(subject)

        ContractSnapshot.assert(canonical(log), named: "offlineTransition_twice")
        XCTAssertEqual(registry.state(for: book.identifier), .downloadFailed)
        _ = subject
    }

    /// The failure carries the network-loss message to the activity log.
    func testOfflineTransition_logsTheConnectionLostMessage() async {
        let book = makeBook("message")
        registry.addBook(book, state: .downloading)
        await mapTask(10, to: book)
        await addActiveInfo(taskID: 10, for: book)

        let reachability = MockReachability(initiallyConnected: true)
        let subject = makeSubject(reachability: reachability)
        await drainMainQueueAsync()

        reachability.simulate(connected: false)
        await awaitHandling(subject)

        let expected = "Download failed for 'Network Loss message': The connection was lost during the download."
        var messages: [String] = []
        for _ in 0..<100 {
            messages = await tracker.recentActivities().map(\.message)
            if messages.contains(expected) { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(messages.contains(expected), "logged: \(messages)")
        _ = subject
    }

    // MARK: - Helpers

    /// Sorts each run of same-method calls: within a phase the order follows
    /// dictionary iteration and is not part of the contract; the phase order is.
    private func canonical(_ log: CallLog) -> CallLog {
        var runs: [[CallRecord]] = []
        for record in log.snapshot() {
            if let last = runs.last?.last, last.method == record.method {
                runs[runs.count - 1].append(record)
            } else {
                runs.append([record])
            }
        }
        let result = CallLog()
        for run in runs {
            for record in run.sorted(by: { sortKey($0) < sortKey($1) }) {
                result.record(record.method, args: record.args)
            }
        }
        return result
    }

    private func sortKey(_ record: CallRecord) -> String {
        record.args.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
    }
}

/// Holds the subject alive and joins its most recent failure handling.
private struct NetworkLossSubject {
    let center: MyBooksDownloadCenter
    let monitor: DownloadNetworkLossMonitor
    let join: @MainActor () async -> Void
}

/// Records registry reads and writes once recording is on. State reads stop
/// being recorded after the first failure write: the failure path starts
/// asynchronous work elsewhere in the app that also reads registry state, and
/// those reads are not part of this contract.
private final class SpyNetworkLossRegistry: TPPBookRegistryMock, @unchecked Sendable {
    private let log: CallLog
    private var recordsStateReads = false
    var isRecording = false {
        didSet { recordsStateReads = isRecording }
    }

    init(log: CallLog) {
        self.log = log
        super.init()
    }

    override func state(for bookIdentifier: String?) -> TPPBookState {
        let state = super.state(for: bookIdentifier)
        if isRecording, recordsStateReads, let bookIdentifier {
            log.record("registry.state", args: ["book": bookIdentifier, "state": state.stringValue()])
        }
        return state
    }

    override func addBook(_ book: TPPBook, location: TPPBookLocation? = nil, state: TPPBookState, fulfillmentId: String? = nil, readiumBookmarks: [TPPReadiumBookmark]? = nil, genericBookmarks: [TPPBookLocation]? = nil) {
        if isRecording {
            recordsStateReads = false
            log.record("registry.addBook", args: ["book": book.identifier, "state": state.stringValue()])
        }
        super.addBook(book, location: location, state: state, fulfillmentId: fulfillmentId, readiumBookmarks: readiumBookmarks, genericBookmarks: genericBookmarks)
    }
}

/// Records `cancel()` so cancellation is ordered against registry calls.
private final class SpyCancelTask: MockURLSessionDownloadTask, @unchecked Sendable {
    private let log: CallLog

    init(taskIdentifier: Int, log: CallLog) {
        self.log = log
        super.init(taskIdentifier: taskIdentifier)
    }

    override func cancel() {
        log.record("task.cancel", args: ["task": taskIdentifier])
        super.cancel()
    }
}
