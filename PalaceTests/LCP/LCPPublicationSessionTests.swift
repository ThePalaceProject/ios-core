//
//  LCPPublicationSessionTests.swift
//  PalaceTests
//
//  One live background session per publication transfer, carrying the handlers
//  of the caller that is waiting on it.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

/// Palace fetches a 0.7-1.2 GB LCP archive on a background session whose
/// identifier is derived from the licence URL, and `acquirePublication` is
/// reachable more than once for one book: a reclaimed content claim, the
/// registry self-heal plus the patron opening the book, or a relaunch.
///
/// Foundation permits exactly one `URLSession` per background identifier and
/// leaves a second one undefined — it logs "A background URLSession with
/// identifier ... already exists!" and stops delivering callbacks reliably to
/// the newer delegate, which the patron sees as progress frozen at 0% — and a
/// second task on one identifier transfers the same gigabytes twice.
final class LCPPublicationSessionTests: XCTestCase {

    private var factory: SessionFactorySpy!
    /// Tasks are only ever handed to the delegate as callback arguments here,
    /// never resumed, so no request leaves the test process.
    private var taskSource: URLSession!
    private var writtenFiles: [URL] = []

    override func setUp() {
        super.setUp()
        factory = SessionFactorySpy()
        taskSource = URLSession(configuration: .ephemeral)
    }

    override func tearDown() {
        factory.teardown()
        taskSource.invalidateAndCancel()
        for file in writtenFiles { try? FileManager.default.removeItem(at: file) }
        writtenFiles = []
        super.tearDown()
    }

    // MARK: - One session, one transfer

    func testAcquireTwiceForTheSameLicence_runsOneTransferOnOneSession() throws {
        let licence = try writeLicence()
        let first = TPPLicensesService(makeSession: factory.make)
        let second = TPPLicensesService(makeSession: factory.make)

        let firstTask = first.acquirePublication(from: licence, progress: { _ in }, completion: { _, _ in })
        let secondTask = second.acquirePublication(from: licence, progress: { _ in }, completion: { _, _ in })

        XCTAssertEqual(
            factory.handles.count, 1,
            "two sessions on one background identifier is undefined behaviour, and the patron sees progress stuck at 0%"
        )
        XCTAssertEqual(
            factory.handles.first?.requests.count, 1,
            "a second task on the identifier fetches the same gigabyte archive twice"
        )
        XCTAssertNotNil(firstTask)
        XCTAssertIdentical(
            secondTask, firstTask,
            "the repeat request must be handed the transfer already running"
        )

        failTransfer(on: first)
    }

    func testAcquireForTwoDifferentLicences_runsATransferForEach() throws {
        let firstLicence = try writeLicence()
        let secondLicence = try writeLicence()
        let first = TPPLicensesService(makeSession: factory.make)
        let second = TPPLicensesService(makeSession: factory.make)

        let firstTask = first.acquirePublication(from: firstLicence, progress: { _ in }, completion: { _, _ in })
        let secondTask = second.acquirePublication(from: secondLicence, progress: { _ in }, completion: { _, _ in })

        XCTAssertEqual(factory.handles.count, 2, "two different books are two different transfers")
        XCTAssertNotNil(firstTask)
        XCTAssertNotNil(secondTask)
        XCTAssertNotIdentical(secondTask, firstTask)

        failTransfer(on: first)
        failTransfer(on: second)
    }

    // MARK: - Whose handlers fire

    func testAcquireTwiceForTheSameLicence_reportsProgressToTheCallerThatIsWaiting() throws {
        let licence = try writeLicence()
        var firstProgress: [Double] = []
        var secondProgress: [Double] = []
        let first = TPPLicensesService(makeSession: factory.make)
        let second = TPPLicensesService(makeSession: factory.make)

        _ = first.acquirePublication(from: licence, progress: { firstProgress.append($0) }, completion: { _, _ in })
        _ = second.acquirePublication(from: licence, progress: { secondProgress.append($0) }, completion: { _, _ in })

        deliverProgress(to: [first, second], written: 50, expected: 100)

        XCTAssertEqual(
            secondProgress, [0.5],
            "the caller that is waiting must see the bytes move, exactly once"
        )
        XCTAssertEqual(
            firstProgress, [],
            "the superseded caller is no longer on screen; its handler must not fire"
        )

        failTransfer(on: first)
        failTransfer(on: second)
    }

