//
//  LCPFulfillmentHandlerTests.swift
//  PalaceTests
//
//  Coverage for the LCP-specific fulfillment paths in
//  LCPFulfillmentHandler. The class is gated `#if LCP` (it depends on
//  ReadiumLCP types) so the test class shares the same gate.
//
//  Branches covered (failure paths only — the TPPLCPLicense(url:) read
//  on the success path requires a valid Readium-encoded license JSON
//  file which is too heavy to fixture in a unit test):
//    - License rename succeeds → fulfill is invoked with the renamed
//      license URL.
//    - fulfill completion fires with an error → alertPresenter publishes
//      a "Fulfilment Error" message.
//    - fulfill completion fires with localUrl=nil → alertPresenter
//      publishes the "no local URL" error.
//    - Audiobook path: the unconditional copyLicenseForStreaming +
//      markDownloadSuccessful side effects fire even before the
//      fulfillment task completes.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

#if LCP

import XCTest
import Combine
import PalaceCatalog
@testable import Palace

@MainActor
final class LCPFulfillmentHandlerTests: XCTestCase {

    private var tempDir: URL!
    private var registry: TPPBookRegistryMock!
    private var stateManager: DownloadStateManager!
    private var reporter: DownloadProgressReporter!
    private var alertPresenter: DownloadAlertPresenter!
    private var bookFileManager: BookFileManager!
    private var backgroundHandler: BackgroundDownloadHandler!
    private var lcpService: SpyLCPLibraryService!
    private var spyDelegate: SpyDelegate!
    private var handler: LCPFulfillmentHandler!
    private var capturedErrors: [DownloadErrorInfo] = []
    private var subscription: AnyCancellable?

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LCPFulfillmentHandlerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        registry = TPPBookRegistryMock()
        stateManager = DownloadStateManager()
        reporter = DownloadProgressReporter(
            accessibilityAnnouncements: TPPAccessibilityAnnouncementCenter(),
            downloadAnnouncementService: DownloadAnnouncementService()
        )
        alertPresenter = DownloadAlertPresenter(
            bookRegistry: registry,
            stateManager: stateManager,
            progressReporter: reporter,
            downloadAnnouncementService: DownloadAnnouncementService()
        )
        bookFileManager = BookFileManager(bookRegistry: registry)
        backgroundHandler = BackgroundDownloadHandler()
        lcpService = SpyLCPLibraryService()
        spyDelegate = SpyDelegate()

        capturedErrors = []
        subscription = reporter.downloadErrorPublisher.sink { [weak self] info in
            self?.capturedErrors.append(info)
        }

