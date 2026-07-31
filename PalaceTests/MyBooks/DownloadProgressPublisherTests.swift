//
//  DownloadProgressPublisherTests.swift
//  PalaceTests
//
//  Unit tests for DownloadProgressReporter: progress publishing, error publishing,
//  accessibility announcements, and broadcast throttling.
//

import XCTest
import Combine
@testable import Palace

final class DownloadProgressPublisherTests: XCTestCase {

    private var reporter: DownloadProgressReporter!
    private var cancellables: Set<AnyCancellable>!

    override func setUp() {
        super.setUp()
        cancellables = []
        reporter = DownloadProgressReporter(
            accessibilityAnnouncements: TPPAccessibilityAnnouncementCenter(
                postHandler: { _, _ in },
                isVoiceOverRunning: { false }
            )
        )
    }

    override func tearDown() {
        cancellables = nil
        reporter = nil
        super.tearDown()
    }

    // MARK: - Progress Publishing

    func testSendProgress_publishesOnProgressPublisher() {
        let expectation = XCTestExpectation(description: "Progress received")
        var receivedBookId: String?
        var receivedProgress: Double?

        reporter.downloadProgressPublisher
            .sink { (bookId, progress) in
                receivedBookId = bookId
                receivedProgress = progress
                expectation.fulfill()
            }
            .store(in: &cancellables)

        reporter.sendProgress(bookIdentifier: "book-123", progress: 0.75)

        wait(for: [expectation], timeout: 2.0)
        XCTAssertEqual(receivedBookId, "book-123")
        XCTAssertEqual(receivedProgress ?? 0, 0.75, accuracy: 0.001)
    }

    func testSendProgress_multipleUpdates_allReceived() {
        let expectation = XCTestExpectation(description: "All progress received")
        expectation.expectedFulfillmentCount = 3
        var progressValues: [Double] = []

        reporter.downloadProgressPublisher
            .sink { (_, progress) in
                progressValues.append(progress)
                expectation.fulfill()
            }
            .store(in: &cancellables)

        reporter.sendProgress(bookIdentifier: "book-1", progress: 0.25)
        reporter.sendProgress(bookIdentifier: "book-1", progress: 0.50)
        reporter.sendProgress(bookIdentifier: "book-1", progress: 1.0)

        wait(for: [expectation], timeout: 2.0)
        XCTAssertEqual(progressValues.count, 3)
    }

    func testSendProgress_differentBooks_publishesSeparately() {
        let expectation = XCTestExpectation(description: "Different books received")
        expectation.expectedFulfillmentCount = 2
        var receivedIds: [String] = []

        reporter.downloadProgressPublisher
            .sink { (bookId, _) in
                receivedIds.append(bookId)
                expectation.fulfill()
            }
            .store(in: &cancellables)

        reporter.sendProgress(bookIdentifier: "book-A", progress: 0.3)
        reporter.sendProgress(bookIdentifier: "book-B", progress: 0.6)

        wait(for: [expectation], timeout: 2.0)
        XCTAssertTrue(receivedIds.contains("book-A"))
        XCTAssertTrue(receivedIds.contains("book-B"))
    }

    // MARK: - Error Publishing

    func testPublishAndAnnounceError_publishesOnErrorPublisher() {
        let expectation = XCTestExpectation(description: "Error received")
        var receivedError: DownloadErrorInfo?

        reporter.downloadErrorPublisher
            .sink { errorInfo in
                receivedError = errorInfo
                expectation.fulfill()
            }
            .store(in: &cancellables)

        let errorInfo = DownloadErrorInfo(
            bookId: "error-book",
            title: "Download Failed",
            message: "Network error occurred"
        )

        reporter.publishAndAnnounceError(errorInfo)

        wait(for: [expectation], timeout: 2.0)
        XCTAssertEqual(receivedError?.bookId, "error-book")
        XCTAssertEqual(receivedError?.title, "Download Failed")
        XCTAssertEqual(receivedError?.message, "Network error occurred")
    }

    func testPublishAndAnnounceError_withRetryAction() {
        let expectation = XCTestExpectation(description: "Error with retry received")
        var receivedError: DownloadErrorInfo?

        reporter.downloadErrorPublisher
            .sink { errorInfo in
                receivedError = errorInfo
                expectation.fulfill()
            }
            .store(in: &cancellables)

        var retryCalled = false
        let errorInfo = DownloadErrorInfo(
            bookId: "retry-book",
            title: "Borrow Failed",
            message: "Try again",
            retryAction: { retryCalled = true }
        )

        reporter.publishAndAnnounceError(errorInfo)

        wait(for: [expectation], timeout: 2.0)
        XCTAssertNotNil(receivedError?.retryAction)
        receivedError?.retryAction?()
        XCTAssertTrue(retryCalled)
    }

