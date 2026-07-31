//
//  LocalBookContentServiceTests.swift
//  PalaceTests
//
//  Coverage for the local-content deletion paths extracted into
//  LocalBookContentService. Exercises both `deleteLocalContent`
//  overloads (identifier + book) across the epub / pdf / audiobook
//  / unsupported branches against a temp-dir BookFileManager.
//

import XCTest
import Combine
import PalaceCatalog
@testable import Palace

final class LocalBookContentServiceTests: XCTestCase {

    private var tempDir: URL!
    private var registry: TPPBookRegistryMock!
    private var bookFileManager: SpyBookFileManager!
    private var service: LocalBookContentService!
    private var appContainer: AppContainer!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LocalBookContentServiceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        appContainer = makeTestAppContainer()
        registry = TPPBookRegistryMock()
        bookFileManager = SpyBookFileManager(
            tempDir: tempDir,
            bookRegistry: registry,
            accountsManager: appContainer.accountsManager
        )
        service = LocalBookContentService(
            bookRegistry: registry,
            accountsManager: appContainer.accountsManager,
            bookFileManager: bookFileManager
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        registry = nil
        bookFileManager = nil
        service = nil
        appContainer = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    @discardableResult
    private func writeFile(at url: URL, bytes: Int = 100) throws -> URL {
        try Data(repeating: 0xCC, count: bytes).write(to: url)
        return url
    }

    private func seedBook(_ book: TPPBook) {
        registry.addBook(book, location: nil, state: .downloadSuccessful,
                         fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)
    }

    // MARK: - deleteLocalContent(for: identifier)

    func testDeleteForIdentifier_unknownIdentifier_logsAndDoesNothing() {
        // No book added — service should bail out without touching disk.
        // Drop a stray file so we can assert nothing got removed.
        let strayURL = tempDir.appendingPathComponent("stray.epub")
        try? Data(repeating: 0x00, count: 50).write(to: strayURL)

        service.deleteLocalContent(for: "nonexistent-id")

        XCTAssertTrue(FileManager.default.fileExists(atPath: strayURL.path),
                      "Unknown identifier must not delete unrelated files")
    }

    func testDeleteForIdentifier_lookUpsBookInRegistryAndDelegates() throws {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        seedBook(book)

        let url = bookFileManager.fakeURLFor(book)
        try writeFile(at: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        service.deleteLocalContent(for: book.identifier)

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "Identifier-overload must resolve the book and delete its file")
    }

    // MARK: - deleteLocalContent(forBook:)

    func testDeleteForBook_epub_removesFileWhenPresent() throws {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let url = bookFileManager.fakeURLFor(book)
        try writeFile(at: url)

        service.deleteLocalContent(forBook: book)

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "epub branch must remove the file from disk")
    }

    func testDeleteForBook_epub_missingFile_logsButDoesNotThrow() {
        // No file written, just attempt deletion. The service catches
        // missing-file and continues — no XCTFail expected.
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        service.deleteLocalContent(forBook: book)
        // No assertion needed beyond "didn't crash" — the test passing
        // means the method handled the missing-file branch gracefully.
    }

