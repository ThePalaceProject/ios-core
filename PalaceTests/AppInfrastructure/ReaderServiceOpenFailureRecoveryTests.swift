//
//  ReaderServiceOpenFailureRecoveryTests.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import Combine
import PalaceBookModel
import PalaceCatalog
@testable import Palace
#if LCP
import ReadiumLCP
#endif

/// Records what the failure handler did. Main-actor isolated so the
/// service's `@MainActor` closures can capture it.
@MainActor
private final class OpenFailureSpy {
    var connected = true
    var alerts: [(title: String, message: String?)] = []
    var redownloads: [String] = []
}

/// Records the delete and download the re-download recovery asks for. Every
/// other member fails the test, since the recovery must not reach it.
private final class RedownloadDownloadCenterSpy: MyBooksDownloadCenterProviding {
    var deleted: [String] = []
    var started: [String] = []

    var downloadProgressPublisher = PassthroughSubject<(String, Double), Never>()
    var downloadErrorPublisher = PassthroughSubject<DownloadErrorInfo, Never>()

    func startBorrow(for book: TPPBook, attemptDownload: Bool, borrowCompletion: (() -> Void)?) {
        XCTFail("The re-download must not borrow")
    }
    func startDownload(for book: TPPBook, withRequest initedRequest: URLRequest?) {
        started.append(book.identifier)
    }
    func cancelDownload(for identifier: String) {
        XCTFail("The re-download must not cancel a download")
    }
    func deleteLocalContent(for identifier: String, account: String?) {
        deleted.append(identifier)
    }
    func returnBook(withIdentifier identifier: String, completion: (@Sendable () -> Void)?) {
        XCTFail("The re-download must not return the book")
    }
    func downloadInfo(forBookIdentifier bookIdentifier: String) -> MyBooksDownloadInfo? { nil }
    func downloadInfoAsync(forBookIdentifier bookIdentifier: String) async -> MyBooksDownloadInfo? { nil }
    func fileUrl(for identifier: String) -> URL? { nil }
    func fileUrl(for identifier: String, account: String?) -> URL? { nil }
    func reset() {}
}

/// PP-5431 — what a failed book open does next. The first failure deletes the
/// local copy and re-downloads it, which needs the network; offline it must
/// leave the copy and its state alone and say a connection is needed.
@MainActor
final class ReaderServiceOpenFailureRecoveryTests: XCTestCase {

    private var spy: OpenFailureSpy!
    private var service: ReaderService!
    private let book = TPPBookMocker.snapshotEPUB()
    private let openError = LibraryServiceError.openFailed(
        NSError(domain: "Adobe DRM decoding error", code: 1001)
    )

    override func setUp() {
        super.setUp()
        let spy = OpenFailureSpy()
        self.spy = spy
        service = ReaderService(
            rootViewController: { nil },
            isConnected: { spy.connected },
            presentAlert: { title, message in spy.alerts.append((title, message)) },
            redownloadAndReopen: { book, _ in spy.redownloads.append(book.identifier) },
            imageCache: { MockImageCache() }
        )
    }

    override func tearDown() {
        service = nil
        spy = nil
        super.tearDown()
    }

    // MARK: - Decision table

    /// Every (retry, definitive license error, connected) cell, so a change to
    /// one branch cannot move another without a failing cell.
    func testOpenFailureRecovery_EveryCombination() {
        typealias R = ReaderService.OpenFailureRecovery
        let cases: [(isRetry: Bool, definitive: Bool, connected: Bool, expected: R)] = [
            (false, false, true, .redownload),
            (false, false, false, .requireConnection),
            (false, true, true, .showError),
            (false, true, false, .showError),
            (true, false, true, .showError),
            (true, false, false, .showError),
            (true, true, true, .showError),
            (true, true, false, .showError),
        ]
        for c in cases {
            XCTAssertEqual(
                ReaderService.openFailureRecovery(
                    isRetry: c.isRetry,
                    isDefinitiveLicenseError: c.definitive,
                    isConnected: c.connected
                ),
                c.expected,
                "isRetry=\(c.isRetry) definitive=\(c.definitive) connected=\(c.connected)"
            )
        }
    }

    // MARK: - The failure handler

