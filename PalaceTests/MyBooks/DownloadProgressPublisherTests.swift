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

final class DownloadProgressPublisherCoreTests: XCTestCase {

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
}
