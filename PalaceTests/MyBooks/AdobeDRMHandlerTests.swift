//
//  AdobeDRMHandler bridges NYPLADEPTDelegate callbacks to the download lifecycle;
//  every branch and error path of the fulfilment-result handler is exercised with
//  a spy delegate and a per-test temp directory. AdobeDRMHandler is behind
//  `#if FEATURE_DRM_CONNECTOR`, reachable via `@testable import Palace` because
//  the Palace module is built with that flag.
//

import XCTest
@testable import Palace
import PalaceBookModel
import PalaceBookRegistry

@MainActor
final class AdobeDRMHandlerTests: XCTestCase {

    private var registry: TPPBookRegistryMock!
    private var spy: SpyDRMDelegate!
    private var handler: AdobeDRMHandler!
    private var book: TPPBook!
    private var tempDir: URL!
    private var sourceFileURL: URL!
    private var destFileURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        registry = TPPBookRegistryMock()
        book = TPPBookMocker.mockBook(identifier: "adobe-book-1", title: "Adobe Test Title", distributorType: .EpubZip)
        registry.addBook(book, state: .downloading)

        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AdobeDRMHandlerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        sourceFileURL = tempDir.appendingPathComponent("adobe-source.epub")
        destFileURL = tempDir.appendingPathComponent("adobe-dest.epub")
        try Data("source-bytes".utf8).write(to: sourceFileURL)

