//
//  ReaderServiceRouteOwnershipTests.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import CryptoKit
import PalaceBookModel
import PalaceReadingPosition
@testable import Palace

/// PP-5022 — pins the ownership rule the LCP-PDF completions use before popping.
///
/// An LCP open runs for seconds or minutes and finishes asynchronously. The
/// patron can back out of the loading view — which restores the tab bar — and
/// push something else on that same stack before the open lands. Both
/// completion arms (`abortRunawayOpen` and the `openBook` failure arm) used to
/// call `path.removeLast()` unconditionally, which removes the patron's screen
/// rather than the reader route. This is the decision that stops that, and it
/// is the only part of the flow that can be exercised without driving a real
/// Readium publication open.
@MainActor
final class ReaderServiceRouteOwnershipTests: XCTestCase {

    private var service: ReaderService!
    private var coordinator: NavigationCoordinator!
    private let bookId = "lcp-pdf-book"

    override func setUp() {
        super.setUp()
        service = ReaderService()
        coordinator = NavigationCoordinator()
    }

    override func tearDown() {
        service = nil
        coordinator = nil
        super.tearDown()
    }

    /// The ordinary abort: the loading route this open pushed is still on top,
    /// so it is ours to remove.
    func testPopRouteIfStillOwned_RouteStillPending_PopsIt() {
        coordinator.markLCPPDFExtractPending(forBookId: bookId)
        coordinator.push(.pdf(BookRoute(id: bookId)))

        let popped = service.popRouteIfStillOwned(forBookIdentifier: bookId, on: coordinator)

        XCTAssertTrue(popped)
        XCTAssertEqual(coordinator.path.count, 0, "The reader route this open pushed must be removed")
    }

    /// The regression: patron backed out (pending cleared) and pushed their own
    /// screen. A late abort must leave it alone.
    func testPopRouteIfStillOwned_PatronBackedOutAndPushedTheirOwn_DoesNotPop() {
        coordinator.markLCPPDFExtractPending(forBookId: bookId)
        coordinator.push(.pdf(BookRoute(id: bookId)))
        // Backing out of the loading view tears the open down…
        coordinator.clearLCPPDFExtractPending(forBookId: bookId)
        coordinator.popToRoot(animated: false)
        // …and the patron navigates somewhere else on the same stack.
        coordinator.push(.bookDetail(BookRoute(id: "some-other-book")))

        let popped = service.popRouteIfStillOwned(forBookIdentifier: bookId, on: coordinator)

        XCTAssertFalse(popped)
        XCTAssertEqual(coordinator.path.count, 1,
                       "A late completion must not remove a route the patron pushed after backing out")
    }

    /// A different book's open must not pop this book's route.
    func testPopRouteIfStillOwned_PendingForAnotherBook_DoesNotPop() {
        coordinator.markLCPPDFExtractPending(forBookId: "a-different-book")
        coordinator.push(.pdf(BookRoute(id: "a-different-book")))

        let popped = service.popRouteIfStillOwned(forBookIdentifier: bookId, on: coordinator)

        XCTAssertFalse(popped)
        XCTAssertEqual(coordinator.path.count, 1)
    }

    /// Pending but nothing on the stack — nothing to pop, and no crash on the
    /// empty-path edge.
    func testPopRouteIfStillOwned_EmptyPath_DoesNotPop() {
        coordinator.markLCPPDFExtractPending(forBookId: bookId)

        let popped = service.popRouteIfStillOwned(forBookIdentifier: bookId, on: coordinator)

        XCTAssertFalse(popped)
        XCTAssertEqual(coordinator.path.count, 0)
    }

    /// No stack recorded for the open at all (its host was torn down): nothing
    /// to act on, and emphatically not "act on whatever is visible instead".
    func testPopRouteIfStillOwned_NoCoordinator_DoesNothing() {
        XCTAssertFalse(service.popRouteIfStillOwned(forBookIdentifier: bookId, on: nil))
    }