    func testAcquireTwiceForTheSameLicence_reportsFailureToTheCallerThatIsWaiting() throws {
        let licence = try writeLicence()
        var firstErrors: [Error] = []
        var secondErrors: [Error] = []
        let first = TPPLicensesService(makeSession: factory.make)
        let second = TPPLicensesService(makeSession: factory.make)

        _ = first.acquirePublication(from: licence, progress: { _ in }, completion: { _, error in
            if let error { firstErrors.append(error) }
        })
        _ = second.acquirePublication(from: licence, progress: { _ in }, completion: { _, error in
            if let error { secondErrors.append(error) }
        })

        failTransfer(on: first)
        failTransfer(on: second)

        XCTAssertEqual(secondErrors.count, 1, "the caller that is waiting must learn the transfer failed")
        XCTAssertEqual((secondErrors.first as NSError?)?.code, NSURLErrorTimedOut)
        XCTAssertEqual(firstErrors.count, 0, "the superseded caller must not be told about a transfer it no longer owns")
    }

    // MARK: - Releasing the session

    func testTransferThatCannotContinue_invalidatesTheSessionAndFreesTheIdentifier() throws {
        let licence = try writeLicence()
        let service = TPPLicensesService(makeSession: factory.make)
        _ = service.acquirePublication(from: licence, progress: { _ in }, completion: { _, _ in })
        let handle = try XCTUnwrap(factory.handles.first)

        failTransfer(on: service)

        XCTAssertEqual(
            handle.invalidations, 1,
            "a session that is never invalidated holds its identifier and its delegate for the life of the process"
        )

        let retry = TPPLicensesService(makeSession: factory.make)
        _ = retry.acquirePublication(from: licence, progress: { _ in }, completion: { _, _ in })
        XCTAssertEqual(
            factory.handles.count, 2,
            "a failed transfer must leave the book downloadable again"
        )

        failTransfer(on: retry)
    }

