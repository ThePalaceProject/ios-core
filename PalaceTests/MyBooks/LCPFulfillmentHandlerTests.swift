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

    /// Wraps the shared `awaitConditionAsync` helper. `file`/`line`
    /// forwarded so timeout XCTFail blames the call site.
    private func waitForPublishedError(
        timeout: TimeInterval = 10.0,
        file: StaticString = #file,
        line: UInt = #line
    ) async {
        await awaitConditionAsync(timeout: timeout, file: file, line: line) { [weak self] in
            self?.capturedErrors.isEmpty == false
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

    // MARK: - LCP audiobook phase-2 download failure must not downgrade

    /// Regression of PP-4114-adjacent iPad bug.
    ///
    /// LCP audiobooks have a two-phase download: the .lcpl license file
    /// completes first and the book is immediately marked `.downloadSuccessful`
    /// (playable via streaming). The LCP toolkit then runs a SECONDARY
    /// background download for the .lcpa content file from googleapis.com
    /// so offline playback also works.
    ///
    /// If that secondary download fails — for example, the user toggles
    /// airplane mode mid-fetch — `lcpCompletion` was previously firing
    /// `failDownloadWithAlert`, which flipped the audiobook from
    /// `.downloadSuccessful` back to `.downloadFailed`. The user reported
    /// this on iPad: previously-downloaded audiobooks lost the Read/Listen
    /// affordance and showed "The download could not be completed." the
    /// moment they went offline.
    ///
    /// Fix: when the book is an audiobook AND already at
    /// `.downloadSuccessful` (license is in place, streaming is viable),
    /// the secondary-fetch error is logged but does NOT publish a failure
    /// alert or mutate the registry state. Offline playback isn't
    /// available until they retry, but the book stays readable.
    func testFulfill_audiobook_secondaryDownloadError_doesNotFlipStreamingReadyBook() async throws {
        let audiobook = TPPBookMocker.mockBook(distributorType: .AudiobookLCP)
        let sourceURL = try writeSourceFile(ext: "lcpa")
        let downloadTask = FakeDownloadTask(state: .completed, identifier: 1)

        handler.fulfillLCPLicense(fileUrl: sourceURL, forBook: audiobook, downloadTask: downloadTask)

        // Mirror production: the audiobook path's synchronous
        // markDownloadSuccessful runs immediately. We assert the spy saw
        // it (sanity), then stage the registry state production would be
        // in when the phase-2 error fires.
        XCTAssertEqual(spyDelegate.markSuccessfulCalls, [audiobook.identifier],
                       "precondition: audiobook is marked .downloadSuccessful at license-fulfilled time")
        registry.addBook(audiobook, state: .downloadSuccessful)

        // Fire the secondary-fetch failure (airplane mode in production).
        let completion = try XCTUnwrap(lcpService.lastCompletion)
        let networkLost = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorNetworkConnectionLost,
            userInfo: [NSLocalizedDescriptionKey: "The network connection was lost."]
        )
        completion(nil, networkLost)

        // Give the async error handler time to run; without the guard it
        // calls failDownloadWithAlert synchronously off the completion.
        try? await Task.sleep(nanoseconds: 250_000_000)
        await Task.yield()

        XCTAssertEqual(registry.state(for: audiobook.identifier), .downloadSuccessful,
                       "LCP audiobook with streaming-ready license must NOT flip to .downloadFailed when the phase-2 content download fails")
        XCTAssertTrue(capturedErrors.isEmpty,
                      "No user-facing 'Fulfilment Error' alert should publish for an audiobook that's still streaming-playable")
    }

    /// Sibling check: a non-audiobook (e.g. LCP EPUB) does NOT get the
    /// pass — its content file is essential, and a phase-2 failure means
    /// the book can't be opened. The existing alert path must remain.
    func testFulfill_epub_secondaryDownloadError_stillSurfacesAlert() async throws {
        let book = TPPBookMocker.mockBook(distributorType: .ReadiumLCP)
        let sourceURL = try writeSourceFile()
        let downloadTask = FakeDownloadTask(state: .completed, identifier: 1)

        handler.fulfillLCPLicense(fileUrl: sourceURL, forBook: book, downloadTask: downloadTask)
        // Even if an EPUB were somehow at .downloadSuccessful (it isn't
        // until the secondary completes), the alert must still fire — the
        // user can't read it without the content file.
        registry.addBook(book, state: .downloadSuccessful)

        let completion = try XCTUnwrap(lcpService.lastCompletion)
        completion(nil, NSError(domain: NSURLErrorDomain,
                                code: NSURLErrorNetworkConnectionLost,
                                userInfo: [NSLocalizedDescriptionKey: "lost"]))
        await waitForPublishedError()

        XCTAssertFalse(capturedErrors.isEmpty,
                       "EPUB/PDF LCP books still need the alert — no content file = no read")
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