    // MARK: - Superseded-open detection

    /// The generation an open started under is still current: its completions
    /// are the ones that should act.
    func testIsSupersededOpen_GenerationUnchanged_IsNotSuperseded() {
        XCTAssertFalse(service.isSupersededOpen(forBookIdentifier: bookId, generation: 0))
    }

    /// A back-out bumps the generation via teardown, so the completion still in
    /// flight from the previous open must recognise itself as stale — otherwise
    /// its cleanup lands on the open that replaced it.
    func testIsSupersededOpen_AfterTeardown_OldGenerationIsSuperseded() {
        service.releaseLCPPDFOpen(forBookIdentifier: bookId)

        XCTAssertTrue(service.isSupersededOpen(forBookIdentifier: bookId, generation: 0),
                      "A completion from before the teardown must not act")
        XCTAssertFalse(service.isSupersededOpen(forBookIdentifier: bookId, generation: 1),
                       "The open that replaced it is the current one")
    }

    /// Staleness is per book: tearing down book A must not make book B's
    /// in-flight completion look superseded.
    func testIsSupersededOpen_IsScopedToTheBook() {
        service.releaseLCPPDFOpen(forBookIdentifier: "another-book")

        XCTAssertFalse(service.isSupersededOpen(forBookIdentifier: bookId, generation: 0),
                       "Another book's teardown must not supersede this book's open")
    }

    // MARK: - Backing out of the loading view

    private func makeContent(for book: TPPBook) -> (TPPPDFDocument, TPPPDFDocumentMetadata) {
        (TPPPDFDocument(url: URL(fileURLWithPath: "/nonexistent/extracted.pdf")),
         TPPPDFDocumentMetadata(with: book,
                                bookRegistry: TPPBookRegistryMock(),
                                positionWriter: InertPositionWriter()))
    }

    /// Backing out while the extract runs abandons the open: its late completion
    /// must not store the document or leave the loader pending.
    func testBackOutWhileExtracting_LateCompletion_IsIgnored() throws {
        let book = TPPBookMocker.snapshotPDF()
        let route = BookRoute(id: book.identifier)
        let generation = try XCTUnwrap(service.beginLCPPDFOpen(for: book, on: coordinator))

        coordinator.path.removeLast()
        var built = false
        let handedOff = service.completeLCPPDFOpen(forBookIdentifier: book.identifier, generation: generation) {
            built = true
            return makeContent(for: book)
        }

        XCTAssertFalse(handedOff)
        XCTAssertFalse(built, "A superseded completion must not build the PDFKit document")
        XCTAssertNil(coordinator.resolvePDF(for: route))
        XCTAssertFalse(coordinator.isLCPPDFExtractPending(for: route))
    }

    /// After a back-out the book is no longer in flight, so a reopen starts a
    /// new open instead of coalescing into the abandoned one.
    func testBackOutWhileExtracting_Reopen_StartsANewGeneration() throws {
        let book = TPPBookMocker.snapshotPDF()
        let first = try XCTUnwrap(service.beginLCPPDFOpen(for: book, on: coordinator))
        coordinator.path.removeLast()

        let second = try XCTUnwrap(service.beginLCPPDFOpen(for: book, on: coordinator),
                                   "A reopen after backing out must not be coalesced")

        XCTAssertTrue(service.isSupersededOpen(forBookIdentifier: book.identifier, generation: first))
        XCTAssertFalse(service.isSupersededOpen(forBookIdentifier: book.identifier, generation: second))
        XCTAssertEqual(coordinator.path.count, 1)
        XCTAssertTrue(coordinator.isLCPPDFExtractPending(for: BookRoute(id: book.identifier)))
    }

