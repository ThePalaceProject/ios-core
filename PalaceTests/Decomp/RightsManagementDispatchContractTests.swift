//
//  RightsManagementDispatchContractTests.swift
//  PalaceTests
//
//  PRE-WAVE test pack for the god-class decomposition campaign
//  (docs/architecture/god-class-decomposition-plan.md §5 row
//  "MyBooksDownloadCenter": "DRM dispatch contract (spy FulfillmentHandling
//  recording call order per format)").
//
//  The post-download DRM/format dispatch that §5 calls "FulfillmentHandling"
//  lives in `Palace/MyBooks/RightsManagementDispatcher.swift`. It is the
//  second half of MBDC's `handleDownloadCompletion` — given the parsed
//  rights-management kind it routes each format to exactly one collaborator:
//
//    .lcp                     → delegate.fulfillLCPLicense       (LCP)
//    .adobe (#if DRM)         → logBookDownloadFailure / Adobe fulfillment
//    .overdriveManifestJSON   → fileOps.replaceBook              (Overdrive)
//    .none                    → fileOps.moveFile                 (open access)
//    .simplifiedBearerTokenJSON → re-issue bearer-auth'd task    (bearer)
//    .unknown                 → logBookDownloadFailure + alert
//
//  A silent decomposition that swapped two arms, dropped an arm, or inverted
//  the `failureRequiringAlert = !fileOps.…` guard would mis-route a paid loan
//  to the wrong DRM handler with no compile error — precisely the money-path
//  regression class this contract pins. Each test locks WHICH collaborator
//  fires for a format AND the alert/error the switch returns.
//
//  Tested through the real seam (RightsManagementDispatcher + its
//  RightsManagementDispatcherDelegate / BackgroundDownloadFileOps spies), so
//  the pins survive the move into PalaceDownloads unchanged.
//

import XCTest
import PalaceCatalog
@testable import Palace

final class RightsManagementDispatchContractTests: XCTestCase {

    private var log: CallLog!
    private var delegate: SpyDispatchDelegate!
    private var fileOps: SpyFileOps!
    private var stateManager: DownloadStateManager!
    private var registry: TPPBookRegistryMock!
    private var userAccount: TPPUserAccountMock!
    private var dispatcher: RightsManagementDispatcher!
    private var session: URLSession!

    override func setUpWithError() throws {
        try super.setUpWithError()
        log = CallLog()
        delegate = SpyDispatchDelegate(log: log)
        fileOps = SpyFileOps(log: log)
        stateManager = DownloadStateManager()
        registry = TPPBookRegistryMock()
        userAccount = TPPUserAccountMock()
        session = URLSession(configuration: .ephemeral)

        #if FEATURE_DRM_CONNECTOR
        // SEAM: RightsManagementDispatcher requires a concrete `AdobeDRMService`
        // and there is no injectable `AdobeDRMService` protocol seam. The
        // `.adobe` PDF-rejection branch under test returns synchronously WITHOUT
        // touching the service (it is only reached on the non-PDF fulfillment
        // path, which is `// SEAM`-noted below), so `.shared` here is a
        // construction placeholder that is never exercised by these tests.
        dispatcher = RightsManagementDispatcher(
            stateManager: stateManager,
            fileOps: fileOps,
            bookRegistry: registry,
            userAccountProvider: { [unowned self] in self.userAccount },
            adobeDRMService: .shared
        )
        #else
        dispatcher = RightsManagementDispatcher(
            stateManager: stateManager,
            fileOps: fileOps,
            bookRegistry: registry,
            userAccountProvider: { [unowned self] in self.userAccount }
        )
        #endif
        dispatcher.delegate = delegate
    }

    override func tearDownWithError() throws {
        log = nil
        delegate = nil
        fileOps = nil
        stateManager = nil
        registry = nil
        userAccount = nil
        dispatcher = nil
        session = nil
        try super.tearDownWithError()
    }

    // MARK: - LCP → fulfillLCPLicense