        handler = LCPFulfillmentHandler(
            bookRegistry: registry,
            stateManager: stateManager,
            progressReporter: reporter,
            alertPresenter: alertPresenter,
            bookFileManager: bookFileManager,
            backgroundDownloadHandler: backgroundHandler,
            fileManager: .default,
            lcpServiceFactory: { [unowned self] in self.lcpService }
        )
        handler.delegate = spyDelegate
    }

    override func tearDownWithError() throws {
        subscription?.cancel()
        subscription = nil
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        registry = nil
        stateManager = nil
        reporter = nil
        alertPresenter = nil
        bookFileManager = nil
        backgroundHandler = nil
        lcpService = nil
        spyDelegate = nil
        handler = nil
        capturedErrors = []
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    /// Writes a temp source file the handler will rename to .lcpl.
    @discardableResult
    private func writeSourceFile(name: String = "src", ext: String = "epub") throws -> URL {
        let url = tempDir.appendingPathComponent(name).appendingPathExtension(ext)
        try Data(repeating: 0xCD, count: 50).write(to: url)
        return url
    }

    private func waitForPublishedError(timeout: TimeInterval = 1.0) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !capturedErrors.isEmpty { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
            await Task.yield()
        }
    }

    // MARK: - License rename + fulfill invocation

    func testFulfill_invokesLCPServiceWithRenamedLicenseURL() async throws {
        let book = TPPBookMocker.mockBook(distributorType: .ReadiumLCP)
        let sourceURL = try writeSourceFile()
        let downloadTask = FakeDownloadTask(state: .completed, identifier: 1)

        handler.fulfillLCPLicense(fileUrl: sourceURL, forBook: book, downloadTask: downloadTask)

        XCTAssertEqual(lcpService.fulfillCallCount, 1, "Service must be invoked exactly once")
        let licenseURL = try XCTUnwrap(lcpService.lastFileURL)
        XCTAssertEqual(licenseURL.pathExtension, "lcpl",
                       "Source file is renamed to .lcpl before fulfill")
        XCTAssertTrue(FileManager.default.fileExists(atPath: licenseURL.path),
                      "Renamed license file exists on disk")
    }

    // MARK: - Fulfill completion error → alert

    func testFulfill_completionWithError_publishesFulfilmentErrorAlert() async throws {
        let book = TPPBookMocker.mockBook(distributorType: .ReadiumLCP)
        let sourceURL = try writeSourceFile()
        let downloadTask = FakeDownloadTask(state: .completed, identifier: 1)

        handler.fulfillLCPLicense(fileUrl: sourceURL, forBook: book, downloadTask: downloadTask)

        let completion = try XCTUnwrap(lcpService.lastCompletion)
        let error = NSError(domain: "test", code: 99,
                            userInfo: [NSLocalizedDescriptionKey: "license expired"])
        completion(nil, error)
        await waitForPublishedError()

        let info = try XCTUnwrap(capturedErrors.first)
        XCTAssertTrue(info.message.contains("Fulfilment Error"),
                      "License-fulfillment errors are surfaced with the 'Fulfilment Error' prefix")
        XCTAssertTrue(info.message.contains("license expired"),
                      "Underlying error description is included in the alert message")
    }

    // MARK: - Fulfill completion no localUrl → alert

    func testFulfill_completionWithoutLocalURL_publishesNoLocalURLAlert() async throws {
        let book = TPPBookMocker.mockBook(distributorType: .ReadiumLCP)
        let sourceURL = try writeSourceFile()
        let downloadTask = FakeDownloadTask(state: .completed, identifier: 1)

        handler.fulfillLCPLicense(fileUrl: sourceURL, forBook: book, downloadTask: downloadTask)

        let completion = try XCTUnwrap(lcpService.lastCompletion)
        // No error AND no local URL → handler bails through the
        // TPPLCPLicense guard and surfaces the no-local-URL error.
        completion(nil, nil)
        await waitForPublishedError()

        let info = try XCTUnwrap(capturedErrors.first)
        XCTAssertTrue(info.message.contains("Error with LCP license fulfillment"),
                      "Missing local URL surfaces the documented error message")
    }

    // MARK: - Audiobook unconditional path

    func testFulfill_audiobook_marksDownloadSuccessfulEvenBeforeCompletion() async throws {
        let audiobook = TPPBookMocker.mockBook(distributorType: .AudiobookLCP)
        let sourceURL = try writeSourceFile(ext: "lcpa")
        let downloadTask = FakeDownloadTask(state: .completed, identifier: 1)

        handler.fulfillLCPLicense(fileUrl: sourceURL, forBook: audiobook, downloadTask: downloadTask)

        // The audiobook path runs the markDownloadSuccessful + streaming-
        // license-copy side effects unconditionally — they don't wait for
        // the fulfillment task to finish, so the user can stream
        // immediately.
        XCTAssertEqual(spyDelegate.markSuccessfulCalls, [audiobook.identifier],
                       "Audiobook books mark .downloadSuccessful immediately so streaming works")
    }

    // MARK: - Fulfillment task tracking

    func testFulfill_storesReturnedDownloadTaskInStateManager() async throws {
        let book = TPPBookMocker.mockBook(distributorType: .ReadiumLCP)
        let sourceURL = try writeSourceFile()
        let downloadTask = FakeDownloadTask(state: .completed, identifier: 7)
        let fulfillmentTask = FakeDownloadTask(state: .running, identifier: 999)
        lcpService.taskToReturn = fulfillmentTask

        handler.fulfillLCPLicense(fileUrl: sourceURL, forBook: book, downloadTask: downloadTask)

        // The Task hop inside the handler is fire-and-forget; allow it to
        // resolve before asserting.
        for _ in 0..<5 {
            try? await Task.sleep(nanoseconds: 30_000_000)
            await Task.yield()
            if await stateManager.bookIdentifierToDownloadInfo.get(book.identifier) != nil { break }
        }

        let stored = await stateManager.bookIdentifierToDownloadInfo.get(book.identifier)
        XCTAssertNotNil(stored,
                       "Returned fulfillment download task is parked in stateManager so progress + cancel hooks can route to it")
    }
}

// MARK: - Test fakes

/// SubclassesLCPLibraryService and overrides @objc fulfill so tests can
/// drive the progress + completion closures explicitly without standing
/// up Readium / SQLite repositories.
private final class SpyLCPLibraryService: LCPLibraryService {
    var fulfillCallCount = 0
    var lastFileURL: URL?
    var lastProgress: ((Double) -> Void)?
    var lastCompletion: ((URL?, NSError?) -> Void)?
    var taskToReturn: URLSessionDownloadTask?

    override func fulfill(_ file: URL,
                          progress: @escaping (_ progress: Double) -> Void,
                          completion: @escaping (_ localUrl: URL?, _ error: NSError?) -> Void) -> URLSessionDownloadTask? {
        fulfillCallCount += 1
        lastFileURL = file
        lastProgress = progress
        lastCompletion = completion
        return taskToReturn
    }
}

private final class FakeDownloadTask: URLSessionDownloadTask {
    private let _state: URLSessionTask.State
    private let _taskIdentifier: Int

    init(state: URLSessionTask.State, identifier: Int) {
        self._state = state
        self._taskIdentifier = identifier
        super.init()
    }

    override var state: URLSessionTask.State { _state }
    override var taskIdentifier: Int { _taskIdentifier }
    override func cancel() {}
    override func resume() {}
    override func suspend() {}
}

private final class SpyDelegate: LCPFulfillmentHandlerDelegate {
    var markSuccessfulCalls: [String] = []

    func markDownloadSuccessful(for book: TPPBook) {
        markSuccessfulCalls.append(book.identifier)
    }
}

#endif