    func testTransferThatFinishes_handsOverTheArchiveAndInvalidatesTheSession() throws {
        let licence = try writeLicence()
        let service = TPPLicensesService(makeSession: factory.make)
        var delivered: URL?
        var reported: Error?
        // No wait: this licence has no path-in-zip, so the service hands the
        // archive over synchronously from the delegate callback below. A
        // deadline here would be a wall-clock wait on work already done — and
        // if that ever stops being synchronous, `delivered` is nil and this
        // fails loudly instead of flaking under parallel clones.
        _ = service.acquirePublication(from: licence, progress: { _ in }, completion: { url, error in
            delivered = url
            reported = error
        })
        let handle = try XCTUnwrap(factory.handles.first)

        let downloaded = try writeFile(contents: "archive bytes")
        service.urlSession(URLSession.shared, downloadTask: anyDownloadTask(), didFinishDownloadingTo: downloaded)

        let archive = try XCTUnwrap(delivered, "the caller must receive the archive it waited for")
        writtenFiles.append(archive)
        XCTAssertNil(reported)
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path),
                      "the archive must outlive the callback, which owns the download location")
        XCTAssertEqual(handle.invalidations, 1, "a finished transfer has no further use for its session")
    }

    func testTransferThatFinishesWithAnUnreadableFile_reportsTheErrorAndReleasesTheSession() throws {
        let licence = try writeLicence()
        let service = TPPLicensesService(makeSession: factory.make)
        var reported: Error?
        // Synchronous for the same reason as above: the copy of an absent file
        // throws inside the delegate callback, so the failure is reported
        // before that call returns.
        _ = service.acquirePublication(from: licence, progress: { _ in }, completion: { _, error in
            reported = error
        })
        let handle = try XCTUnwrap(factory.handles.first)

        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("never-written-\(UUID().uuidString).zip")
        service.urlSession(URLSession.shared, downloadTask: anyDownloadTask(), didFinishDownloadingTo: missing)

        XCTAssertNotNil(reported, "a download whose file cannot be read is a failure the caller must hear about")
        XCTAssertEqual(handle.invalidations, 1, "the session must be released however the transfer ended")
    }

    // MARK: - Resuming

    func testTransferThatCanResume_continuesOnTheSameSessionAndStaysAdoptable() throws {
        let licence = try writeLicence()
        let service = TPPLicensesService(makeSession: factory.make)
        let started = service.acquirePublication(from: licence, progress: { _ in }, completion: { _, _ in })
        let handle = try XCTUnwrap(factory.handles.first)

        let partial = Data("bytes already on disk".utf8)
        service.urlSession(
            URLSession.shared,
            task: anyDownloadTask(),
            didCompleteWithError: NSError(
                domain: NSURLErrorDomain, code: NSURLErrorTimedOut,
                userInfo: [NSURLSessionDownloadTaskResumeData: partial]
            )
        )

        XCTAssertEqual(handle.resumptions, [partial], "the transfer must continue from the bytes already fetched")
        XCTAssertEqual(handle.requests.count, 1, "resuming must not start the archive again from byte zero")
        XCTAssertEqual(handle.invalidations, 0, "a transfer that is continuing still needs its session")

        // A resumed transfer nothing records is a transfer nothing can observe
        // or manage: the next request for the book must be handed it.
        let later = TPPLicensesService(makeSession: factory.make)
        let adopted = later.acquirePublication(from: licence, progress: { _ in }, completion: { _, _ in })
        XCTAssertEqual(factory.handles.count, 1, "the resumed transfer is still the only one")
        XCTAssertIdentical(adopted, handle.resumedTasks.first, "the live transfer is the resumed task")
        XCTAssertNotIdentical(adopted, started, "the task that failed is not the live transfer")

        failTransfer(on: service)
    }

    /// Resuming is bounded. The counter that bounds it must advance, or a
    /// 1.2 GB archive retries for as long as the link keeps dropping — which
    /// is the saturation this path exists to avoid. Mutation reported the
    /// increment surviving: every test here drove one failure, and one failure
    /// cannot tell `+= 1` from `-= 1`.
    func testATransferThatKeepsFailing_stopsResumingAtTheAttemptCap() throws {
        let licence = try writeLicence()
        var reported: [Error] = []
        let service = TPPLicensesService(makeSession: factory.make)
        _ = service.acquirePublication(
            from: licence,
            progress: { _ in },
            completion: { _, error in if let error { reported.append(error) } }
        )
        let handle = try XCTUnwrap(factory.handles.first)

        let partial = Data("bytes already on disk".utf8)
        let resumable = NSError(
            domain: NSURLErrorDomain, code: NSURLErrorTimedOut,
            userInfo: [NSURLSessionDownloadTaskResumeData: partial]
        )

        // More failures than the cap allows, each one resumable.
        for _ in 0 ..< (TPPLicensesService.maxResumeAttempts + 2) {
            service.urlSession(URLSession.shared, task: anyDownloadTask(), didCompleteWithError: resumable)
        }

        XCTAssertEqual(
            handle.resumptions.count, TPPLicensesService.maxResumeAttempts,
            "the attempt counter must advance, or the archive resumes without end"
        )
        XCTAssertFalse(
            reported.isEmpty,
            "reaching the cap must tell the caller, not fail silently"
        )
        // The exact count is deliberately not pinned. This drives the delegate
        // more times than production can: one task reports completion once, and
        // no further task is created once the cap is reached, so the extra
        // callbacks here have no production counterpart.
    }

    // MARK: - Giving a waiting chapter the link

    /// A transfer double, so the hold's tests state transport state instead of
    /// waiting for it. The previous version drove real `URLSessionDownloadTask`s
    /// at a real host and polled for `.running`, which reaches the network and
    /// could miss the transition entirely when DNS failed fast — four of these
    /// passed alone and failed only once the full suite loaded the machine.
    private func heldTransfer(
        _ registry: LCPPublicationSessionRegistry,
        _ identifier: String,
        running: Bool = true
    ) -> FakeDownloadTask {
        let handle = FakeSessionHandle(identifier: identifier)
        _ = registry.transfer(for: identifier, delegate: makeDelegate()) { _ in handle }
        let task = FakeDownloadTask(
            identifier: identifier.hashValue, url: URL(string: "https://archive.test/\(identifier).lcpa")!,
            bytesReceived: 0, isRunning: running
        )
        registry.setTask(task, for: identifier)
        return task
    }

    /// A chapter the patron is waiting on gets the link: the background
    /// archive transfer is suspended for the load and resumed after it.
    func testChapterLoad_suspendsTheArchiveTransferAndResumesItAfterwards() throws {
        let registry = LCPPublicationSessionRegistry()
        let task = heldTransfer(registry, "hold-1")

        XCTAssertEqual(registry.holdTransfersForChapterLoad(), 1, "the running transfer must be held")
        XCTAssertEqual(task.suspensions, 1, "a held transfer gives up the link")
        XCTAssertTrue(registry.isHeldForChapterLoad("hold-1"))

        XCTAssertEqual(registry.releaseTransfersHeldForChapterLoad(), 1, "the hold must be given back")
        XCTAssertEqual(task.resumptions, 1, "the archive keeps downloading after the chapter loads")
        XCTAssertFalse(registry.isHeldForChapterLoad("hold-1"))
    }

    /// A transfer registered DURING a hold starts held, or it takes the link
    /// the hold is protecting.
    func testTransferRegisteredDuringAHold_startsHeld() throws {
        let registry = LCPPublicationSessionRegistry()
        let handle = FakeSessionHandle(identifier: "hold-2")
        _ = registry.transfer(for: "hold-2", delegate: makeDelegate()) { _ in handle }
        registry.holdTransfersForChapterLoad()

        let late = FakeDownloadTask(
            identifier: 2, url: URL(string: "https://archive.test/late.lcpa")!,
            bytesReceived: 0, isRunning: true
        )
        registry.setTask(late, for: "hold-2")

        XCTAssertTrue(registry.isHeldForChapterLoad("hold-2"))
        XCTAssertEqual(late.suspensions, 1)
        registry.releaseTransfersHeldForChapterLoad()
        XCTAssertEqual(late.resumptions, 1, "and it must be resumed with the rest")
    }

    /// A SECOND task registered inside one hold must not suspend the transfer
    /// twice.
    ///
    /// `suspend`/`resume` nest, so two suspends need two resumes and the single
    /// release can only give one — the archive would stop at the byte it had
    /// reached, which is the symptom the earlier attempt was withdrawn for.
    /// Reachable: de-duplication's `getAllTasks` callback lands mid-hold and
    /// calls `setTask` again for the surviving task.
    func testSecondTaskRegisteredInsideOneHold_isNotSuspendedTwice() throws {
        let registry = LCPPublicationSessionRegistry()
        let first = heldTransfer(registry, "hold-7")
        registry.holdTransfersForChapterLoad()
        XCTAssertEqual(first.suspensions, 1)

        let replacement = FakeDownloadTask(
            identifier: 7, url: URL(string: "https://archive.test/dup.lcpa")!,
            bytesReceived: 0, isRunning: true
        )
        registry.setTask(replacement, for: "hold-7")

        XCTAssertEqual(
            replacement.suspensions, 0,
            "the transfer is already held; suspending again needs a second resume that never comes"
        )
        XCTAssertEqual(registry.releaseTransfersHeldForChapterLoad(), 1)
        XCTAssertEqual(replacement.resumptions, 1, "and one release returns it to running")
    }

    /// A task registered after the transfer finished must not be suspended:
    /// nothing holds it any more, so nothing could ever resume it.
    func testTaskRegisteredAfterTheTransferFinished_isNotSuspended() throws {
        let registry = LCPPublicationSessionRegistry()
        _ = heldTransfer(registry, "hold-8")
        registry.holdTransfersForChapterLoad()
        registry.finish("hold-8")

        let late = FakeDownloadTask(
            identifier: 8, url: URL(string: "https://archive.test/gone.lcpa")!,
            bytesReceived: 0, isRunning: true
        )
        registry.setTask(late, for: "hold-8")

        XCTAssertEqual(
            late.suspensions, 0,
            "a transfer the registry no longer has cannot be resumed, so it must not be suspended"
        )
    }

    /// A transfer that ends while held takes its hold with it.
    func testTransferThatFinishesWhileHeld_leavesNoHoldBehind() throws {
        let registry = LCPPublicationSessionRegistry()
        _ = heldTransfer(registry, "hold-3")
        registry.holdTransfersForChapterLoad()

        registry.finish("hold-3")

        XCTAssertFalse(registry.isHeldForChapterLoad("hold-3"), "the finished transfer is gone")
        XCTAssertEqual(
            registry.releaseTransfersHeldForChapterLoad(), 0,
            "releasing must not resume a transfer that already ended"
        )
    }

    /// Releasing twice resumes nothing the second time, so the timer and the
    /// paired end cannot both return a transfer to running.
    func testReleasingAHoldTwice_resumesNothingTheSecondTime() throws {
        let registry = LCPPublicationSessionRegistry()
        let task = heldTransfer(registry, "hold-4")
        registry.holdTransfersForChapterLoad()

        XCTAssertEqual(registry.releaseTransfersHeldForChapterLoad(), 1)
        XCTAssertEqual(registry.releaseTransfersHeldForChapterLoad(), 0, "the second release is a no-op")
        XCTAssertEqual(task.resumptions, 1, "and the transfer was resumed exactly once")
    }

    /// A hold whose deadline passed is released by the next registry
    /// operation, without anyone calling release — the paired end can be lost.
    func testHoldPastItsDeadline_isReleasedWithoutTheCallback() throws {
        let registry = LCPPublicationSessionRegistry()
        let task = heldTransfer(registry, "hold-5")

        registry.holdTransfersForChapterLoad(until: Date().addingTimeInterval(-1))
        XCTAssertEqual(task.suspensions, 1, "precondition: the transfer is held")

        registry.healExpiredHoldForChapterLoad()

        XCTAssertEqual(task.resumptions, 1, "an expired hold must not strand the download")
        XCTAssertFalse(registry.isHeldForChapterLoad("hold-5"))
    }

    /// A transfer that has not started is not held: suspending it would make
    /// the release START it.
    func testTransferThatIsNotRunning_isNotHeld() throws {
        let registry = LCPPublicationSessionRegistry()
        let idle = heldTransfer(registry, "hold-6", running: false)

        XCTAssertEqual(registry.holdTransfersForChapterLoad(), 0, "nothing was moving, so nothing is held")

        registry.releaseTransfersHeldForChapterLoad()
        XCTAssertEqual(idle.resumptions, 0, "the release must not start a transfer nobody began")
    }

    // MARK: - Nothing to transfer

    func testAcquireWithAnUnparsableLicence_startsNoTransfer() throws {
        let garbage = try writeFile(contents: "not a licence", extension: "lcpl")
        let service = TPPLicensesService(makeSession: factory.make)
        var reported: Error?

        let task = service.acquirePublication(from: garbage, progress: { _ in }, completion: { _, error in
            reported = error
        })

        XCTAssertNil(task)
        XCTAssertTrue(factory.handles.isEmpty, "an unreadable licence must not claim a background identifier")
        XCTAssertNotNil(reported as? TPPLicensesServiceError)
    }

    func testAcquireWithNoPublicationLink_startsNoTransfer() throws {
        let licence = try writeLicence(links: [["rel": "status", "href": "https://example.org/status.json"]])
        let service = TPPLicensesService(makeSession: factory.make)
        var reported: Error?

        let task = service.acquirePublication(from: licence, progress: { _ in }, completion: { _, error in
            reported = error
        })

        XCTAssertNil(task)
        XCTAssertTrue(factory.handles.isEmpty, "there is nothing to fetch, so there is nothing to open a session for")
        XCTAssertNotNil(reported as? TPPLicensesServiceError)
    }

    // MARK: - Helpers

    /// A delegate for the registry's own tests. The registry keeps it only to
    /// route callbacks; these cases drive the hold directly and never deliver
    /// one, so any instance will do.
    private func makeDelegate() -> TPPLicensesService {
        TPPLicensesService(makeSession: factory.make)
    }


    /// A licence whose URL is unique per test, so its background identifier —
    /// derived from that URL — cannot collide with another test's.
    private func writeLicence(
        links: [[String: String]] = [["rel": "publication",
                                      "href": "https://storage.googleapis.com/palace/archive.lcpa"]]
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lcp-session-\(UUID().uuidString).lcpl")
        let json: [String: Any] = ["id": "urn:uuid:\(UUID().uuidString)", "links": links]
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        writtenFiles.append(url)
        return url
    }

    private func writeFile(contents: String, extension ext: String = "zip") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lcp-session-\(UUID().uuidString).\(ext)")
        try Data(contents.utf8).write(to: url)
        writtenFiles.append(url)
        return url
    }

    private func anyDownloadTask() -> URLSessionDownloadTask {
        taskSource.downloadTask(with: URL(string: "https://example.invalid/archive")!)
    }

    /// Delivers one byte-count callback to every instance, because which
    /// instance the one session took as its delegate is not the caller's
    /// business — only that the waiting caller hears about it once.
    private func deliverProgress(to services: [TPPLicensesService], written: Int64, expected: Int64) {
        for service in services {
            service.urlSession(URLSession.shared, downloadTask: anyDownloadTask(),
                               didWriteData: written, totalBytesWritten: written,
                               totalBytesExpectedToWrite: expected)
        }
    }

    /// Ends a transfer the way a link that cannot be resumed ends it. Also the
    /// cleanup path: it releases the background identifier the test claimed.
    private func failTransfer(on service: TPPLicensesService) {
        service.urlSession(
            URLSession.shared,
            task: anyDownloadTask(),
            didCompleteWithError: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        )
    }
}