    /// Without a back-out a second tap coalesces into the open in flight.
    func testBeginLCPPDFOpen_WhileInFlight_Coalesces() {
        let book = TPPBookMocker.snapshotPDF()
        XCTAssertNotNil(service.beginLCPPDFOpen(for: book, on: coordinator))

        XCTAssertNil(service.beginLCPPDFOpen(for: book, on: coordinator))
        XCTAssertEqual(coordinator.path.count, 1, "A coalesced tap must not push a second route")
    }

    /// The normal flow, extract then reader, keeps the open current: the handoff
    /// lands, and closing the reader afterwards does not tear anything down.
    func testExtractThenReader_DoesNotRelease() throws {
        let book = TPPBookMocker.snapshotPDF()
        let route = BookRoute(id: book.identifier)
        let generation = try XCTUnwrap(service.beginLCPPDFOpen(for: book, on: coordinator))

        let handedOff = service.completeLCPPDFOpen(forBookIdentifier: book.identifier, generation: generation) {
            makeContent(for: book)
        }
        guard case .reader = coordinator.pdfRouteContent(for: route) else {
            return XCTFail("The handoff must show the PDFKit reader")
        }
        coordinator.path.removeLast()

        XCTAssertTrue(handedOff)
        XCTAssertFalse(service.isSupersededOpen(forBookIdentifier: book.identifier, generation: generation),
                       "Neither the handoff nor closing the reader may bump the generation")
        XCTAssertEqual(service.beginLCPPDFOpen(for: book, on: coordinator), generation + 1,
                       "The handoff must drop the in-flight entry so the next open is not coalesced")
    }

    /// The handoff ends the loading progress it was tracking. `LCPPDFOpenProgress`
    /// has no seam into `ReaderService`, so this resets the shared reporter the
    /// way `LCPPDFOpenProgressTests` does.
    func testCompleteLCPPDFOpen_ProgressTracksThisBook_FinishesIt() throws {
        let book = TPPBookMocker.snapshotPDF()
        let progress = LCPPDFOpenProgress.shared
        addTeardownBlock { @MainActor in progress.finish() }
        let generation = try XCTUnwrap(service.beginLCPPDFOpen(for: book, on: coordinator))
        progress.begin(bookIdentifier: book.identifier)

        service.completeLCPPDFOpen(forBookIdentifier: book.identifier, generation: generation) {
            makeContent(for: book)
        }

        XCTAssertNil(progress.bookIdentifier)
        XCTAssertEqual(progress.phase, .idle)
    }

    /// A handoff for one book must not end the loader of another book's open.
    func testCompleteLCPPDFOpen_ProgressTracksAnotherBook_LeavesItRunning() throws {
        let book = TPPBookMocker.snapshotPDF()
        let progress = LCPPDFOpenProgress.shared
        addTeardownBlock { @MainActor in progress.finish() }
        let generation = try XCTUnwrap(service.beginLCPPDFOpen(for: book, on: coordinator))
        progress.begin(bookIdentifier: "another-book")

        service.completeLCPPDFOpen(forBookIdentifier: book.identifier, generation: generation) {
            makeContent(for: book)
        }

        XCTAssertEqual(progress.bookIdentifier, "another-book")
        XCTAssertNotEqual(progress.phase, .idle)
    }

    /// An abort's pop runs the release through the back-out, so it supersedes
    /// the open once and leaves the book free to reopen.
    func testPopRouteIfStillOwned_AfterBegin_ReleasesTheOpen() throws {
        let book = TPPBookMocker.snapshotPDF()
        let generation = try XCTUnwrap(service.beginLCPPDFOpen(for: book, on: coordinator))

        XCTAssertTrue(service.popRouteIfStillOwned(forBookIdentifier: book.identifier, on: coordinator))

        XCTAssertTrue(service.isSupersededOpen(forBookIdentifier: book.identifier, generation: generation))
        XCTAssertFalse(service.isSupersededOpen(forBookIdentifier: book.identifier, generation: generation + 1))
        XCTAssertEqual(service.beginLCPPDFOpen(for: book, on: coordinator), generation + 2)
    }

