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

    private func awaitLanding() async -> Bool {
        await AudiobookSessionManager.awaitAudiobookContentLocal(
            bookId,
            pollInterval: 1,
            isLocal: { [unowned self] _ in self.landed },
            isTransferActive: { [unowned self] in self.reporter.isLCPContentTransferActive(for: $0) },
            downloadFraction: { _ in 0 },
            now: { [unowned self] in self.clock },
            sleep: { [unowned self] interval in
                self.clock += interval
                self.onTick?(self.clock)
            }
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
            sleep: { [unowned self] interval in self.clock += interval }
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
}
