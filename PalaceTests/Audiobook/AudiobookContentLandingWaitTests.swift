//
//  AudiobookContentLandingWaitTests.swift
//
//  The wait for an LCP audiobook's `.lcpa` to land (PP-5451). A download that
//  is still reporting progress must not end the wait; one that failed, went
//  idle, or never ran must. Driven on a fake clock against the real
//  `DownloadProgressReporter`, which is what production asks about the transfer.
//

import XCTest
@testable import Palace

@MainActor
final class AudiobookContentLandingWaitTests: XCTestCase {

    private let bookId = "urn:book:5451"
    private var clock: TimeInterval = 0
    private var landed = false
    private var reporter: DownloadProgressReporter!
    /// Runs once per poll, after the clock advances, so a test can script the
    /// transfer against time.
    private var onTick: ((TimeInterval) -> Void)?

    override func setUp() {
        super.setUp()
        clock = 0
        polls = 0
        landed = false
        onTick = nil
        reporter = DownloadProgressReporter(
            accessibilityAnnouncements: TPPAccessibilityAnnouncementCenter(),
            downloadAnnouncementService: DownloadAnnouncementService()
        )
        reporter.monotonicClock = { [unowned self] in self.clock }
    }

    override func tearDown() {
        onTick = nil
        reporter = nil
        super.tearDown()
    }

    /// More polls than any scripted case needs. Past it the test fails and
    /// reports the content landed, so a loop that does not end cannot hang the suite.
    private let pollLimit = 2_000
    private var polls = 0

    private func fakeSleep(_ interval: TimeInterval) {
        polls += 1
        if polls == pollLimit {
            XCTFail("the wait did not end within \(pollLimit) polls")
            landed = true
        }
        clock += interval
        onTick?(clock)
    }

    private func awaitLanding(
        downloadFraction: @escaping @MainActor (String) -> Float = { _ in 0 },
        onProgress: (@MainActor @Sendable (Float) -> Void)? = nil
    ) async -> Bool {
        await AudiobookSessionManager.awaitAudiobookContentLocal(
            bookId,
            pollInterval: 1,
            isLocal: { [unowned self] _ in self.landed },
            isTransferActive: { [unowned self] in self.reporter.isLCPContentTransferActive(for: $0) },
            downloadFraction: downloadFraction,
            now: { [unowned self] in self.clock },
            sleep: { [unowned self] in self.fakeSleep($0) },
            onProgress: onProgress
        )
    }

    /// The patron's case: a download still moving at 40% after three minutes
    /// must keep the player loading and open it when the archive lands.
    func testWait_WhenDownloadKeepsProgressingPast180s_WaitsAndReportsLanded() async {
        reporter.sendLCPContentDownloadActive(bookIdentifier: bookId, active: true)
        onTick = { [unowned self] t in
            if t < 400 {
                self.reporter.sendProgress(bookIdentifier: self.bookId, progress: t / 1000)
            } else {
                self.landed = true
                self.reporter.sendLCPContentDownloadActive(bookIdentifier: self.bookId, active: false)
            }
        }

        let result = await awaitLanding()

        XCTAssertTrue(result)
        XCTAssertEqual(clock, 400)
    }

    /// A transfer that stops reporting is declared dead by the reporter's idle
    /// window, and the wait ends then rather than running on.
    func testWait_WhenDownloadStallsMidway_ReportsUnavailableAfterIdleWindow() async {
        reporter.sendLCPContentDownloadActive(bookIdentifier: bookId, active: true)
        onTick = { [unowned self] t in
            if t <= 100 {
                self.reporter.sendProgress(bookIdentifier: self.bookId, progress: 0.4)
            }
        }

        let result = await awaitLanding()

        XCTAssertFalse(result)
        let stallEnd = 100 + DownloadProgressReporter.contentTransferIdleTimeout
        XCTAssertEqual(clock, stallEnd + 1)
    }

    /// A failed transfer closes its registration without content; the alert
    /// must follow at once, not after the remaining minutes of a fixed window.
    func testWait_WhenDownloadFails_ReportsUnavailablePromptly() async {
        reporter.sendLCPContentDownloadActive(bookIdentifier: bookId, active: true)
        onTick = { [unowned self] t in
            if t < 20 {
                self.reporter.sendProgress(bookIdentifier: self.bookId, progress: 0.1)
            } else if t == 20 {
                self.reporter.sendLCPContentDownloadActive(bookIdentifier: self.bookId, active: false)
            }
        }

        let result = await awaitLanding()

        XCTAssertFalse(result)
        XCTAssertEqual(clock, 20)
    }

    /// A transfer clears its registration after the archive is moved into
    /// place, so the poll that first sees it inactive must still see the file.
    func testWait_WhenDownloadCompletesBetweenPolls_ReportsLanded() async {
        reporter.sendLCPContentDownloadActive(bookIdentifier: bookId, active: true)
        onTick = { [unowned self] t in
            if t == 30 {
                self.landed = true
                self.reporter.sendLCPContentDownloadActive(bookIdentifier: self.bookId, active: false)
            } else if t < 30 {
                self.reporter.sendProgress(bookIdentifier: self.bookId, progress: 0.5)
            }
        }

        let result = await awaitLanding()

        XCTAssertTrue(result)
        XCTAssertEqual(clock, 30)
    }

