//
//  AudiobookContentWaitSessionTests.swift
//  PalaceTests
//
//  The session's waits for an LCP audiobook's content (PP-5451) can now last
//  a whole download. Pinned: progress reaches the player only while the book
//  is still loading, and closing the player ends the cold-load wait.
//

import XCTest
@testable import Palace

@MainActor
final class AudiobookContentWaitSessionTests: AudiobookSessionOpenTestCase {

    private func lastSink() throws -> @MainActor @Sendable (Float) -> Void {
        try XCTUnwrap(content.progressSinks.last ?? nil, "the wait was given no progress sink")
    }

#if LCP
    /// A gate wait for A that is still running after the patron opens B must
    /// not draw A's download on B's player.
    func testGateWait_AfterPatronOpensAnotherBook_DoesNotDriveThePlayer() async throws {
        inAppNav.isEnabled = true
        content.isLocal = false
        let bookA = lcpBook("lcp-a")
        startOpen(bookA, startPlaying: true)
        await awaitConditionAsync { self.content.landed != nil }
        let sinkA = try lastSink()
        sinkA(0.4)
        XCTAssertEqual(presenter.shownDownloadProgress, [0.4], "A's progress reaches the player while A loads")

        await startParkedOpen(downloadedBook("book-b"))
        sinkA(0.5)

        XCTAssertEqual(presenter.shownDownloadProgress, [0.4], "A's progress must not reach B's player")
        await finishOpens()
    }
#endif

    /// The cold-load wait feeds the player's download bar, which also keeps
    /// the player's 30 s load error off while the download runs.
    func testRecoveryWait_ForwardsProgressToThePlayer_OnlyWhileTheBookLoads() async throws {
        inAppNav.isEnabled = true
        content.isLocal = false
        let book = downloadedBook("book-a")
        await startParkedOpen(book)
        failFirstPlay()
        await awaitConditionAsync { self.content.landed != nil }
        let sink = try lastSink()

        sink(0.4)
        XCTAssertEqual(presenter.shownDownloadProgress, [0.4])
        XCTAssertTrue(presenter.isDownloading)

        await sut.stopPlayback(dismissPhoneUI: false)
        sink(0.6)
        XCTAssertEqual(presenter.shownDownloadProgress, [0.4], "a stopped session's wait must not drive the player")
        await finishOpens()
    }

    /// Closing the player ends the cold-load wait, so a later open of the same
    /// book has its first-play failure handled instead of swallowed.
    func testStopDuringRecoveryWait_EndsTheWait_AndTheNextFailureIsHandled() async throws {
        content.isLocal = false
        let book = downloadedBook("book-a")
        await startParkedOpen(book)
        failFirstPlay()
        await awaitConditionAsync { self.content.landed != nil }
        XCTAssertTrue(sut.awaitingContentDownloadBookIds.contains(book.identifier))

        await sut.stopPlayback(dismissPhoneUI: false)

        XCTAssertFalse(sut.awaitingContentDownloadBookIds.contains(book.identifier))
        await awaitConditionAsync { self.content.landed == nil }

        await startParkedOpen(book)
        failFirstPlay()
        await awaitConditionAsync { self.content.waitCount == 2 }
        await finishOpens()
    }

    /// A cancelled wait that returns after the patron re-opened the same book
    /// must not act on that newer open.
    func testCancelledRecoveryWait_ReturningAfterAReopen_LeavesTheNewOpenAlone() async throws {
        content.isLocal = false
        content.endsCancelledWaits = false
        let book = downloadedBook("book-a")
        await startParkedOpen(book)
        failFirstPlay()
        await awaitConditionAsync { self.content.landed != nil }
        await sut.stopPlayback(dismissPhoneUI: false)
        await startParkedOpen(book)
        XCTAssertEqual(sut.state, .loading(bookId: book.identifier))

        content.land(false)
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(sut.state, .loading(bookId: book.identifier), "the old wait must not end the new open")
        XCTAssertTrue(publishedErrors.isEmpty, "\(publishedErrors)")
        await finishOpens()
    }
}

/// The session built without an injected wait uses the production one over
/// its container's download centre.
@MainActor
final class AudiobookProductionContentWaitTests: AudiobookSessionOpenTestCase {

    override var injectsContentWait: Bool { false }

    /// The wait sees the container's registered transfer, so its failure ends
    /// the wait at the next poll rather than at the 180 s bound.
    func testRecoveryWait_EndsWhenTheContainersTransferFails() async throws {
        content.isLocal = false
        let book = downloadedBook("book-a")
        let reporter = container.downloadCenter.progressReporter
        // Each transfer check reads the reporter's clock, so the count shows
        // when a poll has seen the transfer running.
        let clockReads = ClockReadCounter()
        reporter.monotonicClock = { clockReads.count += 1; return 0 }
        reporter.sendLCPContentDownloadActive(bookIdentifier: book.identifier, active: true)
        await startParkedOpen(book)
        let readsBeforeFailure = clockReads.count
        failFirstPlay()
        XCTAssertTrue(sut.awaitingContentDownloadBookIds.contains(book.identifier))
        await awaitConditionAsync { clockReads.count > readsBeforeFailure }

        reporter.sendLCPContentDownloadActive(bookIdentifier: book.identifier, active: false)

        await awaitConditionAsync(timeout: 3) { !self.sut.awaitingContentDownloadBookIds.contains(book.identifier) }
        XCTAssertFalse(sut.awaitingContentDownloadBookIds.contains(book.identifier))
        await finishOpens()
    }
}

/// Written by the reporter's clock closure, read by the test, both on the main actor.
private final class ClockReadCounter: @unchecked Sendable {
    var count = 0
}
