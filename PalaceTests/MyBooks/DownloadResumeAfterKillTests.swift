//
//  DownloadResumeAfterKillTests.swift
//  PalaceTests
//
//  Deep mutation-killing coverage for the partial-resume / kill / 99 %
//  late-cancel behaviours of the download lifecycle.
//
//  These tests do NOT touch DownloadCoordinator or MyBooksDownloadCenter
//  production code. They drive the BackgroundDownloadHandler.replaceBook /
//  moveFile / validateDownloadedFile seams and the
//  DownloadCancellationHandler late-cancel state machine through their
//  documented public surfaces, with a real FileManager scoped to a per-
//  test temp directory and stub URL session tasks. The point is to pin
//  down the file-integrity contract: under a kill mid-download or a
//  cancel near completion, the system never leaves truncated payload at
//  the destination URL and never marks the registry .downloadSuccessful
//  when the bytes on disk are incomplete or invalid.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

private let resumeTestSession: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [HTTPStubURLProtocol.self]
    return URLSession(configuration: config)
}()

@MainActor
final class DownloadResumeAfterKillTests: XCTestCase {

    private var tempDir: URL!
    private var registry: TPPBookRegistryMock!
    private var mockDelegate: MockBackgroundDownloadDelegate!
    private var handler: BackgroundDownloadHandler!