    /// Offline on the first failure: no delete-and-re-download, and the patron
    /// is told to reconnect instead of seeing a Content Protection Error.
    func testFirstOpenFailure_WhenOffline_AsksForConnectionAndDoesNotRedownload() {
        spy.connected = false

        service.presentOpenFailureAlert(for: openError, book: book, isRetry: false)

        XCTAssertTrue(spy.redownloads.isEmpty, "Offline must not delete the local copy and start a download")
        XCTAssertEqual(spy.alerts.map(\.title), [Strings.MyDownloadCenter.noConnectionTitle])
        XCTAssertEqual(spy.alerts.first?.message, Strings.MyDownloadCenter.noConnectionMessage)
    }

    /// Online on the first failure: the transparent re-download runs and no
    /// alert is shown yet.
    func testFirstOpenFailure_WhenOnline_RedownloadsWithoutAlert() {
        spy.connected = true

        service.presentOpenFailureAlert(for: openError, book: book, isRetry: false)

        XCTAssertEqual(spy.redownloads, [book.identifier])
        XCTAssertTrue(spy.alerts.isEmpty)
    }

    /// A failure after the re-download is final: the Content Protection Error is
    /// shown and no second download starts.
    func testRetryOpenFailure_ShowsContentProtectionErrorWithoutRedownload() {
        spy.connected = true

        service.presentOpenFailureAlert(for: openError, book: book, isRetry: true)

        XCTAssertTrue(spy.redownloads.isEmpty)
        XCTAssertEqual(spy.alerts.map(\.title), ["Content Protection Error"])
    }

    #if LCP
    /// An expired, returned or revoked LCP license cannot be fixed by
    /// downloading again, so it shows the Content Protection Error even
    /// offline, and nothing is re-downloaded.
    func testDefinitiveLicenseError_WhenOffline_ShowsContentProtectionError() {
        spy.connected = false
        let expired = LibraryServiceError.openFailed(
            LCPError.licenseStatus(.expired(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 1)))
        )

        service.presentOpenFailureAlert(for: expired, book: book, isRetry: false)

        XCTAssertTrue(spy.redownloads.isEmpty)
        XCTAssertEqual(spy.alerts.map(\.title), ["Content Protection Error"])
    }
    #endif
}

/// PP-5494 — after the delete and re-download, the book reopens in the reader
/// it failed in. An LCP PDF reopened through the EPUB path does not open.
@MainActor
final class ReaderServiceRedownloadReopenTests: XCTestCase {

    private var spy: OpenFailureSpy!
    private var downloadCenter: RedownloadDownloadCenterSpy!
    private var registry: TPPBookRegistryMock!
    private var reopened: [(id: String, reader: String, isRetry: Bool)] = []
    private var service: ReaderService!
    private let openError = LibraryServiceError.openFailed(
        NSError(domain: "Readium LCP open error", code: 1)
    )

    override func setUp() {
        super.setUp()
        let spy = OpenFailureSpy()
        let downloadCenter = RedownloadDownloadCenterSpy()
        let registry = TPPBookRegistryMock()
        self.spy = spy
        self.downloadCenter = downloadCenter
        self.registry = registry
        reopened = []
        service = ReaderService(
            rootViewController: { nil },
            isConnected: { true },
            presentAlert: { title, message in spy.alerts.append((title, message)) },
            downloadCenter: { downloadCenter },
            bookRegistry: { registry },
            reopenEPUB: { [weak self] book, isRetry in
                self?.reopened.append((book.identifier, "epub", isRetry))
            },
            reopenLCPPDF: { [weak self] book, isRetry in
                self?.reopened.append((book.identifier, "lcpPDF", isRetry))
            },
            imageCache: { MockImageCache() }
        )
    }

    override func tearDown() {
        service = nil
        registry = nil
        downloadCenter = nil
        spy = nil
        reopened = []
        super.tearDown()
    }

