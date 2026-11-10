//
//  SharedPlaytimeUploaderTests.swift
//  PalaceTests
//
//  The play-time uploader sends on the policy's schedule and when the app
//  goes to the background, and never loses or double-sends an entry (PP-5508).
//

import Combine
import XCTest
@testable import Palace

/// Holds every POST until the test answers it, so a send can be kept in
/// flight while another trigger fires.
private final class HeldPlaytimeExecutor: TPPNetworkExecutor, @unchecked Sendable {
    typealias Completion = (Data?, URLResponse?, Error?) -> Void

    private let lock = NSLock()
    private var _bodies: [Data?] = []
    private var _completions: [(url: URL, completion: Completion?)] = []

    convenience init() {
        self.init(cachingStrategy: .ephemeral)
    }

    var postCount: Int { lock.withLock { _bodies.count } }

    /// Entry IDs of each POST, in send order.
    var sentEntryIds: [[String]] {
        lock.withLock { _bodies.map(Self.entryIds) }
    }

    override func POST(_ request: URLRequest,
                       useTokenIfAvailable: Bool,
                       completion: ((Data?, URLResponse?, Error?) -> Void)?) -> URLSessionDataTask? {
        lock.withLock {
            _bodies.append(request.httpBody)
            _completions.append((request.url!, completion))
        }
        return nil
    }

    /// Answers POST `index` with `status`; a 2xx carries a per-entry 201 body.
    /// A POST that was never sent fails the test instead of trapping.
    func respond(_ index: Int, status: Int, file: StaticString = #filePath, line: UInt = #line) {
        guard let (url, completion, body) = lock.withLock({ () -> (URL, Completion?, Data?)? in
            guard _completions.indices.contains(index) else { return nil }
            return (_completions[index].url, _completions[index].completion, _bodies[index])
        }) else {
            XCTFail("no POST \(index) to answer", file: file, line: line)
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "1.1", headerFields: nil)
        var data: Data?
        if (200..<300).contains(status) {
            let entries = Self.entryIds(body).map { ["status": 201, "message": "created", "id": $0] as [String: Any] }
            data = try? JSONSerialization.data(withJSONObject: ["responses": entries])
        }
        completion?(data, response, nil)
    }

    func fail(_ index: Int, file: StaticString = #filePath, line: UInt = #line) {
        guard let completion = lock.withLock({ _completions.indices.contains(index) ? _completions[index].completion : nil }) else {
            XCTFail("no POST \(index) to fail", file: file, line: line)
            return
        }
        completion(nil, nil, NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet))
    }

    private static func entryIds(_ body: Data?) -> [String] {
        guard let body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let entries = json["timeEntries"] as? [[String: Any]] else { return [] }
        return entries.compactMap { $0["id"] as? String }
    }
}

@MainActor
final class SharedPlaytimeUploaderTests: XCTestCase {

    private let libraryId = "urn:uuid:playtime-uploader-library"
    private let trackingURL = URL(string: "https://cm.example.com/lib/playtimes/book-1")!

    private var scheduler: FakeActivityTickScheduler!
    private var policy: ActivityPolicy!
    private var executor: HeldPlaytimeExecutor!
    private var sut: AudiobookDataManager!
    private var libraryChanges: PassthroughSubject<CurrentLibraryChange, Never>!

    override func setUp() async throws {
        try await super.setUp()
        clearStoreFile()
        scheduler = FakeActivityTickScheduler()
        policy = makeTestActivityPolicy(scheduler: scheduler)
        executor = HeldPlaytimeExecutor()
        libraryChanges = PassthroughSubject()
        await makeSut()
    }

    override func tearDown() async throws {
        sut = nil
        libraryChanges = nil
        executor = nil
        policy = nil
        scheduler = nil
        clearStoreFile()
        try await super.tearDown()
    }

    // MARK: - Schedule

    func testSchedule_InEveryVisibility_ArmsFifteenMinuteTimer() {
        XCTAssertEqual(scheduler.armedIntervals, [15 * 60], "launch state is background")

        policy.setScene(.active)
        policy.setScene(.background)

        XCTAssertEqual(scheduler.armedIntervals, [15 * 60],
                       "visibility changes must not re-arm or shorten the upload timer")
    }

    // MARK: - Timer send

    func testTimerTick_WithQueuedEntry_SendsItAndClearsQueueOnSuccess() {
        save("entry-1")

        tick()

        XCTAssertEqual(executor.sentEntryIds, [["entry-1"]])
        executor.respond(0, status: 200)
        drain()
        XCTAssertTrue(sut.store.queue.isEmpty, "a sent entry leaves the queue")
    }

    func testTimerTick_WhenSendFailsWith500_KeepsEntryAndResendsOnNextTick() {
        save("entry-1")
        tick()
        executor.respond(0, status: 500)
        drain()
        XCTAssertEqual(sut.store.queue.map(\.id), ["entry-1"], "a failed send keeps the entry")

        tick()

        XCTAssertEqual(executor.sentEntryIds, [["entry-1"], ["entry-1"]])
    }

    func testTimerTick_WhenNetworkFails_KeepsEntryAndResendsOnNextTick() {
        save("entry-1")
        tick()
        executor.fail(0)
        drain()
        XCTAssertEqual(sut.store.queue.map(\.id), ["entry-1"])

        tick()

        XCTAssertEqual(executor.sentEntryIds, [["entry-1"], ["entry-1"]])
    }

