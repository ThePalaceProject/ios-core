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
        let notificationExpectation = expectation(
            forNotification: Notification.Name.TPPMyBooksDownloadCenterDidChange,
            object: nil
        )

        reporter.broadcastUpdate()

        wait(for: [notificationExpectation], timeout: 2.0)
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

        // Wait for throttle interval
        let waitExpectation = XCTestExpectation(description: "Wait for throttle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            waitExpectation.fulfill()
        }

        wait(for: [waitExpectation], timeout: 3.0)
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
    }

    func testAnnounceDownloadProgress_doesNotCrash() {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        reporter.announceDownloadProgress(for: book, progress: 0.5)
    }

    func testAnnounceDownloadCompleted_doesNotCrash() {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        reporter.announceDownloadCompleted(for: book)
    }

    func testAnnounceDownloadFailed_doesNotCrash() {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        reporter.announceDownloadFailed(for: book)
    }

    func testAnnounceBorrowStarted_doesNotCrash() {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        reporter.announceBorrowStarted(for: book)
    }

    func testAnnounceBorrowSucceeded_doesNotCrash() {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        reporter.announceBorrowSucceeded(for: book)
    }

    func testAnnounceBorrowFailed_doesNotCrash() {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        reporter.announceBorrowFailed(for: book)
    }

    func testAnnounceReturnStarted_doesNotCrash() {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        reporter.announceReturnStarted(for: book)
    }

    func testAnnounceReturnSucceeded_doesNotCrash() {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        reporter.announceReturnSucceeded(for: book)
    }

    func testAnnounceReturnFailed_doesNotCrash() {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        reporter.announceReturnFailed(for: book)
    }

    // MARK: - Notification Sender

    func testBroadcastUpdate_usesNotificationSender() {
        let sender = NSObject()
        reporter.notificationSender = sender

        let notificationExpectation = expectation(
            forNotification: Notification.Name.TPPMyBooksDownloadCenterDidChange,
            object: sender
        )

        reporter.broadcastUpdate()

        wait(for: [notificationExpectation], timeout: 2.0)
    }

    // MARK: - Protocol Conformance

    func testConformsToDownloadProgressPublishing() {
        let publishing: DownloadProgressPublishing = reporter
        XCTAssertNotNil(publishing.downloadProgressPublisher)
        XCTAssertNotNil(publishing.downloadErrorPublisher)
    }
}