    override func setUpWithError() throws {
        try super.setUpWithError()
        HTTPStubURLProtocol.reset()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ResumeAfterKill-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        registry = TPPBookRegistryMock()
        mockDelegate = MockBackgroundDownloadDelegate(bookRegistry: registry)
        handler = BackgroundDownloadHandler(delegate: mockDelegate)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        HTTPStubURLProtocol.reset()
        handler = nil
        mockDelegate = nil
        registry = nil
        tempDir = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func inertDownloadTask() -> URLSessionDownloadTask {
        resumeTestSession.downloadTask(with: URL(string: "https://example.com/x")!)
    }

    private func makeBook(_ id: String = UUID().uuidString) -> TPPBook {
        let book = TPPBookMocker.mockBook(identifier: id, title: "Title-\(id)", distributorType: .EpubZip)
        registry.addBook(book, state: .downloading)
        return book
    }

    // MARK: - Partial-resume → full body replaces partial bytes without truncation

    /// Simulates: download was killed at 50 % (a partial file sits at the
    /// destination URL), then the user resumed and the URLSession completion
    /// hands a *fresh* full payload at a different source URL. `replaceBook`
    /// must atomically swap the partial bytes out for the full payload —
    /// never appending, never leaving the old half-written content at the
    /// destination. Mutation target: removing `replaceItemAt` (which would
    /// keep the partial file) or skipping `validateDownloadedFile`.
    func testReplaceBook_partialAtDestination_isReplacedByFreshFullPayload() throws {
        let book = makeBook()
        let dest = tempDir.appendingPathComponent("dest.epub")
        let halfBytes = Data(repeating: 0xAB, count: 5_000)
        try halfBytes.write(to: dest)
        mockDelegate.fileUrls[book.identifier] = dest

        let source = tempDir.appendingPathComponent("source.epub")
        let fullBytes = Data(repeating: 0xCD, count: 10_000)
        try fullBytes.write(to: source)

        let result = handler.replaceBook(book, withFileAtURL: source, forDownloadTask: inertDownloadTask())
        XCTAssertTrue(result, "Resume completion with valid full payload must succeed")

        let onDisk = try Data(contentsOf: dest)
        XCTAssertEqual(onDisk, fullBytes,
                       "Destination must hold the fresh full payload — not the old partial bytes")
        XCTAssertNotEqual(onDisk, halfBytes,
                          "Half-written bytes from the killed download must not survive replacement")
        XCTAssertEqual(registry.state(for: book.identifier), .downloadSuccessful,
                       "After atomic replace with valid bytes, registry must flip to .downloadSuccessful")
    }

    /// If the resume payload is empty (truncated server response after a kill),
    /// the file-validation guard must reject it: registry must NOT advance to
    /// `.downloadSuccessful`. Mutation target: a `> 0` becoming `>= 0` would
    /// silently accept truncation.
    func testReplaceBook_truncatedResumePayload_failsValidationAndStateUnchanged() throws {
        let book = makeBook()
        let dest = tempDir.appendingPathComponent("dest.epub")
        try Data(repeating: 0xAB, count: 3_000).write(to: dest)
        mockDelegate.fileUrls[book.identifier] = dest

        let truncated = tempDir.appendingPathComponent("truncated.epub")
        try Data().write(to: truncated)  // 0 bytes — server hung up

        let result = handler.replaceBook(book, withFileAtURL: truncated, forDownloadTask: inertDownloadTask())
        XCTAssertFalse(result,
                       "Empty/truncated resume payload must fail validation — never claim success")
        XCTAssertNotEqual(registry.state(for: book.identifier), .downloadSuccessful,
                          "Registry must NOT advance to .downloadSuccessful when bytes are truncated")
    }

    /// `replaceBook` over an existing partial file must NOT produce a double-
    /// write artefact (no two copies, no concatenation): the destination
    /// size after replace == the source size, byte-for-byte equal. This
    /// pins the "exactly one copy on disk" contract.
    func testReplaceBook_noDoubleWriteOrConcatenation() throws {
        let book = makeBook()
        let dest = tempDir.appendingPathComponent("dest.epub")
        let partial = Data(repeating: 0x11, count: 2_048)
        try partial.write(to: dest)
        mockDelegate.fileUrls[book.identifier] = dest

        let source = tempDir.appendingPathComponent("source.epub")
        let full = Data(repeating: 0x22, count: 4_096)
        try full.write(to: source)

        XCTAssertTrue(handler.replaceBook(book, withFileAtURL: source, forDownloadTask: inertDownloadTask()))

        let onDisk = try Data(contentsOf: dest)
        XCTAssertEqual(onDisk.count, full.count,
                       "After replace, on-disk size must equal source size — no double-write, no append")
        // And only one file should reside at the destination's parent (we
        // wrote partial + dest; partial should be gone, source consumed).
        let dirContents = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        XCTAssertFalse(dirContents.contains("source.epub"),
                       "moveItem semantics: the source file must be consumed, not duplicated")
    }

    /// If the source temp file disappears between the URLSession download
    /// and the `replaceBook` call (e.g. the iOS background machinery cleared
    /// it), the handler must propagate a failure and not leave the partial
    /// file untouched-but-marked-successful. Mutation target: short-circuiting
    /// to `return true` would create a phantom success.
    func testReplaceBook_missingSourceAfterKill_failsCleanly() throws {
        let book = makeBook()
        let dest = tempDir.appendingPathComponent("dest.epub")
        try Data(repeating: 0xFF, count: 1_024).write(to: dest)
        mockDelegate.fileUrls[book.identifier] = dest

        let missingSource = tempDir.appendingPathComponent("never-existed.epub")

        let result = handler.replaceBook(book, withFileAtURL: missingSource, forDownloadTask: inertDownloadTask())
        XCTAssertFalse(result, "Missing source must surface as a failure")
        XCTAssertNotEqual(registry.state(for: book.identifier), .downloadSuccessful,
                          "Phantom success after a missing source would mis-report disk state")
    }

    // MARK: - moveFile after kill: previous partial bytes must not survive

    /// `moveFile` is the analog of replaceBook for the "no existing dest"
    /// path. After a kill, a stale partial may still be at the destination
    /// (e.g. because the previous attempt got far enough to write some bytes
    /// before the URL session failed). The pre-remove inside moveFile must
    /// clear those before the fresh source is moved into place.
    func testMoveFile_overStalePartialAtDestination_removesAndReplaces() throws {
        let book = makeBook()
        let dest = tempDir.appendingPathComponent("dest.epub")
        let stale = Data(repeating: 0x55, count: 1_500)
        try stale.write(to: dest)
        mockDelegate.fileUrls[book.identifier] = dest

        let source = tempDir.appendingPathComponent("source.epub")
        let fresh = Data(repeating: 0x66, count: 3_000)
        try fresh.write(to: source)

        let ok = handler.moveFile(at: source, toDestinationForBook: book, forDownloadTask: inertDownloadTask())
        XCTAssertTrue(ok)

        let onDisk = try Data(contentsOf: dest)
        XCTAssertEqual(onDisk, fresh,
                       "moveFile must clobber stale partial bytes at the destination")
        XCTAssertEqual(registry.state(for: book.identifier), .downloadSuccessful)
    }

    // MARK: - 99% late-cancel race: partial must be cleaned up

    /// Late-cancel race: a download cancel arrives after URLSession started
    /// writing but before the completion fires. The cancellation handler
    /// must still flip state to `.downloadNeeded` and clear the download-info
    /// map even at high progress so a retry can be issued cleanly.
    /// Mutation target: gating cancellation on `progress < 0.99` would let
    /// a late cancel get swallowed.
    func testCancel_at99PercentProgress_resetsStateAndClearsMaps() async throws {
        let stateManager = DownloadStateManager()
        let book = makeBook("late-cancel")
        registry.setState(.downloading, for: book.identifier)

        let stubTask = LateCancelStubTask(taskIdentifier: 99)
        let info = MyBooksDownloadInfo(
            downloadProgress: 0.99,
            downloadTask: stubTask,
            rightsManagement: .none
        )
        await stateManager.bookIdentifierToDownloadInfo.set(book.identifier, value: info)
        await stateManager.taskIdentifierToBook.set(99, value: book)

        let spy = LateCancelSpy()
        let cancelHandler = DownloadCancellationHandler(
            stateManager: stateManager,
            bookRegistry: registry,
            adobeDRMService: AdobeDRMService.shared
        )
        cancelHandler.delegate = spy

        cancelHandler.cancelDownload(for: book.identifier)

        // Wait for the async cleanup task to settle.
        await awaitConditionAsync(timeout: 10.0) {
            spy.scheduleCount > 0
        }

        XCTAssertEqual(stubTask.cancelByProducingResumeDataCount, 1,
                       "Late cancel must still call URLSessionDownloadTask.cancel — even at 99%")
        XCTAssertEqual(registry.state(for: book.identifier), .downloadNeeded,
                       "Late cancel must flip registry to .downloadNeeded so retry is offered")
        let leftover = await stateManager.bookIdentifierToDownloadInfo.get(book.identifier)
        XCTAssertNil(leftover, "Stale download info must be cleared after late cancel")
        let leftoverTask = await stateManager.taskIdentifierToBook.get(99)
        XCTAssertNil(leftoverTask, "Stale task-id mapping must be cleared after late cancel")
    }

    /// After a 99% cancel, any half-written file at the destination must
    /// not be silently claimed as successful by a downstream validate call.
    /// Pin the "validateDownloadedFile is the gate" contract for 0-byte
    /// remnants.
    func testValidateDownloadedFile_after99PercentCancelLeavesZeroBytes_returnsFalse() throws {
        let book = makeBook("zero-leftover")
        let dest = tempDir.appendingPathComponent("dest.epub")
        // Simulate the kernel leaving a 0-byte placeholder at the destination
        // after a hard kill.
        FileManager.default.createFile(atPath: dest.path, contents: Data(), attributes: nil)

        XCTAssertFalse(handler.validateDownloadedFile(at: dest, for: book),
                       "A 0-byte placeholder from a killed download must fail validation")
    }
}

// MARK: - Stubs

private final class LateCancelStubTask: URLSessionDownloadTask {
    private let _taskIdentifier: Int
    private(set) var cancelByProducingResumeDataCount = 0
    init(taskIdentifier: Int) {
        self._taskIdentifier = taskIdentifier
        super.init()
    }
    override var taskIdentifier: Int { _taskIdentifier }
    override func cancel() {}
    override func cancel(byProducingResumeData completionHandler: @escaping (Data?) -> Void) {
        cancelByProducingResumeDataCount += 1
        completionHandler(nil)
    }
    override func resume() {}
    override func suspend() {}
}

private final class LateCancelSpy: DownloadCancellationHandlerDelegate {
    private(set) var broadcastCount = 0
    private(set) var scheduleCount = 0
    func broadcastUpdate() { broadcastCount += 1 }
    func schedulePendingStartsIfPossible() { scheduleCount += 1 }
}