    func testTimerTick_WithEmptyQueue_SendsNothing() {
        tick()

        XCTAssertEqual(executor.postCount, 0)
    }

    // MARK: - Background flush

    func testGoingToBackground_SendsQueueOnceWithoutATick() {
        policy.setScene(.active)
        save("entry-1")

        policy.setScene(.background)
        drain()

        XCTAssertEqual(executor.sentEntryIds, [["entry-1"]])
    }

    func testStateChangesWhileStillInBackground_DoNotFlushAgain() {
        policy.setScene(.active)
        save("entry-1")
        policy.setScene(.background)
        drain()
        executor.respond(0, status: 500)
        drain()

        policy.setPlayer(.mini)
        policy.setProtectedDataAvailable(false)
        drain()

        XCTAssertEqual(executor.postCount, 1, "only the visible-to-background transition flushes")
    }

    func testLaunchInBackground_DoesNotFlush() {
        save("entry-1")

        policy.setPlayer(.expanded)
        drain()

        XCTAssertEqual(executor.postCount, 0, "the launch state is not a transition to the background")
    }

    func testInactiveScene_CountsAsVisible_AndDoesNotFlush() {
        policy.setScene(.active)
        save("entry-1")

        policy.setScene(.inactive)
        drain()

        XCTAssertEqual(executor.postCount, 0)
    }

    func testBackgroundWithCarPlayConnected_DoesNotFlushUntilCarPlayDisconnects() {
        policy.setScene(.active)
        policy.setCarPlayConnected(true)
        save("entry-1")

        policy.setScene(.background)
        drain()
        XCTAssertEqual(executor.postCount, 0, "CarPlay keeps the app visible")

        policy.setCarPlayConnected(false)
        drain()
        XCTAssertEqual(executor.sentEntryIds, [["entry-1"]])
    }

    // MARK: - Overlap

    func testBackgroundFlushWhileTimerSendInFlight_DoesNotSendTheEntryTwice() {
        policy.setScene(.active)
        save("entry-1")
        tick()
        XCTAssertEqual(executor.postCount, 1)

        policy.setScene(.background)
        drain()

        XCTAssertEqual(executor.postCount, 1, "an entry already in flight is not sent again")
        executor.respond(0, status: 200)
        drain()
        tick()
        XCTAssertEqual(executor.postCount, 1, "a delivered entry is never resent")
        XCTAssertTrue(sut.store.queue.isEmpty)
    }

    func testOverlappingTrigger_WhenInFlightSendFails_ResendsEntryOnNextTrigger() {
        policy.setScene(.active)
        save("entry-1")
        tick()
        policy.setScene(.background)
        drain()

        executor.respond(0, status: 503)
        drain()
        tick()

        XCTAssertEqual(executor.sentEntryIds, [["entry-1"], ["entry-1"]],
                       "an entry whose send failed is sent again, not dropped")
    }

    func testEntrySavedWhileSendInFlight_IsSentAloneOnNextTrigger() {
        save("entry-1")
        tick()
        save("entry-2")

        tick()

        XCTAssertEqual(executor.sentEntryIds, [["entry-1"], ["entry-2"]])
        executor.respond(1, status: 200)
        executor.respond(0, status: 200)
        drain()
        XCTAssertTrue(sut.store.queue.isEmpty, "both answers clear their own entries")
    }

    // MARK: - Library switch

    func testLibrarySwitch_ReleasesAnUnansweredSend_ForTheNextTrigger() {
        save("entry-1")
        tick()

        libraryChanges.send(.selected)
        tick()

        XCTAssertEqual(executor.sentEntryIds, [["entry-1"], ["entry-1"]],
                       "a send the switch cancelled must not hold its entry forever")
    }

    func testLateAnswerToACancelledSend_DoesNotReleaseTheNewerSend() {
        save("entry-1")
        tick()
        libraryChanges.send(.selected)
        tick()

        executor.respond(0, status: 500)
        drain()
        tick()

        XCTAssertEqual(executor.postCount, 2, "the newer send still carries the entry")
    }

    // MARK: - Helpers

    private func makeSut() async {
        let libraryId = self.libraryId
        sut = AudiobookDataManager(
            networkService: executor,
            currentAccountIdProvider: { libraryId },
            currentLibraryChanges: libraryChanges.eraseToAnyPublisher(),
            uploadTriggers: PlaytimeUploadSchedule.triggers(from: policy)
        )
        sut.store.queue.removeAll()
        sut.store.urls.removeAll()
        // The constructor's reachability subscription may queue a sync of the
        // (empty) queue; let it finish before the test starts counting POSTs.
        await drainMainQueueAsync()
        drain()
    }

    private func save(_ id: String) {
        sut.save(time: AudiobookTimeEntry(
            id: id, bookId: "book-1", libraryId: libraryId,
            timeTrackingUrl: trackingURL, duringMinute: "2026-11-10T10:00Z", duration: 30
        ))
        drain()
    }

    private func tick() {
        scheduler.fireAll()
        drain()
    }

    /// `save`, `syncValues` and each answer's handling all run on the serial
    /// `syncQueue`, so an empty block there joins them.
    private func drain() {
        sut.syncQueue.sync {}
    }

    private func clearStoreFile() {
        if let dir = TPPBookContentMetadataFilesHelper.directory(for: "timetracker") {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("store.json"))
        }
    }
}