    // MARK: - Aborting an open

    private func recordAbortReports() -> () -> [String] {
        var reports: [String] = []
        service.abortedOpenReporter = { reports.append($0.identifier) }
        return { reports }
    }

    /// Every back-out cancels the extract, and that cancellation reaches the
    /// abort. It must not show "Unable to open book" or pop the patron's screen.
    func testAbortRunawayOpen_AfterBackOut_ShowsNoAlertAndPopsNothing() throws {
        let book = TPPBookMocker.snapshotPDF()
        let reports = recordAbortReports()
        let generation = try XCTUnwrap(service.beginLCPPDFOpen(for: book, on: coordinator))
        coordinator.path.removeLast()
        coordinator.push(.bookDetail(BookRoute(id: "some-other-book")))

        service.abortRunawayOpen(for: book, generation: generation)

        XCTAssertEqual(reports(), [], "A superseded open must not alert the patron")
        XCTAssertEqual(coordinator.path.count, 1, "A superseded open must not pop the patron's screen")
    }

    /// Back out, reopen, then the first open fails: the reopened route and its
    /// open must be left alone.
    func testAbortRunawayOpen_OldOpenFailsAfterReopen_LeavesTheNewOpenUntouched() throws {
        let book = TPPBookMocker.snapshotPDF()
        let reports = recordAbortReports()
        let first = try XCTUnwrap(service.beginLCPPDFOpen(for: book, on: coordinator))
        coordinator.path.removeLast()
        let second = try XCTUnwrap(service.beginLCPPDFOpen(for: book, on: coordinator))

        service.abortRunawayOpen(for: book, generation: first)

        XCTAssertEqual(coordinator.path.count, 1, "The reopened route must stay")
        XCTAssertTrue(coordinator.isLCPPDFExtractPending(for: BookRoute(id: book.identifier)))
        XCTAssertFalse(service.isSupersededOpen(forBookIdentifier: book.identifier, generation: second))
        XCTAssertEqual(reports(), [])
    }

    /// The abort of the current open pops its route, tears it down once and
    /// tells the patron once.
    func testAbortRunawayOpen_CurrentOpen_PopsReleasesOnceAndReports() throws {
        let book = TPPBookMocker.snapshotPDF()
        let reports = recordAbortReports()
        let generation = try XCTUnwrap(service.beginLCPPDFOpen(for: book, on: coordinator))

        service.abortRunawayOpen(for: book, generation: generation)

        XCTAssertEqual(coordinator.path.count, 0)
        XCTAssertEqual(reports(), [book.identifier])
        XCTAssertEqual(service.beginLCPPDFOpen(for: book, on: coordinator), generation + 2,
                       "The abort must release the open exactly once")
    }

    // MARK: - Opening a cached extract

