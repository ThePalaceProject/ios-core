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
        let completed = expectation(description: "the archive is handed to the caller")
        _ = service.acquirePublication(from: licence, progress: { _ in }, completion: { url, error in
            delivered = url
            reported = error
            completed.fulfill()
        })
        let handle = try XCTUnwrap(factory.handles.first)

        let downloaded = try writeFile(contents: "archive bytes")
        service.urlSession(URLSession.shared, downloadTask: anyDownloadTask(), didFinishDownloadingTo: downloaded)

        wait(for: [completed], timeout: 2.0)
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
        let completed = expectation(description: "the failure reaches the caller")
        _ = service.acquirePublication(from: licence, progress: { _ in }, completion: { _, error in
            reported = error
            completed.fulfill()
        })
        let handle = try XCTUnwrap(factory.handles.first)

        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("never-written-\(UUID().uuidString).zip")
        service.urlSession(URLSession.shared, downloadTask: anyDownloadTask(), didFinishDownloadingTo: missing)

        wait(for: [completed], timeout: 2.0)
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
private final class FakeSessionHandle: LCPPublicationSessionHandle {
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
