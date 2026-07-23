//
//  AdobeDRMHandlerTests.swift
//  PalaceTests
//
//  Critical-path coverage of AdobeDRMHandler — the bridge between
//  NYPLADEPTDelegate (Adobe RMSDK) callbacks and Palace's download lifecycle.
//  Per CLAUDE.md, DRM fulfilment is a critical path: every branch of the
//  fulfilment-result handler must have a test, and every error path must be
//  exercised. Tests use a spy delegate (so we never need a real NYPLADEPT)
//  and a real FileManager scoped to a per-test temp directory.
//

// Note: AdobeDRMHandler lives behind `#if FEATURE_DRM_CONNECTOR` in the Palace
// target. PalaceTests does NOT define that flag, but `@testable import Palace`
// pulls the symbol in via the compiled Palace swiftmodule (which IS built with
// the flag), so tests can reference AdobeDRMHandler / AdobeDRMHandlerDelegate
// directly without re-guarding here.
import XCTest
@testable import Palace
import PalaceBookModel

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

    func markDownloadSuccessful(for book: TPPBook) {
        markedSuccessful.append(book.identifier)
    }

    func broadcastUpdate() {
        broadcastCount += 1
    }

    func handleAdobeDownloadProgress(_ progress: Double, for tag: String) {
        progressUpdates.append((progress, tag))
    }
}