    /// An LCP-license-wrapped PDF, the shape that reaches the LCP PDF open.
    private func makeLCPPDF() -> TPPBook {
        let pdf = TPPOPDSIndirectAcquisition(type: "application/pdf", indirectAcquisitions: [])
        let license = TPPOPDSAcquisition(
            relation: .generic,
            type: "application/vnd.readium.lcp.license.v1.0+json",
            hrefURL: URL(string: "https://library.test/book.lcpl")!,
            indirectAcquisitions: [pdf],
            availability: TPPOPDSAcquisitionAvailabilityUnlimited()
        )
        return TPPBook(
            acquisitions: [license],
            authors: [],
            categoryStrings: [],
            distributor: "Test",
            identifier: "lcp-pdf-redownload",
            imageURL: nil,
            imageThumbnailURL: nil,
            published: Date(),
            publisher: "Test",
            subtitle: nil,
            summary: nil,
            title: "LCP PDF",
            updated: Date(),
            annotationsURL: nil,
            analyticsURL: nil,
            alternateURL: nil,
            relatedWorksURL: nil,
            previewLink: nil,
            seriesURL: nil,
            revokeURL: nil,
            reportURL: nil,
            timeTrackingURL: nil,
            contributors: [:],
            bookDuration: nil,
            imageCache: MockImageCache()
        )
    }

    /// The first LCP PDF open fails, the copy is deleted and downloaded again,
    /// and the finished download reopens it in the PDF reader.
    func testRedownloadOfLCPPDF_WhenDownloadSucceeds_ReopensInPDFReader() {
        let book = makeLCPPDF()
        XCTAssertEqual(book.defaultBookContentType, .pdf, "Pre-condition: the fixture is a PDF")

        service.presentOpenFailureAlert(for: openError, book: book, isRetry: false)
        XCTAssertEqual(downloadCenter.deleted, [book.identifier])
        XCTAssertEqual(downloadCenter.started, [book.identifier])

        registry.setState(.downloadSuccessful, for: book.identifier)

        XCTAssertEqual(reopened.map(\.id), [book.identifier])
        XCTAssertEqual(reopened.map(\.reader), ["lcpPDF"])
        XCTAssertEqual(reopened.map(\.isRetry), [true], "A failure after the re-download must not download again")
        XCTAssertTrue(spy.alerts.isEmpty)
    }

    /// An EPUB keeps reopening in the EPUB reader after its re-download.
    func testRedownloadOfEPUB_WhenDownloadSucceeds_ReopensInEPUBReader() {
        let book = TPPBookMocker.snapshotEPUB()

        service.presentOpenFailureAlert(for: openError, book: book, isRetry: false)
        registry.setState(.downloadSuccessful, for: book.identifier)

        XCTAssertEqual(reopened.map(\.id), [book.identifier])
        XCTAssertEqual(reopened.map(\.reader), ["epub"])
        XCTAssertEqual(reopened.map(\.isRetry), [true], "A failure after the re-download must not download again")
    }

    /// The re-download resets the book to download-needed, so the registry
    /// does not show an opened copy that was just deleted.
    func testRedownload_ResetsBookToDownloadNeeded() {
        let book = makeLCPPDF()
        var states: [TPPBookState] = []
        let observation = registry.bookStatePublisher
            .filter { $0.0 == book.identifier }
            .sink { states.append($0.1) }

        service.presentOpenFailureAlert(for: openError, book: book, isRetry: false)

        XCTAssertEqual(states, [.downloadNeeded])
        observation.cancel()
    }

    /// A failed re-download shows the Content Protection Error and does not
    /// reopen the book.
    func testRedownloadOfLCPPDF_WhenDownloadFails_ShowsContentProtectionErrorWithoutReopen() {
        let book = makeLCPPDF()

        service.presentOpenFailureAlert(for: openError, book: book, isRetry: false)
        registry.setState(.downloadFailed, for: book.identifier)

        XCTAssertTrue(reopened.isEmpty)
        XCTAssertEqual(spy.alerts.map(\.title), ["Content Protection Error"])
    }

    /// Another book's finished download does not reopen this one, and a later
    /// state change for this book does not reopen it a second time.
    func testRedownload_ReopensOnceAndOnlyForItsOwnBook() {
        let book = makeLCPPDF()

        service.presentOpenFailureAlert(for: openError, book: book, isRetry: false)
        registry.setState(.downloadSuccessful, for: "some-other-book")
        XCTAssertTrue(reopened.isEmpty, "Another book's download must not reopen this one")

        registry.setState(.downloadSuccessful, for: book.identifier)
        registry.setState(.downloadSuccessful, for: book.identifier)

        XCTAssertEqual(reopened.map(\.id), [book.identifier])
    }
}