    /// `.lcp` routes to `delegate.fulfillLCPLicense` and reports NO alert (the
    /// LCP handler owns its own error path). A mutant routing LCP through the
    /// file-move / overdrive arm would drop the license fulfillment entirely,
    /// leaving the patron with an un-decryptable file.
    func test_lcp_routesToFulfillLCPLicense_noAlert() async {
        // VERIFY: `book`/`task` are constructed locally and passed once into the
        // nonisolated async `dispatch` — matching the region-isolation shape the
        // existing DownloadStart contract tests use for non-Sendable TPPBook.
        let book = Self.makeBook(identifier: "RMD-LCP")
        let task = fakeDownloadTask()
        let location = Self.throwawayLocation()

        let result = await dispatcher.dispatch(
            book: book, task: task, location: location, session: session,
            rights: .lcp, failureError: nil
        )

        XCTAssertEqual(log.snapshot().map(\.method), ["delegate.fulfillLCPLicense"])
        XCTAssertFalse(result.failureRequiringAlert)
    }

    // MARK: - Overdrive → fileOps.replaceBook

    /// `.overdriveManifestJSON` routes to `fileOps.replaceBook`. On success
    /// (replaceBook == true) NO alert is required.
    func test_overdriveManifest_routesToReplaceBook_successNoAlert() async {
        fileOps.replaceBookResult = true
        let book = Self.makeBook(identifier: "RMD-OD-OK")
        let task = fakeDownloadTask()

        let result = await dispatcher.dispatch(
            book: book, task: task, location: Self.throwawayLocation(), session: session,
            rights: .overdriveManifestJSON, failureError: nil
        )

        XCTAssertEqual(log.snapshot().map(\.method), ["fileOps.replaceBook"])
        XCTAssertFalse(result.failureRequiringAlert)
    }

    /// Overdrive replace FAILURE (replaceBook == false) → alert required. Kills
    /// the `failureRequiringAlert = !fileOps.replaceBook(…)` negation mutant: a
    /// flipped `!` would silently swallow a failed Overdrive fulfillment.
    func test_overdriveManifest_replaceFails_requiresAlert() async {
        fileOps.replaceBookResult = false
        let book = Self.makeBook(identifier: "RMD-OD-FAIL")
        let task = fakeDownloadTask()

        let result = await dispatcher.dispatch(
            book: book, task: task, location: Self.throwawayLocation(), session: session,
            rights: .overdriveManifestJSON, failureError: nil
        )

        XCTAssertEqual(log.snapshot().map(\.method), ["fileOps.replaceBook"])
        XCTAssertTrue(result.failureRequiringAlert)
    }

    // MARK: - Open access (.none) → fileOps.moveFile

    /// `.none` (open-access / already-decrypted) routes to `fileOps.moveFile`,
    /// NOT replaceBook. Distinct file op — a swap would corrupt the on-disk
    /// layout for one of the two formats.
    func test_openAccess_routesToMoveFile_successNoAlert() async {
        fileOps.moveFileResult = true
        let book = Self.makeBook(identifier: "RMD-OA-OK")
        let task = fakeDownloadTask()

        let result = await dispatcher.dispatch(
            book: book, task: task, location: Self.throwawayLocation(), session: session,
            rights: .none, failureError: nil
        )

        XCTAssertEqual(log.snapshot().map(\.method), ["fileOps.moveFile"])
        XCTAssertFalse(result.failureRequiringAlert)
    }

    /// Open-access move FAILURE → alert required. Kills the negation mutant on
    /// the `.none` arm.
    func test_openAccess_moveFails_requiresAlert() async {
        fileOps.moveFileResult = false
        let book = Self.makeBook(identifier: "RMD-OA-FAIL")
        let task = fakeDownloadTask()

        let result = await dispatcher.dispatch(
            book: book, task: task, location: Self.throwawayLocation(), session: session,
            rights: .none, failureError: nil
        )

        XCTAssertEqual(log.snapshot().map(\.method), ["fileOps.moveFile"])
        XCTAssertTrue(result.failureRequiringAlert)
    }

