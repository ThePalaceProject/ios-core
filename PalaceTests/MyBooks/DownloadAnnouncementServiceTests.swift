//
//  DownloadAnnouncementServiceTests.swift
//  PalaceTests
//
//  Verifies that DownloadAnnouncementService bridges TPPBook → title (and
//  identifier where required) for every lifecycle event, and that Completed /
//  Failed are paired with `resetProgress` so the announcement state machine
//  can re-fire progress on the next download.
//

import XCTest
@testable import Palace
import PalaceBookModel

@MainActor
final class DownloadAnnouncementServiceTests: XCTestCase {

    private var announcer: SpyAnnouncer!
    private var service: DownloadAnnouncementService!
    private var book: TPPBook!

    override func setUp() {
        super.setUp()
        announcer = SpyAnnouncer()
        service = DownloadAnnouncementService(announcer: announcer)
        book = TPPBookMocker.mockBook(distributorType: .EpubZip)
    }

    override func tearDown() {
        announcer = nil
        service = nil
        book = nil
        super.tearDown()
    }

    // MARK: - Download Lifecycle

    func testAnnounceDownloadStarted_forwardsTitleAndIdentifier() {
        service.announceDownloadStarted(for: book)

        XCTAssertEqual(announcer.calls, [
            .downloadStarted(title: book.title, identifier: book.identifier)
        ])
    }

    func testAnnounceDownloadProgress_forwardsTitleIdentifierAndProgress() {
        service.announceDownloadProgress(for: book, progress: 0.42)

        XCTAssertEqual(announcer.calls, [
            .downloadProgress(title: book.title, identifier: book.identifier, progress: 0.42)
        ])
    }

    func testAnnounceDownloadCompleted_announcesAndResetsProgress() {
        service.announceDownloadCompleted(for: book)

        XCTAssertEqual(announcer.calls, [
            .downloadCompleted(title: book.title),
            .resetProgress(identifier: book.identifier)
        ], "Completion must always reset the per-identifier progress bucket so the next download for the same book can re-fire progress announcements.")
    }

    func testAnnounceDownloadFailed_announcesAndResetsProgress() {
        service.announceDownloadFailed(for: book)

        XCTAssertEqual(announcer.calls, [
            .downloadFailed(title: book.title),
            .resetProgress(identifier: book.identifier)
        ], "Failure must always reset the per-identifier progress bucket so a retry can re-fire progress announcements.")
    }

    func testCompletedAndFailed_orderingIsAnnounceThenReset() {
        // The announcer's deduplication looks at message text, not bucket state,
        // so the announce call has to land before the reset clears tracking —
        // otherwise an immediate retry's progress won't dedupe correctly.
        service.announceDownloadCompleted(for: book)
        service.announceDownloadFailed(for: book)

        guard announcer.calls.count == 4 else {
            XCTFail("Expected 4 calls, got \(announcer.calls.count): \(announcer.calls)")
            return
        }
        XCTAssertEqual(announcer.calls[0], .downloadCompleted(title: book.title))
        XCTAssertEqual(announcer.calls[1], .resetProgress(identifier: book.identifier))
        XCTAssertEqual(announcer.calls[2], .downloadFailed(title: book.title))
        XCTAssertEqual(announcer.calls[3], .resetProgress(identifier: book.identifier))
    }

    // MARK: - Borrow

    func testAnnounceBorrowStarted_forwardsTitle() {
        service.announceBorrowStarted(for: book)
        XCTAssertEqual(announcer.calls, [.borrowStarted(title: book.title)])
    }

    func testAnnounceBorrowSucceeded_forwardsTitle() {
        service.announceBorrowSucceeded(for: book)
        XCTAssertEqual(announcer.calls, [.borrowSucceeded(title: book.title)])
    }

    func testAnnounceBorrowFailed_forwardsTitle() {
        service.announceBorrowFailed(for: book)
        XCTAssertEqual(announcer.calls, [.borrowFailed(title: book.title)])
    }

    // MARK: - Return

    func testAnnounceReturnStarted_forwardsTitle() {
        service.announceReturnStarted(for: book)
        XCTAssertEqual(announcer.calls, [.returnStarted(title: book.title)])
    }

    func testAnnounceReturnSucceeded_forwardsTitle() {
        service.announceReturnSucceeded(for: book)
        XCTAssertEqual(announcer.calls, [.returnSucceeded(title: book.title)])
    }

    func testAnnounceReturnFailed_forwardsTitle() {
        service.announceReturnFailed(for: book)
        XCTAssertEqual(announcer.calls, [.returnFailed(title: book.title)])
    }

    // MARK: - Identifier propagation across mixed traffic

    func testIdentifierPropagation_distinctBooksAreNotAliased() {
        let dune = TPPBookMocker.mockBook(identifier: "dune-id", title: "Dune", distributorType: .EpubZip)
        let foundation = TPPBookMocker.mockBook(identifier: "foundation-id", title: "Foundation", distributorType: .EpubZip)

        service.announceDownloadStarted(for: dune)
        service.announceDownloadProgress(for: foundation, progress: 0.5)
        service.announceDownloadCompleted(for: dune)

        XCTAssertEqual(announcer.calls, [
            .downloadStarted(title: "Dune", identifier: "dune-id"),
            .downloadProgress(title: "Foundation", identifier: "foundation-id", progress: 0.5),
            .downloadCompleted(title: "Dune"),
            .resetProgress(identifier: "dune-id")
        ], "resetProgress must use the book that was completed, never the most-recent identifier seen.")
    }

}

// MARK: - Spy

private final class SpyAnnouncer: DownloadLifecycleAnnouncing {

    enum Call: Equatable {
        case downloadStarted(title: String, identifier: String?)
        case downloadProgress(title: String, identifier: String, progress: Double)
        case downloadCompleted(title: String)
        case downloadFailed(title: String)
        case borrowStarted(title: String)
        case borrowSucceeded(title: String)
        case borrowFailed(title: String)
        case returnStarted(title: String)
        case returnSucceeded(title: String)
        case returnFailed(title: String)
        case resetProgress(identifier: String)
    }

    private(set) var calls: [Call] = []

    func announceDownloadStarted(title: String, identifier: String?) {
        calls.append(.downloadStarted(title: title, identifier: identifier))
    }

    func announceDownloadProgress(title: String, identifier: String, progress: Double) {
        calls.append(.downloadProgress(title: title, identifier: identifier, progress: progress))
    }

    func announceDownloadCompleted(title: String) {
        calls.append(.downloadCompleted(title: title))
    }

    func announceDownloadFailed(title: String) {
        calls.append(.downloadFailed(title: title))
    }

    func announceBorrowStarted(title: String) {
        calls.append(.borrowStarted(title: title))
    }

    func announceBorrowSucceeded(title: String) {
        calls.append(.borrowSucceeded(title: title))
    }

    func announceBorrowFailed(title: String) {
        calls.append(.borrowFailed(title: title))
    }

    func announceReturnStarted(title: String) {
        calls.append(.returnStarted(title: title))
    }

    func announceReturnSucceeded(title: String) {
        calls.append(.returnSucceeded(title: title))
    }

    func announceReturnFailed(title: String) {
        calls.append(.returnFailed(title: title))
    }

    func resetProgress(identifier: String) {
        calls.append(.resetProgress(identifier: identifier))
    }
}