// MARK: - Doubles

/// Stands in for the background `URLSession`. A unit test must not register a
/// real one: the system daemon outlives the test process and would hand the
/// next run the previous run's transfer.

// MARK: - De-duplicating the tasks the system restored

/// Cancelling a duplicate is only safe if its completion can be told apart from
/// the transfer ending: `didCompleteWithError` does not look at which task
/// completed, a cancellation maps to `.giveUp`, and `.giveUp` invalidates the
/// session the surviving task is still downloading in.
final class LCPDuplicateTaskDropTests: XCTestCase {

    private let archiveURL = URL(string: "https://storage.googleapis.com/bucket/book.lcpa")!

    func testTheLaggingDuplicate_isCancelledAndTheLeaderIsNot() {
        let service = TPPLicensesService()
        let leader = FakeDownloadTask(identifier: 11, url: archiveURL, bytesReceived: 734_003_200)
        let lagging = FakeDownloadTask(identifier: 12, url: archiveURL, bytesReceived: 4_096)
        service.dropDuplicates(among: [leader, lagging], for: archiveURL)

        XCTAssertTrue(lagging.wasCancelled, "the duplicate that has moved least must be the one dropped")
        XCTAssertFalse(leader.wasCancelled, "cancelling the task most of the way through restarts the archive from zero")
    }