    // MARK: - Unknown rights → log + alert, error preserved

    /// `.unknown` logs a download failure and requires an alert — and it must
    /// NOT mutate the incoming `failureError` (the caller's original error is
    /// surfaced). Kills both the "drop the log call" mutant and a
    /// `failureRequiringAlert = false` mutant that would strand the patron on a
    /// spinner with no error.
    func test_unknownRights_logsFailure_requiresAlert_preservesError() async {
        let sentinel = NSError(domain: "caller", code: 99)
        let book = Self.makeBook(identifier: "RMD-UNKNOWN")
        let task = fakeDownloadTask()

        let result = await dispatcher.dispatch(
            book: book, task: task, location: Self.throwawayLocation(), session: session,
            rights: .unknown, failureError: sentinel
        )

        XCTAssertEqual(log.snapshot().map(\.method), ["delegate.logBookDownloadFailure"])
        XCTAssertTrue(result.failureRequiringAlert)
        XCTAssertEqual((result.failureError as NSError?)?.code, 99,
                       "unknown-rights arm must not overwrite the caller's error")
    }

    // MARK: - Bearer token JSON → missing-data guard

    /// `.simplifiedBearerTokenJSON` whose payload is absent on disk logs a
    /// failure AND alerts — in that order. Pins the two-call sequence on the
    /// bearer-token error guard (a mutant dropping either call would leave the
    /// re-fulfillment silently stuck). `failureRequiringAlert` stays false
    /// because the bearer arm alerts directly via the delegate rather than
    /// through the shared tail flag.
    func test_bearerTokenJSON_missingData_logsThenAlerts() async {
        let book = Self.makeBook(identifier: "RMD-BEARER")
        let task = fakeDownloadTask()
        // A location that does not exist → `Data(contentsOf:)` returns nil →
        // the "no data available on disk" guard fires.
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rmd-nonexistent-\(UUID().uuidString).bin")

        let result = await dispatcher.dispatch(
            book: book, task: task, location: missing, session: session,
            rights: .simplifiedBearerTokenJSON, failureError: nil
        )

        XCTAssertEqual(log.snapshot().map(\.method),
                       ["delegate.logBookDownloadFailure", "delegate.failDownloadWithAlert"])
        XCTAssertFalse(result.failureRequiringAlert)
    }

    // MARK: - Adobe ACSM (DRM builds only)

    #if FEATURE_DRM_CONNECTOR
    /// `.adobe` payload that is actually an Adobe PDF (`application/pdf` in the
    /// ACSM) is rejected as unsupported — synchronously, before any DRM
    /// fulfillment Task is spawned: it logs a failure, requires an alert, and
    /// surfaces an "Adobe PDF … not supported" error. Kills a mutant that
    /// dropped the PDF guard and shipped the unsupported payload to fulfillment.
    ///
    /// SEAM: the non-PDF `.adobe` branch spawns a fire-and-forget Task on the
    /// concrete `AdobeDRMService` (`ensureDeviceActivated` + `fulfill`) with no
    /// injectable protocol seam — its success/failure is verified on a sim
    /// against an Adept-fulfilled EPUB, not here.
    func test_adobe_pdfPayload_rejectedAsUnsupported() async throws {
        let book = Self.makeBook(identifier: "RMD-ADOBE-PDF")
        let task = fakeDownloadTask()
        // Write an ACSM whose body carries the PDF format marker the guard scans.
        let acsm = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rmd-adobe-\(UUID().uuidString).acsm")
        let body = "<fulfillmentToken><dc:format>application/pdf</dc:format></fulfillmentToken>"
        try body.data(using: .utf8)!.write(to: acsm)
        defer { try? FileManager.default.removeItem(at: acsm) }

        let result = await dispatcher.dispatch(
            book: book, task: task, location: acsm, session: session,
            rights: .adobe, failureError: nil
        )

        XCTAssertEqual(log.snapshot().map(\.method), ["delegate.logBookDownloadFailure"])
        XCTAssertTrue(result.failureRequiringAlert)
        let message = (result.failureError as NSError?)?.localizedDescription ?? ""
        XCTAssertTrue(message.contains("Adobe PDF"),
                      "unsupported-PDF error message must be surfaced; got '\(message)'")
    }
    #endif