    /// The archive is moved into place after the poll's existence check and
    /// before its transfer check; the wait must report it landed.
    func testWait_WhenArchiveLandsBetweenChecks_ReportsLanded() async {
        reporter.sendLCPContentDownloadActive(bookIdentifier: bookId, active: true)
        let result = await AudiobookSessionManager.awaitAudiobookContentLocal(
            bookId,
            pollInterval: 1,
            isLocal: { [unowned self] _ in self.landed },
            isTransferActive: { [unowned self] id in
                if self.clock >= 30 {
                    self.landed = true
                    self.reporter.sendLCPContentDownloadActive(bookIdentifier: id, active: false)
                } else {
                    self.reporter.sendProgress(bookIdentifier: id, progress: 0.5)
                }
                return self.reporter.isLCPContentTransferActive(for: id)
            },
            downloadFraction: { _ in 0 },
            now: { [unowned self] in self.clock },
            sleep: { [unowned self] in self.fakeSleep($0) }
        )

        XCTAssertTrue(result)
        XCTAssertEqual(clock, 30)
    }

    /// No transfer registered: the existing 180 s window still applies.
    func testWait_WhenNoDownloadIsRunning_ReportsUnavailableAtTimeout() async {
        let result = await awaitLanding()

        XCTAssertFalse(result)
        XCTAssertEqual(clock, 180)
    }

    /// No transfer registered, but the file appears (another writer): landed.
    func testWait_WhenNoDownloadIsRunningButFileLands_ReportsLanded() async {
        onTick = { [unowned self] t in
            if t == 50 { self.landed = true }
        }

        let result = await awaitLanding()

        XCTAssertTrue(result)
        XCTAssertEqual(clock, 50)
    }

    /// A transfer queued behind another archive starts late; once it reports
    /// progress the 180 s window no longer ends the wait.
    func testWait_WhenQueuedDownloadStartsLateAndProgresses_WaitsAndReportsLanded() async {
        onTick = { [unowned self] t in
            if t == 100 {
                self.reporter.sendLCPContentDownloadActive(bookIdentifier: self.bookId, active: true)
            } else if t > 100 && t < 300 {
                self.reporter.sendProgress(bookIdentifier: self.bookId, progress: 0.5)
            } else if t >= 300 {
                self.landed = true
            }
        }

        let result = await awaitLanding()

        XCTAssertTrue(result)
        XCTAssertEqual(clock, 300)
    }

    /// The content already on disk: no wait at all.
    func testWait_WhenContentAlreadyLocal_ReturnsLandedWithoutPolling() async {
        landed = true

        let result = await awaitLanding()

        XCTAssertTrue(result)
        XCTAssertEqual(clock, 0)
    }

    /// Each poll forwards the download fraction to the sink, so the player's
    /// bar moves while the patron waits.
    func testWait_WithProgressSink_ForwardsTheDownloadFractionEachPoll() async {
        reporter.sendLCPContentDownloadActive(bookIdentifier: bookId, active: true)
        onTick = { [unowned self] t in
            self.reporter.sendProgress(bookIdentifier: self.bookId, progress: t / 10)
            if t == 3 { self.landed = true }
        }
        var forwarded: [Float] = []

        let result = await awaitLanding(
            downloadFraction: { [unowned self] _ in Float(self.clock / 10) },
            onProgress: { forwarded.append($0) }
        )

        XCTAssertTrue(result)
        XCTAssertEqual(forwarded, [0, 0.1, 0.2])
    }

    /// A transfer whose fraction goes backwards (a restarted range) is still
    /// alive; the wait keeps going and the sink gets the values as reported.
    func testWait_WhenProgressRegresses_KeepsWaitingAndForwardsIt() async {
        reporter.sendLCPContentDownloadActive(bookIdentifier: bookId, active: true)
        let fractions: [Float] = [0.5, 0.6, 0.2, 0.3]
        onTick = { [unowned self] t in
            if Int(t) < fractions.count {
                self.reporter.sendProgress(bookIdentifier: self.bookId, progress: Double(fractions[Int(t)]))
            } else {
                self.landed = true
            }
        }
        var forwarded: [Float] = []

        let result = await awaitLanding(
            downloadFraction: { [unowned self] _ in fractions[min(Int(self.clock), fractions.count - 1)] },
            onProgress: { forwarded.append($0) }
        )

        XCTAssertTrue(result)
        XCTAssertEqual(forwarded, fractions)
        XCTAssertEqual(clock, 4)
    }

    /// Cancelling the waiting task ends the wait at the next poll, even with a
    /// live transfer, because `Task.sleep` returns at once once cancelled.
    func testWait_WhenTaskIsCancelled_EndsAtTheNextPoll() async {
        reporter.sendLCPContentDownloadActive(bookIdentifier: bookId, active: true)
        onTick = { [unowned self] t in
            self.reporter.sendProgress(bookIdentifier: self.bookId, progress: 0.3)
            if t == 5 { withUnsafeCurrentTask { $0?.cancel() } }
        }

        let result = await awaitLanding()

        XCTAssertFalse(result)
        XCTAssertEqual(clock, 5)
    }

    /// The production factory reads the transfer from the download centre it is
    /// given: a download still progressing past 180 s keeps the wait open.
    func testFactory_WhenContainerTransferKeepsProgressingPast180s_WaitsUntilItEnds() async {
        let center = makeTestAppContainer().downloadCenter
        center.progressReporter.monotonicClock = { [unowned self] in self.clock }
        center.progressReporter.sendLCPContentDownloadActive(bookIdentifier: bookId, active: true)
        onTick = { [unowned self] t in
            if t < 400 {
                center.progressReporter.sendProgress(bookIdentifier: self.bookId, progress: t / 1000)
            } else {
                center.progressReporter.sendLCPContentDownloadActive(bookIdentifier: self.bookId, active: false)
            }
        }
        let wait = AudiobookSessionManager.contentLandingWait(
            downloadCenter: center,
            now: { [unowned self] in self.clock },
            sleep: { [unowned self] in self.fakeSleep($0) }
        )

        let result = await wait(bookId, nil)

        XCTAssertFalse(result, "no file was written for the book")
        XCTAssertEqual(clock, 400)
    }
}