    func testTheCancelledDuplicatesCompletion_isSuppressed() {
        let service = TPPLicensesService()
        let leader = FakeDownloadTask(identifier: 21, url: archiveURL, bytesReceived: 900_000)
        let lagging = FakeDownloadTask(identifier: 22, url: archiveURL, bytesReceived: 1_024)
        service.dropDuplicates(among: [leader, lagging], for: archiveURL)

        XCTAssertTrue(
            service.consumeDroppedTask(22),
            "without this the cancellation ends the whole transfer and the patron sits at N% with no error"
        )
        XCTAssertFalse(
            service.consumeDroppedTask(21),
            "the surviving task's completion is the real one and must not be swallowed"
        )
    }

    func testASingleOutstandingTask_isNeverCancelled() {
        let service = TPPLicensesService()
        let only = FakeDownloadTask(identifier: 31, url: archiveURL, bytesReceived: 512)

        service.dropDuplicates(among: [only], for: archiveURL)

        XCTAssertFalse(only.wasCancelled, "a lone task is the transfer; cancelling it stops the archive")
        XCTAssertFalse(service.consumeDroppedTask(31), "nothing was dropped, so nothing may be suppressed")
    }

    func testATaskForADifferentArchive_isLeftAlone() {
        let service = TPPLicensesService()
        let mine = FakeDownloadTask(identifier: 41, url: archiveURL, bytesReceived: 10)
        let other = FakeDownloadTask(
            identifier: 42,
            url: URL(string: "https://storage.googleapis.com/bucket/other.lcpa")!,
            bytesReceived: 999_999
        )
        service.dropDuplicates(among: [mine, other], for: archiveURL)

        XCTAssertFalse(other.wasCancelled, "another book's transfer shares the session only by accident")
        XCTAssertFalse(mine.wasCancelled, "with one task for this archive there is no duplicate to drop")
    }
}