        spy = SpyDRMDelegate(bookRegistry: registry, destURL: destFileURL)
        handler = AdobeDRMHandler(delegate: spy)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        registry = nil
        spy = nil
        handler = nil
        book = nil
        tempDir = nil
        sourceFileURL = nil
        destFileURL = nil
        try super.tearDownWithError()
    }

    // MARK: - Happy Path

    func testHandleFulfillment_didFinishCopySucceeded_marksSuccessfulAndPersistsRights() throws {
        let rightsData = Data("<rights>xml</rights>".utf8)

        handler.handleFulfillmentResult(
            didFinishDownload: true,
            to: sourceFileURL,
            fulfillmentID: "fulfill-42",
            isReturnable: true,
            rightsData: rightsData,
            tag: book.identifier,
            adeptError: nil
        )

        XCTAssertEqual(spy.markedSuccessful, [book.identifier], "Successful fulfilment must mark the book downloadSuccessful.")
        XCTAssertEqual(spy.broadcastCount, 1, "Successful fulfilment must broadcast exactly one update.")
        XCTAssertEqual(spy.failed, [], "Happy path must not invoke failDownloadWithAlert.")
        XCTAssertEqual(registry.fulfillmentId(forIdentifier: book.identifier), "fulfill-42", "Returnable book must persist its Adobe fulfilment ID.")

        XCTAssertTrue(FileManager.default.fileExists(atPath: destFileURL.path), "Adobe-fulfilled file must be copied to the destination.")
        let rightsFileURL = URL(fileURLWithPath: destFileURL.path.appending("_rights.xml"))
        XCTAssertEqual(try Data(contentsOf: rightsFileURL), rightsData, "Rights data must be persisted next to the fulfilled file.")
    }

    func testHandleFulfillment_nonReturnable_skipsFulfillmentIdPersistence() {
        handler.handleFulfillmentResult(
            didFinishDownload: true,
            to: sourceFileURL,
            fulfillmentID: "fulfill-77",
            isReturnable: false,
            rightsData: Data("<r/>".utf8),
            tag: book.identifier,
            adeptError: nil
        )

        XCTAssertEqual(spy.markedSuccessful, [book.identifier])
        XCTAssertNil(registry.fulfillmentId(forIdentifier: book.identifier), "Non-returnable books must not persist a fulfilment ID — that's how the registry knows not to offer return.")
    }

    func testHandleFulfillment_returnableButNoFulfillmentID_skipsPersistence() {
        handler.handleFulfillmentResult(
            didFinishDownload: true,
            to: sourceFileURL,
            fulfillmentID: nil,
            isReturnable: true,
            rightsData: Data("<r/>".utf8),
            tag: book.identifier,
            adeptError: nil
        )

        XCTAssertEqual(spy.markedSuccessful, [book.identifier])
        XCTAssertNil(registry.fulfillmentId(forIdentifier: book.identifier), "Missing fulfilment ID can't be persisted — guard against writing nil.")
    }

    // MARK: - Failure Branches

    func testHandleFulfillment_didFinishDownloadFalse_failsAndDoesNotMarkSuccessful() {
        handler.handleFulfillmentResult(
            didFinishDownload: false,
            to: sourceFileURL,
            fulfillmentID: "fulfill-99",
            isReturnable: true,
            rightsData: Data("<r/>".utf8),
            tag: book.identifier,
            adeptError: NSError(domain: "ADEPT", code: 1, userInfo: nil)
        )

        XCTAssertEqual(spy.failed, [book.identifier], "didFinishDownload=false must invoke failDownloadWithAlert.")
        XCTAssertEqual(spy.markedSuccessful, [], "Failure path must not mark the book successful.")
        XCTAssertEqual(spy.broadcastCount, 0, "Failure path must not broadcast a successful update.")
        XCTAssertNil(registry.fulfillmentId(forIdentifier: book.identifier), "Failure path must not persist a fulfilment ID.")
    }

    func testHandleFulfillment_missingDestinationURL_failsWithAlert() {
        spy.destURLOverride = nil  // delegate returns nil for fileUrl(for:)

        handler.handleFulfillmentResult(
            didFinishDownload: true,
            to: sourceFileURL,
            fulfillmentID: "fulfill-1",
            isReturnable: true,
            rightsData: Data("<r/>".utf8),
            tag: book.identifier,
            adeptError: nil
        )

        // With nil dest URL, the handler returns early at the first fileUrl
        // check — no fail-with-alert, no markSuccessful, no broadcast.
        XCTAssertEqual(spy.markedSuccessful, [])
        XCTAssertEqual(spy.failed, [])
        XCTAssertEqual(spy.broadcastCount, 0)
    }

    func testHandleFulfillment_missingAdeptToURL_failsWithAlert() {
        handler.handleFulfillmentResult(
            didFinishDownload: true,
            to: nil,
            fulfillmentID: "fulfill-1",
            isReturnable: true,
            rightsData: Data("<r/>".utf8),
            tag: book.identifier,
            adeptError: nil
        )

        XCTAssertEqual(spy.failed, [book.identifier], "Missing adeptToURL must invoke failDownloadWithAlert.")
        XCTAssertEqual(spy.markedSuccessful, [])
    }

    func testHandleFulfillment_copyFailure_failsWithAlert() {
        let nonExistentSource = tempDir.appendingPathComponent("does-not-exist.epub")

        handler.handleFulfillmentResult(
            didFinishDownload: true,
            to: nonExistentSource,
            fulfillmentID: "fulfill-1",
            isReturnable: true,
            rightsData: Data("<r/>".utf8),
            tag: book.identifier,
            adeptError: nil
        )

        XCTAssertEqual(spy.failed, [book.identifier], "Copy-failure (source missing) must invoke failDownloadWithAlert.")
        XCTAssertEqual(spy.markedSuccessful, [])
    }

    // MARK: - Guards

    func testHandleFulfillment_unknownBookIdentifier_returnsEarlyWithoutSideEffects() {
        handler.handleFulfillmentResult(
            didFinishDownload: true,
            to: sourceFileURL,
            fulfillmentID: "fulfill-1",
            isReturnable: true,
            rightsData: Data("<r/>".utf8),
            tag: "not-in-registry",
            adeptError: nil
        )

        XCTAssertEqual(spy.markedSuccessful, [], "Unknown book must not be marked successful.")
        XCTAssertEqual(spy.failed, [], "Unknown book must not trigger an alert — there's no book to alert about.")
        XCTAssertEqual(spy.broadcastCount, 0)
    }

    func testHandleFulfillment_undecodableRightsData_returnsEarlyWithoutSideEffects() {
        // 0xC0 is invalid as a leading UTF-8 byte
        let invalidUTF8 = Data([0xC0, 0xC1, 0xFE])

        handler.handleFulfillmentResult(
            didFinishDownload: true,
            to: sourceFileURL,
            fulfillmentID: "fulfill-1",
            isReturnable: true,
            rightsData: invalidUTF8,
            tag: book.identifier,
            adeptError: nil
        )

        XCTAssertEqual(spy.markedSuccessful, [], "Undecodable rights data must abort fulfilment — we never want to claim success on corrupt rights.")
        XCTAssertEqual(spy.failed, [])
    }

    /// A Return leaves the record in the registry at `.unregistered`, so the
    /// book lookup still succeeds and the rest of fulfilment would run. Shelving
    /// there takes `.unregistered` to `.downloadSuccessful`, which is not a legal
    /// transition, and leaves DRM content for a loan the patron gave back.
    func testHandleFulfillment_bookReturnedBeforeAdobeFinished_doesNotShelveOrMarkSuccessful() throws {
        let alreadyThere = Data("content-the-patron-still-has".utf8)
        try alreadyThere.write(to: destFileURL)
        registry.setState(.unregistered, for: book.identifier)

        handler.handleFulfillmentResult(
            didFinishDownload: true,
            to: sourceFileURL,
            fulfillmentID: "fulfill-after-return",
            isReturnable: true,
            rightsData: Data("<r/>".utf8),
            tag: book.identifier,
            adeptError: nil
        )

        XCTAssertEqual(spy.markedSuccessful, [], "A loan that ended must not be marked downloadSuccessful.")
        XCTAssertEqual(spy.failed, [], "Discarding a returned book's fulfilment is not a download failure to show the patron.")
        XCTAssertNil(registry.fulfillmentId(forIdentifier: book.identifier), "A returned book must not gain a fulfilment ID.")
        XCTAssertEqual(registry.registry[book.identifier]?.state, .unregistered, "The discard must leave the returned state alone.")
        XCTAssertEqual(try Data(contentsOf: destFileURL), alreadyThere, "The discard must not touch what is already at the destination.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceFileURL.path), "Adobe's temp file must not be left behind by the discard.")
    }

    /// `.returning` is the same loan a moment earlier: the cleanup is in flight,
    /// so writing here re-creates exactly what it is deleting.
    func testHandleFulfillment_returnInFlight_doesNotShelveOrMarkSuccessful() {
        registry.setState(.returning, for: book.identifier)

        handler.handleFulfillmentResult(
            didFinishDownload: true,
            to: sourceFileURL,
            fulfillmentID: "fulfill-mid-return",
            isReturnable: true,
            rightsData: Data("<r/>".utf8),
            tag: book.identifier,
            adeptError: nil
        )

        XCTAssertEqual(spy.markedSuccessful, [])
        XCTAssertEqual(spy.failed, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: destFileURL.path), "A return in flight must not leave content at the destination.")
    }

    /// The counterpart that keeps the guard honest: a hold is not a loan either,
    /// so a fulfilment landing against one is discarded the same way.
    func testHandleFulfillment_bookOnHold_doesNotShelveOrMarkSuccessful() {
        registry.setState(.holding, for: book.identifier)

        handler.handleFulfillmentResult(
            didFinishDownload: true,
            to: sourceFileURL,
            fulfillmentID: "fulfill-hold",
            isReturnable: true,
            rightsData: Data("<r/>".utf8),
            tag: book.identifier,
            adeptError: nil
        )

        XCTAssertEqual(spy.markedSuccessful, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: destFileURL.path))
    }

    /// The event dimension of the same guard: the transfer failed AND the loan
    /// was already over. No alert, because a download-failed prompt for a
    /// returned book is not actionable, and nothing shelved. `to: nil` drives
    /// the discard's own nil binding at the same time.
    func testHandleFulfillment_transferFailedAfterReturn_isSilentAndShelvesNothing() {
        registry.setState(.unregistered, for: book.identifier)

        handler.handleFulfillmentResult(
            didFinishDownload: false,
            to: nil,
            fulfillmentID: "fulfill-failed-after-return",
            isReturnable: true,
            rightsData: Data("<r/>".utf8),
            tag: book.identifier,
            adeptError: NSError(domain: "ADEPT", code: 7, userInfo: nil)
        )

        XCTAssertEqual(spy.markedSuccessful, [], "A failed transfer for a returned loan must not be marked successful.")
        XCTAssertEqual(spy.failed, [], "A returned book must not raise a download-failed alert.")
        XCTAssertEqual(registry.registry[book.identifier]?.state, .unregistered, "The silent discard must leave the returned state alone.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destFileURL.path), "Nothing may be written for a loan that ended.")
    }

    /// The discard removes Adobe's temp file with `try?`. A FileManager that
    /// throws there must not change the outcome: the book still is not shelved.
    /// Without this, a later `try!` would crash on a path nothing exercises.
    func testHandleFulfillment_returnedAndTempFileCannotBeRemoved_stillDiscards() {
        registry.setState(.unregistered, for: book.identifier)

        handler.handleFulfillmentResult(
            didFinishDownload: true,
            to: sourceFileURL,
            fulfillmentID: "fulfill-undeletable",
            isReturnable: true,
            rightsData: Data("<r/>".utf8),
            tag: book.identifier,
            adeptError: nil,
            fileManager: RemoveRefusingFileManager()
        )

        XCTAssertEqual(spy.markedSuccessful, [], "A failing cleanup must not turn the discard into a shelve.")
        XCTAssertEqual(registry.registry[book.identifier]?.state, .unregistered)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destFileURL.path))
    }

    // MARK: - Cancellation

    func testHandleCancellation_setsRegistryStateAndBroadcasts() {
        handler.handleCancellation(tag: book.identifier)

        XCTAssertEqual(registry.registry[book.identifier]?.state, .downloadNeeded, "Cancellation must set the registry state back to .downloadNeeded so the user can retry.")
        XCTAssertEqual(spy.broadcastCount, 1, "Cancellation must broadcast so listeners refresh.")
    }

    // MARK: - No Authorization

    func testHandleNoAuthorization_doesNotMutateRegistryOrAlert() {
        // book was added to the registry in setUp with state .downloading; no-auth must leave it untouched.
        handler.handleNoAuthorization()

        XCTAssertEqual(spy.markedSuccessful, [])
        XCTAssertEqual(spy.failed, [])
        XCTAssertEqual(spy.broadcastCount, 0)
        XCTAssertEqual(registry.registry[book.identifier]?.state, .downloading, "No-authorization (post-PP-3649) is purely diagnostic — must not change registry or surface UI.")
    }

    // MARK: - Progress Forwarding

    func testProgressForwarding_invokesDelegateWithProgressAndTag() {
        handler.handleProgress(0.5, for: book.identifier)

        XCTAssertEqual(spy.progressUpdates.count, 1)
        XCTAssertEqual(spy.progressUpdates.first?.0 ?? -1, 0.5, accuracy: 0.0001)
        XCTAssertEqual(spy.progressUpdates.first?.1, book.identifier)
    }
}