    // MARK: - Broadcast Update

    func testBroadcastUpdate_postsNotification() {
        var receivedNotification = false
        let notificationExpectation = expectation(
            forNotification: Notification.Name.TPPMyBooksDownloadCenterDidChange,
            object: nil,
            handler: { _ in receivedNotification = true; return true }
        )

        reporter.broadcastUpdate()

        wait(for: [notificationExpectation], timeout: 2.0)
        XCTAssertTrue(receivedNotification, "broadcastUpdate must post TPPMyBooksDownloadCenterDidChange")
    }

    func testBroadcastUpdate_throttles_rapidCalls() {
        var notificationCount = 0
        let token = NotificationCenter.default.addObserver(
            forName: Notification.Name.TPPMyBooksDownloadCenterDidChange,
            object: nil,
            queue: .main
        ) { _ in
            notificationCount += 1
        }

        // Fire many rapid updates
        for _ in 0..<10 {
            reporter.broadcastUpdate()
        }

        // The publisher emits one notification immediately and schedules a
        // single trailing broadcast at +0.5s. Poll until the trailing fires
        // (count >= 2) rather than sleeping for a fixed window. Generous
        // 5s timeout keeps the test resilient under loaded CI without
        // disguising a real regression as flake.
        awaitCondition(timeout: 5.0) { notificationCount >= 2 }
        NotificationCenter.default.removeObserver(token)

        // Should have throttled - fewer notifications than calls
        // At minimum 1 (first), at most a few (first + delayed)
        XCTAssertGreaterThan(notificationCount, 0)
        XCTAssertLessThan(notificationCount, 10, "Should throttle broadcasts")
    }

    // MARK: - Accessibility Announcements (smoke tests)

    func testAnnounceDownloadStarted_doesNotCrash() {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        reporter.announceDownloadStarted(for: book)
        // Reporter must still be in a usable state after announcement
        XCTAssertNotNil(reporter.downloadProgressPublisher, "Publisher must remain valid after announcement")
    }

    func testAnnounceDownloadProgress_doesNotCrash() {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        reporter.announceDownloadProgress(for: book, progress: 0.5)
        // Progress value must not corrupt reporter state
        XCTAssertNotNil(reporter.downloadProgressPublisher, "Publisher must remain valid after progress announcement")
    }

    func testAnnounceDownloadCompleted_doesNotCrash() {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        reporter.announceDownloadCompleted(for: book)
        XCTAssertNotNil(reporter.downloadProgressPublisher, "Publisher must remain valid after completion announcement")
    }

    func testAnnounceDownloadFailed_doesNotCrash() {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        reporter.announceDownloadFailed(for: book)
        XCTAssertNotNil(reporter.downloadErrorPublisher, "Error publisher must remain valid after failure announcement")
    }

    func testAnnounceBorrowStarted_doesNotCrash() {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        reporter.announceBorrowStarted(for: book)
        XCTAssertFalse(book.identifier.isEmpty, "Book used for announcement must have a valid identifier")
    }

    func testAnnounceBorrowSucceeded_doesNotCrash() {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        reporter.announceBorrowSucceeded(for: book)
        XCTAssertNotNil(book.title, "Book title must be non-nil when borrow succeeds")
    }

    func testAnnounceBorrowFailed_doesNotCrash() {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        reporter.announceBorrowFailed(for: book)
        XCTAssertNotNil(reporter.downloadErrorPublisher, "Error publisher must be valid after borrow-failed announcement")
    }

    func testAnnounceReturnStarted_doesNotCrash() {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        reporter.announceReturnStarted(for: book)
        XCTAssertFalse(book.identifier.isEmpty, "Book identifier must be valid for return-started announcement")
    }

    func testAnnounceReturnSucceeded_doesNotCrash() {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        reporter.announceReturnSucceeded(for: book)
        XCTAssertNotNil(reporter.downloadProgressPublisher, "Publisher must be valid after return-succeeded announcement")
    }

    func testAnnounceReturnFailed_doesNotCrash() {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        reporter.announceReturnFailed(for: book)
        XCTAssertNotNil(reporter.downloadErrorPublisher, "Error publisher must be valid after return-failed announcement")
    }

    // MARK: - Notification Sender