/// A task whose progress and URL are fixed. Conforms to the seam rather than
/// subclassing `URLSessionDownloadTask`, which has no accessible initializer.
private final class FakeDownloadTask: OutstandingArchiveTask, @unchecked Sendable {
    let taskIdentifier: Int
    let archiveURL: URL?
    let bytesTransferred: Int64
    let isFinished: Bool
    private(set) var wasCancelled = false
    /// Suspend/resume are recorded rather than counted into one flag, so a
    /// double release is visible as two resumes instead of reading the same as
    /// one.
    private(set) var suspensions = 0
    private(set) var resumptions = 0
    var isRunning: Bool

    init(
        identifier: Int,
        url: URL,
        bytesReceived: Int64,
        isFinished: Bool = false,
        isRunning: Bool = true
    ) {
        taskIdentifier = identifier
        archiveURL = url
        bytesTransferred = bytesReceived
        self.isFinished = isFinished
        self.isRunning = isRunning
    }

    func cancelTransfer() { wasCancelled = true }
    func suspendTransfer() { suspensions += 1; isRunning = false }
    func resumeTransfer() { resumptions += 1; isRunning = true }
}

// MARK: - Choosing which duplicate task survives

/// A relaunch during a transfer leaves the system holding the previous
/// process's task while this process starts its own. Both move the same
/// gigabytes and either can complete, so one has to go — and it must be the one
/// that has made least progress, or a nearly-finished archive restarts at zero.
final class LCPDuplicateTaskChoiceTests: XCTestCase {