    // MARK: - Helpers

    private static func throwawayLocation() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rmd-loc-\(UUID().uuidString).bin")
    }

    private static func makeBook(identifier: String) -> TPPBook {
        let acquisitionURL = URL(string: "http://example.com/\(identifier)")!
        let acquisition = TPPOPDSAcquisition(
            relation: .generic,
            type: "application/epub+zip",
            hrefURL: acquisitionURL,
            indirectAcquisitions: [],
            availability: TPPOPDSAcquisitionAvailabilityUnlimited()
        )
        return TPPBook(
            acquisitions: [acquisition],
            authors: [TPPBookAuthor(authorName: "Author", relatedBooksURL: nil)],
            categoryStrings: nil,
            distributor: nil,
            identifier: identifier,
            imageURL: nil,
            imageThumbnailURL: nil,
            published: nil,
            publisher: nil,
            subtitle: nil,
            summary: nil,
            title: "Title-\(identifier)",
            updated: Date(timeIntervalSince1970: 0),
            annotationsURL: nil,
            analyticsURL: nil,
            alternateURL: nil,
            relatedWorksURL: nil,
            previewLink: nil,
            seriesURL: nil,
            revokeURL: nil,
            reportURL: nil,
            timeTrackingURL: nil,
            contributors: nil,
            bookDuration: nil,
            imageCache: MockImageCache()
        )
    }
}

// MARK: - Spies

/// Records the MBDC-side callbacks the dispatcher invokes. `@unchecked
/// Sendable`: the only state is the (thread-safe) CallLog reference.
private final class SpyDispatchDelegate: RightsManagementDispatcherDelegate, @unchecked Sendable {
    let log: CallLog
    init(log: CallLog) { self.log = log }

    func logBookDownloadFailure(_ book: TPPBook, reason: String, downloadTask: URLSessionTask, metadata: [String: Any]?) {
        log.record("delegate.logBookDownloadFailure",
                   args: ["bookId": book.identifier, "reason": reason])
    }

    func fulfillLCPLicense(fileUrl: URL, forBook book: TPPBook, downloadTask: URLSessionDownloadTask) {
        log.record("delegate.fulfillLCPLicense", args: ["bookId": book.identifier])
    }

    func failDownloadWithAlert(for book: TPPBook, withMessage message: String?) {
        log.record("delegate.failDownloadWithAlert", args: ["bookId": book.identifier])
    }

    func alertForProblemDocument(_ problemDoc: TPPProblemDocument?, error: Error?, book: TPPBook) {
        log.record("delegate.alertForProblemDocument", args: ["bookId": book.identifier])
    }
}

/// Stubs `BackgroundDownloadFileOps` with configurable return values so the
/// success/failure branches of the overdrive/open-access arms are both
/// exercisable. `@unchecked Sendable`: return-value `var`s are set on the
/// test thread before the single `dispatch` await; CallLog is thread-safe.
private final class SpyFileOps: BackgroundDownloadFileOps, @unchecked Sendable {
    let log: CallLog
    var replaceBookResult = true
    var moveFileResult = true
    init(log: CallLog) { self.log = log }

    func replaceBook(_ book: TPPBook, withFileAtURL sourceLocation: URL, forDownloadTask downloadTask: URLSessionDownloadTask) -> Bool {
        log.record("fileOps.replaceBook", args: ["bookId": book.identifier])
        return replaceBookResult
    }

    func moveFile(at sourceLocation: URL, toDestinationForBook book: TPPBook, forDownloadTask downloadTask: URLSessionDownloadTask) -> Bool {
        log.record("fileOps.moveFile", args: ["bookId": book.identifier])
        return moveFileResult
    }
}