// MARK: - Fault injection

/// Refuses every removal so the `try?` in the discard arm is exercised rather
/// than assumed harmless.
private final class RemoveRefusingFileManager: FileManager {
    override func removeItem(at URL: URL) throws {
        throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError, userInfo: nil)
    }
}

// MARK: - SpyDRMDelegate

private final class SpyDRMDelegate: AdobeDRMHandlerDelegate {

    let bookRegistry: TPPBookRegistryProvider
    var destURLOverride: URL?

    private(set) var markedSuccessful: [String] = []
    private(set) var failed: [String] = []
    private(set) var broadcastCount: Int = 0
    private(set) var progressUpdates: [(Double, String)] = []

    init(bookRegistry: TPPBookRegistryProvider, destURL: URL?) {
        self.bookRegistry = bookRegistry
        self.destURLOverride = destURL
    }

    func fileUrl(for identifier: String) -> URL? { destURLOverride }

    func failDownloadWithAlert(for book: TPPBook, withMessage message: String?) {
        failed.append(book.identifier)
    }

    /// Mirrors `MyBooksDownloadCenter.markDownloadSuccessful`, which writes the
    /// state as well as announcing. Recording the call alone cannot show the
    /// `.unregistered` to `.downloadSuccessful` move this handler must not make.
    func markDownloadSuccessful(for book: TPPBook) {
        markedSuccessful.append(book.identifier)
        bookRegistry.setState(.downloadSuccessful, for: book.identifier)
    }

    func broadcastUpdate() {
        broadcastCount += 1
    }

    func handleAdobeDownloadProgress(_ progress: Double, for tag: String) {
        progressUpdates.append((progress, tag))
    }
}