    #if LCP
    /// The disk-cache hit skips the Readium open: a valid extract from an
    /// earlier open must reach the reader as a document on that file.
    func testHandOffExtractedPDF_CachedExtract_OpensTheReaderOnThatFile() throws {
        let book = TPPBookMocker.snapshotPDF()
        let route = BookRoute(id: book.identifier)
        let account = "reader-service-handoff-test-account"
        let accountDir = try XCTUnwrap(TPPBookContentMetadataFilesHelper.directory(for: account))
        let hashed = SHA256.hash(data: Data(book.identifier.utf8)).map { String(format: "%02x", $0) }.joined()
        let seeded = accountDir.appendingPathComponent("registry/lcp-pdf-extracts/\(hashed).pdf")
        try FileManager.default.createDirectory(at: seeded.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (Data("%PDF-1.4".utf8) + Data(repeating: 0x20, count: 2_048)).write(to: seeded)
        addTeardownBlock { try? FileManager.default.removeItem(at: seeded) }
        let cachedURL = try XCTUnwrap(LCPPDFDiskExtract.cachedURL(bookIdentifier: book.identifier, account: account))
        let generation = try XCTUnwrap(service.beginLCPPDFOpen(for: book, on: coordinator))

        service.handOffExtractedPDF(at: cachedURL, for: book, generation: generation, openStartedAt: Date(),
                                    makeMetadata: { self.makeContent(for: $0).1 })

        guard case .reader(let document, _) = coordinator.pdfRouteContent(for: route) else {
            return XCTFail("The cached extract must open in the PDFKit reader")
        }
        XCTAssertEqual(document.fileURL, seeded)
        XCTAssertFalse(coordinator.isLCPPDFExtractPending(for: route))
    }
    #endif

    // MARK: - Cancelling the extract

    private func makeExtractTask() -> Task<Void, Never> {
        let task = Task<Void, Never> {
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 10_000_000) }
        }
        addTeardownBlock { task.cancel() }
        return task
    }

    func testReleaseLCPPDFOpen_CancelsTheRegisteredExtract() {
        let task = makeExtractTask()
        service.registerExtractTask(forBookIdentifier: bookId, task)

        service.releaseLCPPDFOpen(forBookIdentifier: bookId)

        XCTAssertTrue(task.isCancelled)
    }

    /// Backing out stops the extract rather than leaving it decrypting into
    /// the progress reporter the next open shares.
    func testBackOutWhileExtracting_CancelsTheExtract() throws {
        let book = TPPBookMocker.snapshotPDF()
        let task = makeExtractTask()
        _ = try XCTUnwrap(service.beginLCPPDFOpen(for: book, on: coordinator))
        service.registerExtractTask(forBookIdentifier: book.identifier, task)

        coordinator.path.removeLast()

        XCTAssertTrue(task.isCancelled)
    }

    func testReleaseLCPPDFOpen_LeavesAnotherBooksExtractRunning() {
        let task = makeExtractTask()
        service.registerExtractTask(forBookIdentifier: "another-book", task)

        service.releaseLCPPDFOpen(forBookIdentifier: bookId)

        XCTAssertFalse(task.isCancelled)
    }

    // MARK: - Watchdog

    private var overLimit: Int { ReaderService.runawayDecryptBlockLimit + 1 }

    func testWatchdogVerdict_CurrentOpenOverTheLimit_Aborts() {
        XCTAssertEqual(service.watchdogVerdict(forBookIdentifier: bookId, generation: 0,
                                               trackedBookIdentifier: bookId, decryptedBlocks: overLimit),
                       .abort)
    }

    func testWatchdogVerdict_AtTheLimit_KeepsWatching() {
        XCTAssertEqual(service.watchdogVerdict(forBookIdentifier: bookId, generation: 0,
                                               trackedBookIdentifier: bookId,
                                               decryptedBlocks: ReaderService.runawayDecryptBlockLimit),
                       .keepWatching)
    }

    /// After a back-out the reporter belongs to whatever opens next; the old
    /// open's watchdog must stop rather than abort it.
    func testWatchdogVerdict_SupersededOpen_Stops() {
        service.releaseLCPPDFOpen(forBookIdentifier: bookId)

        XCTAssertEqual(service.watchdogVerdict(forBookIdentifier: bookId, generation: 0,
                                               trackedBookIdentifier: bookId, decryptedBlocks: overLimit),
                       .stop)
    }

    /// Book A's watchdog must not read book B's block count and tell the
    /// patron A is too large.
    func testWatchdogVerdict_ReporterTracksAnotherBook_Stops() {
        XCTAssertEqual(service.watchdogVerdict(forBookIdentifier: bookId, generation: 0,
                                               trackedBookIdentifier: "another-book", decryptedBlocks: overLimit),
                       .stop)
    }
}

private struct InertPositionWriter: PositionWriter {
    func save(_ snapshot: PositionSnapshot) async throws -> ServerPositionID? { nil }
    func load(for bookID: String) async throws -> PositionSnapshot? { nil }
    func cancel(for bookID: String) async {}
}
