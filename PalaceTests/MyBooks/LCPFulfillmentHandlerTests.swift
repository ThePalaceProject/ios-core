//
//  LCPFulfillmentHandlerTests.swift
//  PalaceTests
//
//  Coverage for the LCP-specific fulfillment paths in
//  LCPFulfillmentHandler. The class is gated `#if LCP` (it depends on
//  ReadiumLCP types) so the test class shares the same gate.
//
//  Branches covered:
//    - License rename succeeds → fulfill is invoked with the renamed
//      license URL.
//    - fulfill completion fires with an error → alertPresenter publishes
//      a "Fulfilment Error" message.
//    - fulfill completion fires with localUrl=nil → alertPresenter
//      publishes the "no local URL" error.
//    - Audiobook path: the license landing does NOT mark the book
//      successful; the content landing does. The header previously said
//      the opposite, and separately claimed the success path was too
//      heavy to fixture — it is not: a minimal `{"id":…,"links":[]}`
//      parses, and `replaceBook` only needs a delegate that resolves a
//      destination plus a non-empty file.
//    - Content-fetch failure does not downgrade a book whose content is
//      already on disk. That guard tests the FILE, not registry state, so
//      these fixtures write real content rather than staging a registry
//      state production forbids as an entry condition.
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
        // Resolve book files inside the per-test temp dir so the disk state the
        // handler inspects is controllable. The content-failure guard tests the
        // FILE, not the registry state, so a test that wants "this book already
        // has local content" has to be able to create that content.
        bookFileManager = BookFileManager(
            bookRegistry: registry,
            directoryProvider: { [tempDir] _ in tempDir }
        )
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
            lcpServiceFactory: { [unowned self] in self.lcpService },
            // PP-4957: the download-first tests in this suite assert the flag-OFF
            // path; pin the streaming flag OFF so they don't read the shared flag
            // (non-deterministic in the test host). The streaming tests build their
            // own handler via makeStreamingHandler() with the provider forced ON.
            streamingEnabledProvider: { false }
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

    // MARK: - Content-transfer registration
    //
    // The `.lcpa` transfer runs on Readium's own URLSession and is never in
    // `downloadInfo`, which is additionally cleared ~100 ms after fulfillment
    // begins. This registration is therefore the ONLY thing telling registry
    // reconciliation that a license-without-content book is downloading rather
    // than stranded. Without it, a device trace showed reconciliation firing three
    // times in eight seconds and scheduling a re-download that fetched a second
    // full 1.8 GB copy of the archive.

    func testFulfill_registersTheContentTransfer_beforeStartingIt() throws {
        let book = TPPBookMocker.mockBook(distributorType: .AudiobookLCP)
        let sourceURL = try writeSourceFile()
        let downloadTask = FakeDownloadTask(state: .running, identifier: 7)

        XCTAssertFalse(reporter.isLCPContentTransferActive(for: book.identifier), "precondition")

        handler.fulfillLCPLicense(fileUrl: sourceURL, forBook: book, downloadTask: downloadTask)

        XCTAssertTrue(
            reporter.isLCPContentTransferActive(for: book.identifier),
            "reconciliation must be able to see this transfer, or it schedules a duplicate download of the whole archive"
        )
    }

    /// Not audiobook-only: an LCP EPUB mid-fulfillment also resolves to `.absent`,
    /// so an unregistered transfer lets a warm `load()` call a healthy download failed.
    func testFulfill_registersTheContentTransfer_forEpubsToo() throws {
        let book = TPPBookMocker.mockBook(distributorType: .ReadiumLCP)
        let sourceURL = try writeSourceFile()
        let downloadTask = FakeDownloadTask(state: .running, identifier: 8)

        handler.fulfillLCPLicense(fileUrl: sourceURL, forBook: book, downloadTask: downloadTask)

        XCTAssertTrue(reporter.isLCPContentTransferActive(for: book.identifier),
                      "an LCP EPUB transfer must be registered too")
    }

    func testFulfill_completion_clearsTheContentTransfer() throws {
        let book = TPPBookMocker.mockBook(distributorType: .AudiobookLCP)
        let sourceURL = try writeSourceFile()
        let downloadTask = FakeDownloadTask(state: .running, identifier: 9)

        handler.fulfillLCPLicense(fileUrl: sourceURL, forBook: book, downloadTask: downloadTask)
        XCTAssertTrue(reporter.isLCPContentTransferActive(for: book.identifier), "precondition")

        let completion = try XCTUnwrap(lcpService.lastCompletion)
        completion(tempDir.appendingPathComponent("content.lcpa"), nil)

        XCTAssertFalse(
            reporter.isLCPContentTransferActive(for: book.identifier),
            "a registration left behind after the transfer ends pins the book at .downloading and the half-sheet on a bar that never moves"
        )
    }

    /// The failure arm must clear too — a stuck registration would suppress the
    /// recovery re-download that a failed fulfillment specifically depends on.
    func testFulfill_completionWithError_alsoClearsTheContentTransfer() throws {
        let book = TPPBookMocker.mockBook(distributorType: .AudiobookLCP)
        let sourceURL = try writeSourceFile()
        let downloadTask = FakeDownloadTask(state: .running, identifier: 10)

        handler.fulfillLCPLicense(fileUrl: sourceURL, forBook: book, downloadTask: downloadTask)
        let completion = try XCTUnwrap(lcpService.lastCompletion)
        completion(nil, NSError(domain: "test", code: 1))

        XCTAssertFalse(reporter.isLCPContentTransferActive(for: book.identifier),
                       "the failure arm must release the registration as well")
    }

    /// F1: the PRODUCER, not the unit. `testTransferRegistry_heartbeatKeepsALongDownloadAlive`
    /// calls `sendProgress` directly, so it passed while the fulfillment path
    /// published straight to the publisher and never heartbeated at all. This
    /// drives Readium's actual progress callback and then advances the clock past
    /// the idle window — the registration must survive, or a long download expires
    /// mid-flight and a second full archive is fetched.
    func testFulfill_progressCallbackHeartbeatsTheRegistration() throws {
        let book = TPPBookMocker.mockBook(distributorType: .AudiobookLCP)
        let sourceURL = try writeSourceFile()
        let downloadTask = FakeDownloadTask(state: .running, identifier: 11)

        var now: TimeInterval = 1_000
        reporter.monotonicClock = { now }

        handler.fulfillLCPLicense(fileUrl: sourceURL, forBook: book, downloadTask: downloadTask)
        let progress = try XCTUnwrap(lcpService.lastProgress)

        // A long transfer that keeps reporting, well past the idle window.
        for _ in 0..<4 {
            now += DownloadProgressReporter.contentTransferIdleTimeout - 10
            progress(0.5)
            let ticked = expectation(description: "heartbeat applied")
            DispatchQueue.main.async { ticked.fulfill() }
            wait(for: [ticked], timeout: 5.0)
        }
        now += DownloadProgressReporter.contentTransferIdleTimeout - 10

        XCTAssertTrue(
            reporter.isLCPContentTransferActive(for: book.identifier),
            "a still-transferring .lcpa expired at the idle mark — reconciliation then schedules a duplicate of the archive already downloading"
        )
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

    /// Writes a non-empty content file where the handler resolves this book's
    /// local content, so `hasLocalContent` is true.
    @discardableResult
    private func writeLocalContent(for book: TPPBook) throws -> URL {
        // Book-based overload: the identifier overload resolves through the
        // registry, and these fixtures write content before registering.
        let url = try XCTUnwrap(bookFileManager.fileUrl(for: book, account: nil))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(repeating: 0xEE, count: 2048).write(to: url)
        return url
    }

    // MARK: - Audiobook: success waits for the content package

    /// Inverted deliberately. This test previously asserted the opposite —
    /// that an LCP audiobook is marked `.downloadSuccessful` the moment its
    /// `.lcpl` license lands — on the premise that a license alone was enough
    /// to stream. That premise no longer holds: streaming-from-license is
    /// broken upstream (readium/swift-toolkit#579) and an `.lcpa` is a single
    /// encrypted container with no partial-play threshold, so until the whole
    /// archive is on disk there is nothing playable.
    ///
    /// Marking success early had two visible costs: "Listen" was offered for a
    /// book whose audio was absent, and the half-sheet's progress bar (gated on
    /// `bookState == .downloading`) drew an invisible spacer for the entire
    /// multi-gigabyte transfer, which patrons read as a failure.
    func testFulfill_audiobook_doesNotMarkSuccessfulUntilContentLands() async throws {
        let audiobook = TPPBookMocker.mockBook(distributorType: .AudiobookLCP)
        let sourceURL = try writeSourceFile(ext: "lcpa")
        let downloadTask = FakeDownloadTask(state: .completed, identifier: 1)

        handler.fulfillLCPLicense(fileUrl: sourceURL, forBook: audiobook, downloadTask: downloadTask)

        XCTAssertTrue(spyDelegate.markSuccessfulCalls.isEmpty,
                      "the license landing must NOT mark the book successful — the .lcpa content is still transferring")
    }

    // MARK: - PP-4957 streaming-from-license (feature flag ON)

    /// Builds a handler with the LCP-audiobook-streaming flag forced ON. The
    /// setUp handler leaves the flag at its production default (OFF), so every
    /// other test in this file exercises the unchanged download-first path — the
    /// flag-OFF invariance the feature depends on.
    private func makeStreamingHandler() -> LCPFulfillmentHandler {
        let streamingHandler = LCPFulfillmentHandler(
            bookRegistry: registry,
            stateManager: stateManager,
            progressReporter: reporter,
            alertPresenter: alertPresenter,
            bookFileManager: bookFileManager,
            backgroundDownloadHandler: backgroundHandler,
            fileManager: .default,
            lcpServiceFactory: { [unowned self] in self.lcpService },
            streamingEnabledProvider: { true }
        )
        streamingHandler.delegate = spyDelegate
        return streamingHandler
    }

    /// Writes a PARSEABLE `.lcpl` license (fixed id) as the source file the
    /// handler renames and re-reads. A `0xCD`-bytes fixture fails
    /// `TPPLCPLicense(url:)` and would silently exercise only the error arm —
    /// leaving the `setFulfillmentId` success arm (which drives return/revoke)
    /// untested. This makes the real success arm run.
    private func writeValidLicenseSource(id: String) throws -> URL {
        let url = tempDir.appendingPathComponent("incoming-\(UUID().uuidString)").appendingPathExtension("lcpa")
        try "{\"id\":\"\(id)\",\"links\":[]}".data(using: .utf8)!.write(to: url)
        return url
    }

    /// Flag ON + LCP audiobook: the license alone makes the book playable, so the
    /// handler marks it successful immediately, records the fulfillment ID from
    /// the parsed license, and NEVER starts the `.lcpa` content download — the
    /// player streams via the swift-toolkit #579 fork. This is the core PP-4957
    /// behavior; deleting the streaming branch regresses every assertion here.
    func testFulfill_streamingEnabled_audiobook_marksSuccessfulOnLicense_noDownload() async throws {
        let audiobook = TPPBookMocker.mockBook(distributorType: .AudiobookLCP)
        // The book must be in the registry for setFulfillmentId to stick.
        registry.addBook(audiobook, state: .downloading)
        let licenseId = "urn:uuid:pp4957-streaming-license"
        let sourceURL = try writeValidLicenseSource(id: licenseId)
        let downloadTask = FakeDownloadTask(state: .completed, identifier: 1)

        makeStreamingHandler().fulfillLCPLicense(fileUrl: sourceURL, forBook: audiobook, downloadTask: downloadTask)

        XCTAssertEqual(lcpService.fulfillCallCount, 0,
                       "streaming ON must NOT download the .lcpa — the license alone is enough to stream")
        XCTAssertEqual(spyDelegate.markSuccessfulCalls, [audiobook.identifier],
                       "streaming ON marks the book successful on the license so 'Listen' is offered immediately")
        XCTAssertEqual(registry.fulfillmentId(forIdentifier: audiobook.identifier), licenseId,
                       "the fulfillment ID (used by return/revoke) must be recorded from the parsed license on the streaming path")
        XCTAssertFalse(reporter.isLCPContentTransferActive(for: audiobook.identifier),
                       "no content transfer starts, so no 'downloading' cue may be left active — an un-cleared cue pins the book at .downloading forever")
    }

    /// Defensive arm: streaming ON but the license bytes don't parse. The book is
    /// still marked playable (the license read only drives the fulfillment ID),
    /// but no fulfillment ID is recorded — the license-read failure is non-fatal
    /// to the streaming mark-successful path.
    func testFulfill_streamingEnabled_unreadableLicense_stillMarksSuccessful_noFulfillmentId() async throws {
        let audiobook = TPPBookMocker.mockBook(distributorType: .AudiobookLCP)
        registry.addBook(audiobook, state: .downloading)
        let sourceURL = try writeSourceFile(ext: "lcpa")  // 0xCD bytes → not a parseable license
        let downloadTask = FakeDownloadTask(state: .completed, identifier: 1)

        makeStreamingHandler().fulfillLCPLicense(fileUrl: sourceURL, forBook: audiobook, downloadTask: downloadTask)

        XCTAssertEqual(spyDelegate.markSuccessfulCalls, [audiobook.identifier],
                       "an unreadable license must not block the streaming mark-successful — the read only affects the fulfillment ID")
        XCTAssertNil(registry.fulfillmentId(forIdentifier: audiobook.identifier),
                     "no parseable license → no fulfillment ID recorded")
        XCTAssertEqual(lcpService.fulfillCallCount, 0, "still no content download")
    }

    /// Flag ON but the book is an LCP EPUB, not an audiobook: streaming is
    /// audiobook-only, so the EPUB must still fulfill (download) normally. Proves
    /// the branch is gated on `.audiobook`, not on the flag alone.
    func testFulfill_streamingEnabled_epub_stillDownloads() async throws {
        let epub = TPPBookMocker.mockBook(distributorType: .ReadiumLCP)
        let sourceURL = try writeSourceFile()
        let downloadTask = FakeDownloadTask(state: .completed, identifier: 2)

        makeStreamingHandler().fulfillLCPLicense(fileUrl: sourceURL, forBook: epub, downloadTask: downloadTask)

        XCTAssertEqual(lcpService.fulfillCallCount, 1,
                       "an LCP EPUB is unaffected by audiobook streaming — it must still download normally")
        XCTAssertTrue(spyDelegate.markSuccessfulCalls.isEmpty,
                      "the EPUB is not marked successful on the license — its content is still transferring")
    }

    // MARK: - LCP audiobook phase-2 download failure must not downgrade

    /// Regression of PP-4114-adjacent iPad bug.
    ///
    /// LCP audiobooks have a two-phase download: the .lcpl license file
    /// completes first, then the LCP toolkit runs a SECONDARY background
    /// download for the .lcpa content file from googleapis.com.
    ///
    /// The case guarded here is a RE-fulfillment of a book that already has
    /// playable content on disk (hence the explicitly staged
    /// `.downloadSuccessful` below). A first fulfillment is `.downloading` at
    /// this point and must fail honestly instead — see
    /// `testFulfill_audiobook_freshFulfillmentContentError_surfacesAlert`.
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

        // Stage a book that ALREADY has content on disk — which is what the
        // guard actually protects. Registry state alone is NOT enough any more
        // (and staging `.downloadSuccessful` by hand was a fixture that
        // production forbids as an entry condition to this path).
        try writeLocalContent(for: audiobook)
        registry.addBook(audiobook, state: .downloadSuccessful)

        // Fire the secondary-fetch failure (airplane mode in production).
        let completion = try XCTUnwrap(lcpService.lastCompletion)
        let networkLost = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorNetworkConnectionLost,
            userInfo: [NSLocalizedDescriptionKey: "The network connection was lost."]
        )
        completion(nil, networkLost)

        // Negative assertion: nothing should be published. A fixed sleep would
        // be both slow and flake-prone under -test-iterations 3, so drain the
        // main queue deterministically instead — the guard's failure mode
        // (failDownloadWithAlert off the completion) would have enqueued by now.
        await drainMainQueueAsync()

        XCTAssertEqual(registry.state(for: audiobook.identifier), .downloadSuccessful,
                       "LCP audiobook with streaming-ready license must NOT flip to .downloadFailed when the phase-2 content download fails")
        XCTAssertTrue(capturedErrors.isEmpty,
                      "No user-facing 'Fulfilment Error' alert should publish for an audiobook that's still streaming-playable")
    }

    /// Future-proofing for the `.used` transition. Audiobooks don't
    /// transition through `.used` today (only PDFs do), but the guard
    /// matches the established `(.downloadSuccessful || .used)` pattern
    /// from BookReturnService — so if audiobook open ever wires through
    /// open-once → `.used`, the regression doesn't silently return.
    func testFulfill_audiobook_inUsedState_secondaryDownloadError_doesNotFlipToFailed() async throws {
        let audiobook = TPPBookMocker.mockBook(distributorType: .AudiobookLCP)
        let sourceURL = try writeSourceFile(ext: "lcpa")
        let downloadTask = FakeDownloadTask(state: .completed, identifier: 1)

        handler.fulfillLCPLicense(fileUrl: sourceURL, forBook: audiobook, downloadTask: downloadTask)
        // Stage the future state: book has been opened at least once AND its
        // content is on disk.
        try writeLocalContent(for: audiobook)
        registry.addBook(audiobook, state: .used)

        let completion = try XCTUnwrap(lcpService.lastCompletion)
        completion(nil, NSError(domain: NSURLErrorDomain,
                                code: NSURLErrorNetworkConnectionLost,
                                userInfo: [NSLocalizedDescriptionKey: "lost"]))
        await drainMainQueueAsync()

        XCTAssertEqual(registry.state(for: audiobook.identifier), .used,
                       "Audiobook in .used (already-opened) must survive a phase-2 failure same as .downloadSuccessful")
        XCTAssertTrue(capturedErrors.isEmpty,
                      "No alert should publish for an already-opened audiobook on phase-2 failure")
    }

    /// The positive path, and the reason this test exists: after 3.2.3 moved
    /// `markDownloadSuccessful` out of the license-fulfilled branch and into the
    /// content-landed branch, NOTHING asserted that an LCP audiobook ever
    /// reaches `.downloadSuccessful` at all. Deleting that call killed zero
    /// tests while stranding every fresh LCP download in `.downloading`
    /// (Cancel-only, no Listen). Reviewers caught it; this pins it.
    ///
    /// Reaching the branch needs the real `replaceBook` to succeed, which needs
    /// a delegate that can resolve a destination — hence the mock delegate — and
    /// a license the completion can parse, hence the JSON fixture rather than
    /// arbitrary bytes.
    func testFulfill_audiobook_marksSuccessfulOnceContentLands() async throws {
        let audiobook = TPPBookMocker.mockBook(distributorType: .AudiobookLCP)

        // Destination the content will be moved to.
        let destination = tempDir.appendingPathComponent("\(audiobook.identifier).lcpa")
        let mockDelegate = MockBackgroundDownloadDelegate(bookRegistry: registry)
        mockDelegate.fileUrls[audiobook.identifier] = destination
        backgroundHandler.delegate = mockDelegate

        // The file handed to fulfillLCPLicense is renamed to `.lcpl` and later
        // re-read by the completion, so it must be a parseable license.
        let sourceURL = tempDir.appendingPathComponent("incoming-\(UUID().uuidString).lcpa")
        let licenseJSON = """
        {"id":"urn:uuid:\(UUID().uuidString)","links":[]}
        """
        try licenseJSON.data(using: .utf8)!.write(to: sourceURL)

        let downloadTask = FakeDownloadTask(state: .completed, identifier: 1)
        handler.fulfillLCPLicense(fileUrl: sourceURL, forBook: audiobook, downloadTask: downloadTask)

        XCTAssertTrue(spyDelegate.markSuccessfulCalls.isEmpty,
                      "precondition: the license landing alone must not mark success")

        // The content arrives.
        let contentURL = tempDir.appendingPathComponent("content-\(UUID().uuidString).lcpa")
        try Data(repeating: 0xAB, count: 4096).write(to: contentURL)

        let completion = try XCTUnwrap(lcpService.lastCompletion)
        completion(contentURL, nil)
        await awaitConditionAsync { [weak self] in
            self?.spyDelegate.markSuccessfulCalls.isEmpty == false
        }

        XCTAssertEqual(spyDelegate.markSuccessfulCalls, [audiobook.identifier],
                       "once the .lcpa is stored the book must become downloadSuccessful, or it strands in .downloading forever")
        XCTAssertTrue(capturedErrors.isEmpty,
                      "a successful content landing must not surface a failure alert")
    }

    /// The other side of the guard above. On a FIRST fulfillment the book is
    /// still `.downloading` when the content fetch fails, so there is no
    /// playable audio to protect and (with streaming broken) nothing to fall
    /// back to. Continuing silently would strand the book in `.downloading`
    /// forever with no way for the patron to retry, so the failure must
    /// surface. Before this change the book had already been marked
    /// `.downloadSuccessful`, which is what sent it down the "leave it alone"
    /// branch and produced a book that advertised Listen but had no audio.
    func testFulfill_audiobook_freshFulfillmentContentError_surfacesAlert() async throws {
        let audiobook = TPPBookMocker.mockBook(distributorType: .AudiobookLCP)
        let sourceURL = try writeSourceFile(ext: "lcpa")
        let downloadTask = FakeDownloadTask(state: .completed, identifier: 1)

        handler.fulfillLCPLicense(fileUrl: sourceURL, forBook: audiobook, downloadTask: downloadTask)

        // A first fulfillment: the book is mid-download, NOT streaming-ready.
        registry.addBook(audiobook, state: .downloading)

        let completion = try XCTUnwrap(lcpService.lastCompletion)
        completion(nil, NSError(domain: NSURLErrorDomain,
                                code: NSURLErrorNetworkConnectionLost,
                                userInfo: [NSLocalizedDescriptionKey: "lost"]))
        await waitForPublishedError()

        XCTAssertFalse(capturedErrors.isEmpty,
                       "a first fulfillment whose content never arrived must surface a failure, not sit in .downloading forever")
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