    func testOneOutstandingTask_isNotDeduplicated() {
        XCTAssertNil(
            TPPLicensesService.indexOfTaskToKeep(bytesReceived: [1_000]),
            "a lone task is the transfer; cancelling or re-recording it would stop the archive"
        )
    }

    func testNoOutstandingTasks_isNotDeduplicated() {
        XCTAssertNil(
            TPPLicensesService.indexOfTaskToKeep(bytesReceived: []),
            "nothing outstanding means nothing to choose between"
        )
    }

    func testTheFurthestAlongTaskSurvives() {
        XCTAssertEqual(
            TPPLicensesService.indexOfTaskToKeep(bytesReceived: [0, 734_003_200, 4_096]),
            1,
            "keeping a fresh task over one most of the way through a gigabyte restarts the transfer from zero"
        )
    }

    func testEqualProgress_keepsTheFirst() {
        XCTAssertEqual(
            TPPLicensesService.indexOfTaskToKeep(bytesReceived: [2_048, 2_048]),
            0,
            "with nothing to choose between them the answer must still be one task, not none"
        )
    }
}

private final class FakeSessionHandle: LCPPublicationSessionHandle {
    /// What `getAllTasks` reports. Empty by default, so a test that does not
    /// care about duplicates behaves as a session with nothing outstanding.
    var outstandingTasks: [URLSessionTask] = []

    func getAllTasks(completionHandler: @escaping @Sendable ([URLSessionTask]) -> Void) {
        completionHandler(outstandingTasks)
    }

    let identifier: String
    private(set) var requests: [URLRequest] = []
    private(set) var resumptions: [Data] = []
    private(set) var resumedTasks: [URLSessionDownloadTask] = []
    private(set) var invalidations = 0

    private let taskSource = URLSession(configuration: .ephemeral)

    init(identifier: String) {
        self.identifier = identifier
    }

    func downloadTask(with request: URLRequest) -> URLSessionDownloadTask {
        requests.append(request)
        return taskSource.downloadTask(with: request)
    }

    func downloadTask(withResumeData resumeData: Data) -> URLSessionDownloadTask {
        resumptions.append(resumeData)
        let task = taskSource.downloadTask(with: URL(string: "https://example.invalid/resumed")!)
        resumedTasks.append(task)
        return task
    }

    func finishTasksAndInvalidate() {
        invalidations += 1
    }

    func teardown() {
        taskSource.invalidateAndCancel()
    }
}

private final class SessionFactorySpy {
    private(set) var handles: [FakeSessionHandle] = []

    func make(identifier: String,
              isolateCredentials: Bool,
              delegate: URLSessionDelegate) -> LCPPublicationSessionHandle {
        let handle = FakeSessionHandle(identifier: identifier)
        handles.append(handle)
        return handle
    }

    func teardown() {
        handles.forEach { $0.teardown() }
    }
}