    func testBroadcastUpdate_usesNotificationSender() {
        let sender = NSObject()
        reporter.notificationSender = sender

        var receivedSender: AnyObject?
        let notificationExpectation = expectation(
            forNotification: Notification.Name.TPPMyBooksDownloadCenterDidChange,
            object: sender,
            handler: { note in receivedSender = note.object as AnyObject; return true }
        )

        reporter.broadcastUpdate()

        wait(for: [notificationExpectation], timeout: 2.0)
        XCTAssertTrue(receivedSender === sender, "Notification must be posted with the configured sender object")
    }

    // MARK: - Protocol Conformance

    func testConformsToDownloadProgressPublishing() {
        let publishing: DownloadProgressPublishing = reporter
        XCTAssertNotNil(publishing.downloadProgressPublisher)
        XCTAssertNotNil(publishing.downloadErrorPublisher)
    }

    // MARK: - Active content-transfer registry
    //
    // Reconciliation reads this from a background queue to decide whether a
    // license-without-content book is stranded or still downloading. It must
    // answer WITHOUT waiting for the main-actor publish, or the reconciliation
    // pass that runs in between schedules a duplicate archive download.

    func testTransferRegistry_reflectsActiveImmediately_withoutAwaitingThePublish() {
        let reporter = DownloadProgressReporter()
        XCTAssertFalse(reporter.isLCPContentTransferActive(for: "book-1"), "precondition")

        reporter.sendLCPContentDownloadActive(bookIdentifier: "book-1", active: true)

        // Deliberately no main-queue drain: the point is that a reader running
        // before the published edge lands still sees the transfer.
        XCTAssertTrue(
            reporter.isLCPContentTransferActive(for: "book-1"),
            "the registry must update synchronously — reconciliation runs off the main actor and a stale read schedules a duplicate 1.8 GB download"
        )
    }

    func testTransferRegistry_clearsOnCompletion() {
        let reporter = DownloadProgressReporter()
        reporter.sendLCPContentDownloadActive(bookIdentifier: "book-1", active: true)
        reporter.sendLCPContentDownloadActive(bookIdentifier: "book-1", active: false)

        XCTAssertFalse(
            reporter.isLCPContentTransferActive(for: "book-1"),
            "a transfer left registered after it ends would suppress the recovery re-download the book depends on"
        )
    }

    func testTransferRegistry_isScopedPerBook() {
        let reporter = DownloadProgressReporter()
        reporter.sendLCPContentDownloadActive(bookIdentifier: "book-1", active: true)

        XCTAssertFalse(
            reporter.isLCPContentTransferActive(for: "book-2"),
            "one book's transfer must not suppress another book's recovery"
        )
    }

    // MARK: - Idle expiry and heartbeat
    //
    // The completion handler is NOT guaranteed to run: LicensesService swallows
    // NSURLErrorCancelled without calling it. The idle window is the backstop, and
    // it is IDLE rather than total duration because a 1.8 GB archive on a slow
    // connection legitimately outlives any total-duration cap.

    func testTransferRegistry_expiresATransferThatHasGoneQuiet() {
        let reporter = DownloadProgressReporter()
        var now: TimeInterval = 1_000
        reporter.monotonicClock = { now }

        reporter.sendLCPContentDownloadActive(bookIdentifier: "book-1", active: true)
        XCTAssertTrue(reporter.isLCPContentTransferActive(for: "book-1"), "precondition")

        now += DownloadProgressReporter.contentTransferIdleTimeout + 1

        XCTAssertFalse(
            reporter.isLCPContentTransferActive(for: "book-1"),
            "a cancelled fulfillment never reports completion — without idle expiry the book is pinned at .downloading forever"
        )
    }

    func testTransferRegistry_heartbeatKeepsALongDownloadAlive() {
        let reporter = DownloadProgressReporter()
        var now: TimeInterval = 1_000
        reporter.monotonicClock = { now }

        reporter.sendLCPContentDownloadActive(bookIdentifier: "book-1", active: true)

        // A long transfer that keeps reporting bytes, well past the idle window.
        for _ in 0..<5 {
            now += DownloadProgressReporter.contentTransferIdleTimeout - 1
            reporter.sendProgress(bookIdentifier: "book-1", progress: 0.5)
        }
        now += DownloadProgressReporter.contentTransferIdleTimeout - 1

        XCTAssertTrue(
            reporter.isLCPContentTransferActive(for: "book-1"),
            "the window is IDLE, not total duration — a slow 1.8 GB download that is still transferring must not be declared dead"
        )
    }