    func testDeleteForBook_pdf_removesContentFile() throws {
        let book = TPPBookMocker.mockBook(distributorType: .OpenAccessPDF)
        let url = bookFileManager.fakeURLFor(book)
        try writeFile(at: url)

        service.deleteLocalContent(forBook: book)

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "pdf branch must remove the content file")
    }

    func testDeleteForBook_unresolvableFileURL_doesNotCrashAndLogsWarning() {
        // MISSING-001-OK: crash-guard — exercises the "Could not resolve fileUrl"
        // early-return; observable contract is "no crash, no exception, no side
        // effect on the file manager beyond the lookup attempt".
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        bookFileManager.failResolutionForIdentifier = book.identifier

        service.deleteLocalContent(forBook: book)

        // Tested implicitly — no crash, no exception. The warning log
        // path is hit per the implementation's `Log.warn`.
    }

    // MARK: - Per-account isolation

    func testDeleteForBook_accountOverride_passedThroughToBookFileManager() throws {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let url = bookFileManager.fakeURLFor(book)
        try writeFile(at: url)

        service.deleteLocalContent(forBook: book, account: "explicit-account-id")

        XCTAssertEqual(bookFileManager.lastResolvedAccount, "explicit-account-id",
                       "Caller-supplied account must be threaded through to the file manager")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

#if LCP

    // MARK: - redownloadLCPContentFile: duplicate-transfer guard
    //
    // Two callers reach this method independently — the registry-load self-heal
    // (BookRegistrySync) and the open-time gate
    // (AudiobookSessionManager.gateOnLCPContentDownload) — and the only guard
    // used to be `fileExists`, which cannot see an in-flight transfer. On device
    // against A1QA that produced two concurrent full downloads of the same
    // 778 MB archive, one of which was stored and the other discarded.

    /// Builds a Marketplace LCP audiobook in the `/loans/` XML feed shape that
    /// `LCPAudiobooks.canOpenBook` actually accepts: the LCP *license* MIME on
    /// `defaultAcquisition`, with `application/audiobook+lcp` as the terminal
    /// indirect child so `defaultBookContentType` resolves to `.audiobook`.
    /// Mirrors the fixtures in `LCPAcquisitionPredicateTests`; a plain
    /// `application/audiobook+lcp` acquisition does NOT satisfy the predicate.
    private func makeLCPAudiobook() -> TPPBook {
        let lcpLicenseMIME = "application/vnd.readium.lcp.license.v1.0+json"
        let audiobookLCPMIME = "application/audiobook+lcp"
        let acquisition = TPPOPDSAcquisition(
            relation: .generic,
            type: lcpLicenseMIME,
            hrefURL: URL(string: "https://library.test/book.lcpl")!,
            indirectAcquisitions: [
                TPPOPDSIndirectAcquisition(type: audiobookLCPMIME, indirectAcquisitions: [])
            ],
            availability: TPPOPDSAcquisitionAvailabilityUnlimited()
        )
        return TPPBook(
            acquisitions: [acquisition],
            authors: [],
            categoryStrings: [],
            distributor: "Test",
            identifier: UUID().uuidString,
            imageURL: nil,
            imageThumbnailURL: nil,
            published: Date(),
            publisher: "Test",
            subtitle: nil,
            summary: nil,
            title: "Test LCP Audiobook",
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

    /// Builds an LCP audiobook whose `.lcpl` license is on disk (so the
    /// license-lookup guard passes) and whose `.lcpa` content is absent (so the
    /// fileExists guard passes), i.e. the exact license-only state the
    /// re-download exists to repair.
    private func seedLicenseOnlyLCPAudiobook() throws -> TPPBook {
        let book = makeLCPAudiobook()
        seedBook(book)
        let contentURL = bookFileManager.fakeURLFor(book)
        let licenseURL = contentURL.deletingPathExtension().appendingPathExtension("lcpl")
        try writeFile(at: licenseURL, bytes: 2569)
        XCTAssertFalse(FileManager.default.fileExists(atPath: contentURL.path),
                       "precondition: content must be absent for the re-download to run")
        return book
    }

    private func makeService(
        fulfiller: SpyLCPContentFulfiller,
        reporter: SpyProgressReporter? = nil,
        idleTimeout: TimeInterval = LocalBookContentService.inflightContentDownloadIdleTimeout,
        clock: FakeClock? = nil
    ) -> LocalBookContentService {
        let service = LocalBookContentService(
            bookRegistry: registry,
            accountsManager: appContainer.accountsManager,
            bookFileManager: bookFileManager,
            lcpContentFulfiller: fulfiller.fulfill,
            inflightIdleTimeout: idleTimeout,
            monotonicClock: clock.map { c in { c.now } }
        )
        service.contentDownloadReporter = reporter
        return service
    }

    // MARK: - Claim lifetime: idle expiry, heartbeat, token-matched release
    //
    // The first version of this guard held a claim for the process lifetime, so
    // a dropped completion wedged the book forever. The second sized the window
    // to the open gate's 180s ceiling as a TOTAL duration — which every title
    // this change was measured against exceeds, so a healthy transfer aged out
    // of its own slot and the next Listen started a duplicate: the exact defect
    // the guard exists to prevent. It is now an IDLE window with a heartbeat.

    func testClaim_silentPastTheIdleWindow_isReclaimed() throws {
        let book = try seedLicenseOnlyLCPAudiobook()
        let fulfiller = SpyLCPContentFulfiller()
        let clock = FakeClock()
        let service = makeService(fulfiller: fulfiller, idleTimeout: 180, clock: clock)

        service.redownloadLCPContentFile(for: book)
        XCTAssertEqual(fulfiller.callCount, 1)

        // No progress, no completion — the transfer is silent. Advance past the
        // idle window rather than sleeping through it.
        clock.advance(seconds: 200)
        service.redownloadLCPContentFile(for: book)

        XCTAssertEqual(fulfiller.callCount, 2,
                       "a transfer that has gone silent past the idle window must be reclaimable, or a dropped callback wedges the book permanently")
    }

    func testClaim_heartbeatedByProgress_isNOTReclaimed() throws {
        let book = try seedLicenseOnlyLCPAudiobook()
        let fulfiller = SpyLCPContentFulfiller()
        let clock = FakeClock()
        let service = makeService(fulfiller: fulfiller, idleTimeout: 180, clock: clock)

        service.redownloadLCPContentFile(for: book)
        XCTAssertEqual(fulfiller.callCount, 1)

        // A long but healthy transfer: total elapsed far exceeds the window,
        // but it keeps reporting progress throughout.
        // Total elapsed far exceeds the window, but it keeps reporting.
        for _ in 0..<6 {
            clock.advance(seconds: 60)
            fulfiller.emitProgress(0.1)
        }

        service.redownloadLCPContentFile(for: book)

        XCTAssertEqual(fulfiller.callCount, 1,
                       "a live transfer must never age out of its own slot — that is what turned a 1.9 GB download into two")
    }

    func testRelease_fromAReclaimedTransfer_doesNotFreeTheSuccessorsSlot() throws {
        let book = try seedLicenseOnlyLCPAudiobook()
        let first = SpyLCPContentFulfiller()
        let clock = FakeClock()
        let service = makeService(fulfiller: first, idleTimeout: 180, clock: clock)

        service.redownloadLCPContentFile(for: book)
        clock.advance(seconds: 200)
        service.redownloadLCPContentFile(for: book)   // reclaimed by a second transfer
        XCTAssertEqual(first.callCount, 2)

        // The ABANDONED first transfer finally reports back.
        first.finishWithError(NSError(domain: "test", code: 1), callIndex: 0)

        XCTAssertTrue(service.isContentDownloadInFlight(for: book.identifier),
                      "a late completion from a reclaimed transfer must not release the slot its successor holds, or a third duplicate can start")
    }

    func testRedownload_whileFirstTransferInFlight_doesNotStartADuplicate() throws {
        let book = try seedLicenseOnlyLCPAudiobook()
        let fulfiller = SpyLCPContentFulfiller()
        let service = makeService(fulfiller: fulfiller)

        // Self-heal fires at launch...
        service.redownloadLCPContentFile(for: book)
        // ...then the patron taps Listen mid-transfer, which hits the same seam.
        service.redownloadLCPContentFile(for: book)
        service.redownloadLCPContentFile(for: book)

        XCTAssertEqual(fulfiller.callCount, 1,
                       "a transfer already in flight must not be duplicated — this is the 2x-bandwidth defect")
        XCTAssertTrue(service.isContentDownloadInFlight(for: book.identifier))
    }

    func testRedownload_afterTransferCompletes_allowsAFreshDownload() throws {
        let book = try seedLicenseOnlyLCPAudiobook()
        let fulfiller = SpyLCPContentFulfiller()
        let service = makeService(fulfiller: fulfiller)

        service.redownloadLCPContentFile(for: book)
        // Finish with a fulfillment error so no content lands and the
        // `fileExists` guard stays open — isolating the in-flight release.
        fulfiller.finishWithError(NSError(domain: "test", code: 1))

        XCTAssertFalse(service.isContentDownloadInFlight(for: book.identifier),
                       "the slot must be released on the error path or the book can never retry")

        service.redownloadLCPContentFile(for: book)

        XCTAssertEqual(fulfiller.callCount, 2,
                       "once the previous transfer has ended a fresh download must be allowed")
    }

    /// A self-heal that SUCCEEDS must promote the record. Reconciliation moved the
    /// book to `.downloadNeeded` on finding a license with no content, and `load()`
    /// is the ONLY reconciler — it runs at launch, from CarPlay bootstrap and on
    /// no-auth holds changes, but NOT on foreground. Without promotion a fully
    /// downloaded audiobook keeps offering "Download" until the next cold launch,
    /// and every 3.2.0-3.2.2 audiobook marked successful at license time lands in
    /// that state on first 3.2.3 launch.
    func testRedownload_onSuccess_promotesTheRecordToDownloadSuccessful() throws {
        let book = try seedLicenseOnlyLCPAudiobook()
        registry.setState(.downloadNeeded, for: book.identifier)
        let fulfiller = SpyLCPContentFulfiller()
        let service = makeService(fulfiller: fulfiller)

        service.redownloadLCPContentFile(for: book)
        let landed = try writeFile(at: tempDir.appendingPathComponent("landed-\(UUID().uuidString).lcpa"))
        fulfiller.finishWithSuccess(localURL: landed)

        XCTAssertEqual(
            registry.state(for: book.identifier), .downloadSuccessful,
            "content landed but the shelf still offers Download — the patron re-downloads a book they already have"
        )
    }

    /// Must not overwrite a terminal state a concurrent path already set.
    func testRedownload_onSuccess_doesNotOverwriteATerminalState() throws {
        let book = try seedLicenseOnlyLCPAudiobook()
        registry.setState(.used, for: book.identifier)
        let fulfiller = SpyLCPContentFulfiller()
        let service = makeService(fulfiller: fulfiller)

        service.redownloadLCPContentFile(for: book)
        let landed = try writeFile(at: tempDir.appendingPathComponent("landed-\(UUID().uuidString).lcpa"))
        fulfiller.finishWithSuccess(localURL: landed)

        XCTAssertEqual(registry.state(for: book.identifier), .used,
                       "a book the patron is already listening to must not be reset by a background re-fetch")
    }

    func testRedownload_whenFileMoveFails_stillReleasesTheSlot() throws {
        let book = try seedLicenseOnlyLCPAudiobook()
        let fulfiller = SpyLCPContentFulfiller()
        let service = makeService(fulfiller: fulfiller)

        service.redownloadLCPContentFile(for: book)
        // Completion reports success but points at a file that does not exist,
        // so `moveItem` throws — the third exit path out of the callback.
        fulfiller.finishWithSuccess(localURL: tempDir.appendingPathComponent("does-not-exist.lcpa"))

        XCTAssertFalse(service.isContentDownloadInFlight(for: book.identifier),
                       "a failed move must not leak the in-flight slot")
    }

    func testRedownload_whenContentAlreadyOnDisk_doesNotTransferAtAll() throws {
        let book = makeLCPAudiobook()
        seedBook(book)
        let contentURL = bookFileManager.fakeURLFor(book)
        let licenseURL = contentURL.deletingPathExtension().appendingPathExtension("lcpl")
        try writeFile(at: licenseURL, bytes: 2569)
        try writeFile(at: contentURL, bytes: 4096)

        let fulfiller = SpyLCPContentFulfiller()
        let service = makeService(fulfiller: fulfiller)

        service.redownloadLCPContentFile(for: book)

        XCTAssertEqual(fulfiller.callCount, 0,
                       "content already on disk must short-circuit before any transfer starts")
    }

    func testRedownload_withoutLicenseOnDisk_doesNotTransfer() throws {
        let book = makeLCPAudiobook()
        seedBook(book)
        // No .lcpl written — nothing to fulfill from.
        let fulfiller = SpyLCPContentFulfiller()
        let service = makeService(fulfiller: fulfiller)

        service.redownloadLCPContentFile(for: book)

        XCTAssertEqual(fulfiller.callCount, 0,
                       "with no license on disk there is nothing to re-fulfill")
    }

    func testRedownload_nonLCPAudiobook_doesNotTransfer() throws {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        seedBook(book)
        let fulfiller = SpyLCPContentFulfiller()
        let service = makeService(fulfiller: fulfiller)

        service.redownloadLCPContentFile(for: book)

        XCTAssertEqual(fulfiller.callCount, 0,
                       "this path is LCP-audiobook only")
    }

    // MARK: - redownloadLCPContentFile: progress reporting
    //
    // Before this, progress was discarded (`progress: { _ in }`), so the
    // half-sheet had nothing to draw for a multi-gigabyte transfer and patrons
    // read the silence as a failure.

    /// The wiring itself. `MyBooksDownloadCenter` assigns the reporter to the
    /// content service after `init` (the service is built earlier in that
    /// initializer than the reporter is). Both halves of the progress cue are
    /// otherwise tested with a hand-injected reporter, so deleting that one
    /// assignment line would silently kill the whole feature with every unit
    /// test still green.
    func testDownloadCenter_wiresItsReporterIntoTheContentService() {
        let center = appContainer.downloadCenter

        XCTAssertNotNil(center.localContentService.contentDownloadReporter,
                        "MyBooksDownloadCenter must wire its progress reporter into the content service, or the LCP content download reports to nothing")
        XCTAssertTrue(center.localContentService.contentDownloadReporter === center.progressReporter,
                      "it must be the SAME reporter the rest of the download center publishes through")
    }

    /// The `downloadCenterHasTransfer` BRANCH. This is not belt-and-braces:
    /// `AudiobookSessionManager` calls `redownloadLCPContentFile` DIRECTLY, never
    /// through reconciliation, so on the Listen-tap-during-fulfillment route this
    /// gate is the only thing standing between the patron and a second copy of the
    /// archive — the measured 2 x 778 MB defect.
    func testRedownload_whenTheDownloadCenterIsAlreadyTransferring_doesNotStartASecond() throws {
        let book = try seedLicenseOnlyLCPAudiobook()
        let fulfiller = SpyLCPContentFulfiller()
        let service = makeService(fulfiller: fulfiller)
        service.downloadCenterHasTransfer = { _ in true }

        service.redownloadLCPContentFile(for: book)

        XCTAssertEqual(fulfiller.callCount, 0,
                       "the fulfillment handler is already transferring this archive; a second fetch doubles the patron's data")
    }

    /// Scoped per book — another title's transfer must not block this recovery.
    func testRedownload_whenAnotherBookIsTransferring_stillStarts() throws {
        let book = try seedLicenseOnlyLCPAudiobook()
        let fulfiller = SpyLCPContentFulfiller()
        let service = makeService(fulfiller: fulfiller)
        service.downloadCenterHasTransfer = { $0 != book.identifier }

        service.redownloadLCPContentFile(for: book)

        XCTAssertEqual(fulfiller.callCount, 1,
                       "an unrelated transfer must not strand this book without its content")
    }

    // MARK: - The post-init wiring
    //
    // Each of these is a single assignment in `MyBooksDownloadCenter.init`, and
    // every behavioural test above injects the seam by hand. Without these, any
    // one of those lines could be deleted with the entire suite still green — the
    // inert-guard shape this branch has already paid for repeatedly.

    /// All three post-init assignments, asserted in ONE test.
    ///
    /// Deliberately not three tests: each would stand up its own
    /// `MyBooksDownloadCenter` graph in `setUp`, and measured against the previous
    /// tip that extra construction cost was enough to tip unrelated deadline-poll
    /// suites into failure under parallel clones (three clean full runs before,
    /// two red after). Coverage is unchanged — deleting any one of the three
    /// assignments still fails this test.
    ///
    /// The assertions are behavioural, not non-nil: a probe is registered in the
    /// real reporter and each consumer must SEE it, so a closure wired to the
    /// wrong registry fails too.
    func testDownloadCenter_wiresTheLCPTransferRegistryIntoEveryConsumer() {
        let center = appContainer.downloadCenter
        let probe = "wiring-probe-\(UUID().uuidString)"

        XCTAssertNotNil(center.localContentService.downloadCenterHasTransfer,
                        "the content service must be able to ask about live transfers — on the Listen-tap route this is the only duplicate-download defence")
        XCTAssertNotNil(center.startCoordinator.hasActiveLCPContentTransfer,
                        "a patron tap must be gated on live transfers, or it starts a second archive fetch")
        XCTAssertTrue(center.cancellationHandler.progressReporter === center.progressReporter,
                      "cancel must be able to release the registration — Readium never reports a cancelled transfer")

        center.progressReporter.sendLCPContentDownloadActive(bookIdentifier: probe, active: true)
        defer { center.progressReporter.clearLCPContentTransfer(for: probe) }

        XCTAssertEqual(center.localContentService.downloadCenterHasTransfer?(probe), true,
                       "the content service's closure must consult the SAME registry the fulfillment path registers into")
        XCTAssertEqual(center.startCoordinator.hasActiveLCPContentTransfer?(probe), true,
                       "the manual-start gate must consult the SAME registry")
    }

    func testRedownload_reportsActiveThenProgressThenIdle() throws {
        let book = try seedLicenseOnlyLCPAudiobook()
        let fulfiller = SpyLCPContentFulfiller()
        let reporter = SpyProgressReporter()
        let service = makeService(fulfiller: fulfiller, reporter: reporter)

        service.redownloadLCPContentFile(for: book)
        XCTAssertEqual(reporter.activity, [true],
                       "the UI cue must open when the transfer starts")

        fulfiller.emitProgress(0.25)
        fulfiller.emitProgress(0.75)
        XCTAssertEqual(reporter.progress.map(\.1), [0.25, 0.75],
                       "real transfer progress must reach the reporter, not be discarded")
        XCTAssertEqual(Set(reporter.progress.map(\.0)), [book.identifier])

        fulfiller.finishWithError(NSError(domain: "test", code: 1))
        XCTAssertEqual(reporter.activity, [true, false],
                       "the cue must close on failure too, or the bar would hang forever")
    }

#endif
}

/// Deterministic monotonic clock for the claim-lifetime tests.
private final class FakeClock {
    private(set) var now: UInt64 = 1_000_000_000
    func advance(seconds: TimeInterval) {
        now &+= UInt64(seconds * 1_000_000_000)
    }
}

// MARK: - Test fakes

#if LCP

/// Stands in for the `LCPLibraryService.fulfill` call so the in-flight guard and
/// the progress plumbing can be driven deterministically. The test decides when
/// (and whether) the transfer completes, which is the only way to observe that
/// the slot is held for the duration and released afterwards.
private final class SpyLCPContentFulfiller {
    private(set) var callCount = 0
    private(set) var lastLicenseURL: URL?
    /// Retained PER CALL, not just the latest. A reclaimed transfer's callback
    /// must be firable after its successor has started, which is the only way to
    /// exercise token-matched release.
    private var progressHandlers: [(Double) -> Void] = []
    private var completionHandlers: [(URL?, Error?) -> Void] = []

    private var progressHandler: ((Double) -> Void)? { progressHandlers.last }
    private var completionHandler: ((URL?, Error?) -> Void)? { completionHandlers.last }

    func fulfill(
        licenseURL: URL,
        progress: @escaping (Double) -> Void,
        completion: @escaping (URL?, Error?) -> Void
    ) {
        callCount += 1
        lastLicenseURL = licenseURL
        progressHandlers.append(progress)
        completionHandlers.append(completion)
    }

    /// Fires the completion of the Nth transfer (0-based), so an abandoned
    /// transfer can report back after a successor has claimed the slot.
    func finishWithError(_ error: Error, callIndex: Int) {
        completionHandlers[callIndex](nil, error)
    }

    func emitProgress(_ fraction: Double) {
        progressHandler?(fraction)
    }

    func finishWithError(_ error: Error) {
        completionHandler?(nil, error)
    }

    func finishWithSuccess(localURL: URL) {
        completionHandler?(localURL, nil)
    }
}

/// Records what the service reports so the tests assert on the published
/// signals rather than on internal state.
private final class SpyProgressReporter: DownloadProgressPublishing {
    let downloadProgressPublisher = PassthroughSubject<(String, Double), Never>()
    let downloadErrorPublisher = PassthroughSubject<DownloadErrorInfo, Never>()
    let lcpContentDownloadPublisher = PassthroughSubject<(String, Bool), Never>()

    private(set) var progress: [(String, Double)] = []
    private(set) var activity: [Bool] = []

    func sendProgress(bookIdentifier: String, progress fraction: Double) {
        progress.append((bookIdentifier, fraction))
    }

    func sendLCPContentDownloadActive(bookIdentifier: String, active: Bool) {
        activity.append(active)
        if active {
            active_transfers.insert(bookIdentifier)
        } else {
            active_transfers.remove(bookIdentifier)
        }
    }

    /// Mirrors the real reporter so a caller that consults the registry sees the
    /// same answer the production guard would.
    private var active_transfers = Set<String>()

    func isLCPContentTransferActive(for bookIdentifier: String) -> Bool {
        active_transfers.contains(bookIdentifier)
    }

    func clearLCPContentTransfer(for bookIdentifier: String) {
        active_transfers.remove(bookIdentifier)
    }

    func publishAndAnnounceError(_ errorInfo: DownloadErrorInfo) {}
    func broadcastUpdate() {}
}

#endif

/// BookFileManager subclass that resolves to predictable temp-dir URLs
/// without requiring real per-account directories. Captures the most
/// recent account passed for assertions.
private final class SpyBookFileManager: BookFileManager {
    private let tempDir: URL
    var lastResolvedAccount: String?
    /// Identifier whose lookup should return nil — exercises the
    /// "Could not resolve fileUrl" branch.
    var failResolutionForIdentifier: String?

    init(tempDir: URL, bookRegistry: TPPBookRegistryProvider, accountsManager: AccountsManager) {
        self.tempDir = tempDir
        super.init(
            bookRegistry: bookRegistry,
            accountsManager: accountsManager,
            fileManager: .default
        )
    }

    func fakeURLFor(_ book: TPPBook) -> URL {
        let ext: String
        switch book.defaultBookContentType {
        case .epub: ext = "epub"
        case .pdf: ext = "pdf"
        case .audiobook: ext = "json"
        default: ext = "bin"
        }
        return tempDir.appendingPathComponent(book.identifier).appendingPathExtension(ext)
    }

    override func fileUrl(for book: TPPBook, account: String?) -> URL? {
        lastResolvedAccount = account
        if book.identifier == failResolutionForIdentifier { return nil }
        return fakeURLFor(book)
    }
}