    func testTransferRegistry_progressForAnUnregisteredBookDoesNotRegisterIt() {
        let reporter = DownloadProgressReporter()
        reporter.sendProgress(bookIdentifier: "book-1", progress: 0.5)

        XCTAssertFalse(reporter.isLCPContentTransferActive(for: "book-1"),
                       "an ordinary download's progress must not masquerade as an LCP content transfer")
    }

    /// The cancel path calls this directly, because Readium never invokes the
    /// fulfillment completion handler for a cancelled transfer.
    func testClearTransfer_dropsTheRegistrationWithoutACompletion() {
        let reporter = DownloadProgressReporter()
        reporter.sendLCPContentDownloadActive(bookIdentifier: "book-1", active: true)

        reporter.clearLCPContentTransfer(for: "book-1")

        XCTAssertFalse(reporter.isLCPContentTransferActive(for: "book-1"),
                       "cancel must release the registration, or the book stays pinned behind a bar that never moves")
    }

    // MARK: - The UI edge on release
    //
    // `isDownloadingLCPContent` is driven ONLY by `lcpContentDownloadPublisher`,
    // and `HalfSheetProgressCue` reads that flag ahead of book state. Dropping a
    // registration without publishing therefore unsticks reconciliation while
    // leaving a determinate bar frozen on screen indefinitely.

    func testClearTransfer_publishesTheInactiveEdge() {
        let reporter = DownloadProgressReporter()
        var edges: [(String, Bool)] = []
        let sub = reporter.lcpContentDownloadPublisher.sink { edges.append(($0.0, $0.1)) }
        defer { sub.cancel() }

        reporter.sendLCPContentDownloadActive(bookIdentifier: "book-1", active: true)
        reporter.clearLCPContentTransfer(for: "book-1")

        let settled = expectation(description: "edges delivered")
        DispatchQueue.main.async { settled.fulfill() }
        wait(for: [settled], timeout: 5.0)

        XCTAssertEqual(edges.map(\.1), [true, false],
                       "a cancelled transfer must publish its own release, or the bar never clears")
    }

    func testIdleExpiry_publishesTheInactiveEdge() {
        let reporter = DownloadProgressReporter()
        var now: TimeInterval = 1_000
        reporter.monotonicClock = { now }
        var edges: [(String, Bool)] = []
        let sub = reporter.lcpContentDownloadPublisher.sink { edges.append(($0.0, $0.1)) }
        defer { sub.cancel() }

        reporter.sendLCPContentDownloadActive(bookIdentifier: "book-1", active: true)
        now += DownloadProgressReporter.contentTransferIdleTimeout + 1
        _ = reporter.isLCPContentTransferActive(for: "book-1")

        let settled = expectation(description: "edges delivered")
        DispatchQueue.main.async { settled.fulfill() }
        wait(for: [settled], timeout: 5.0)

        XCTAssertEqual(edges.map(\.1), [true, false],
                       "expiring a dead transfer must also release the UI, not just reconciliation")
    }

    /// A clear for a book that was never registered must stay silent, or an
    /// unrelated cancel emits a spurious edge that clears someone else's cue.
    func testClearTransfer_forAnUnregisteredBook_publishesNothing() {
        let reporter = DownloadProgressReporter()
        var edges: [(String, Bool)] = []
        let sub = reporter.lcpContentDownloadPublisher.sink { edges.append(($0.0, $0.1)) }
        defer { sub.cancel() }

        reporter.clearLCPContentTransfer(for: "never-registered")

        // Barrier with a REAL edge rather than a main-queue hop. The publish path
        // is `Task { @MainActor }`, which a `DispatchQueue.main.async` does not
        // order behind — so draining the main queue could return before a spurious
        // edge arrived, letting the `if wasRegistered` guard go inert. Sending a
        // known edge and waiting for it guarantees any earlier one has landed too.
        reporter.sendLCPContentDownloadActive(bookIdentifier: "sentinel", active: true)
        let sentinel = expectation(description: "sentinel edge delivered")
        var seenSentinel = false
        let watch = reporter.lcpContentDownloadPublisher.sink {
            if $0.0 == "sentinel" && !seenSentinel { seenSentinel = true; sentinel.fulfill() }
        }
        defer { watch.cancel(); reporter.clearLCPContentTransfer(for: "sentinel") }
        wait(for: [sentinel], timeout: 5.0)

        XCTAssertEqual(edges.filter { $0.0 == "never-registered" }.count, 0,
                       "no registration, no edge — an unrelated cancel must not clear another book's cue")
    }
}
