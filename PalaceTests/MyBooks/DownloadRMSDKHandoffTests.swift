//
//  DownloadRMSDKHandoffTests.swift
//  PalaceTests
//
//  Deep mutation-killing coverage for the RMSDK (Adobe DRM) handoff
//  contract: when the URL session downloads an `.acsm` payload, control
//  is handed to the Adobe RMSDK via NYPLADEPTDelegate callbacks. The
//  AdobeDRMHandler then receives `didFinishDownload` with the fulfilled
//  EPUB at a temp URL and is responsible for moving that into the
//  Palace content directory, persisting `rights_xml`, optionally
//  recording the fulfillment ID (when returnable), and marking the
//  registry .downloadSuccessful. Failure modes from RMSDK
//  (`didFinishDownload=false`, missing destination URL, missing source,
//  no-authorization signal, cancellation) must propagate without
//  silently claiming success.
//
//  These tests use a spy delegate (no real NYPLADEPT) and a per-test
//  temp directory. They are guarded by `#if FEATURE_DRM_CONNECTOR`
//  because the production AdobeDRMHandler lives behind that flag. The
//  Palace target compiles with the flag, so `@testable import Palace`
//  exposes the type without us re-defining the guard locally.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

#if FEATURE_DRM_CONNECTOR

final class DownloadRMSDKHandoffTests: XCTestCase {

    private var registry: TPPBookRegistryMock!
    private var spy: RMSDKHandoffSpy!
    private var handler: AdobeDRMHandler!
    private var book: TPPBook!
    private var tempDir: URL!
    private var acsmFulfilledURL: URL!
    private var contentDestURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()

        registry = TPPBookRegistryMock()
        book = TPPBookMocker.mockBook(identifier: "rmsdk-handoff-1", title: "RMSDK Handoff Title", distributorType: .EpubZip)
        registry.addBook(book, state: .downloading)

        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RMSDKHandoffTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // The "RMSDK fulfilled" payload: a fully-resolved EPUB at a temp URL.
        acsmFulfilledURL = tempDir.appendingPathComponent("acsm-fulfilled.epub")
        contentDestURL = tempDir.appendingPathComponent("content-dest.epub")
        try Data("epub-payload".utf8).write(to: acsmFulfilledURL)

        spy = RMSDKHandoffSpy(bookRegistry: registry, destURL: contentDestURL)
        handler = AdobeDRMHandler(delegate: spy)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        registry = nil
        spy = nil
        handler = nil
        book = nil
        tempDir = nil
        acsmFulfilledURL = nil
        contentDestURL = nil
        try super.tearDownWithError()
    }

    // MARK: - Happy path: full handoff succeeds end-to-end

    /// The full handoff: didFinishDownload=true + valid adeptToURL + valid
    /// destination + parseable rights data + returnable + fulfillment ID.
    /// All side effects must fire: file copied, rights persisted, fulfillment
    /// ID stored, registry advanced. Mutation targets: any one of these
    /// being skipped would be caught.
    func testHandoff_fullSuccessPath_persistsRightsAndFulfillmentID() throws {
        let rightsXML = #"<rights xmlns="urn:adobe:adept" version="1.0"><meta/></rights>"#
        let rightsData = Data(rightsXML.utf8)

        handler.handleFulfillmentResult(
            didFinishDownload: true,
            to: acsmFulfilledURL,
            fulfillmentID: "rmsdk-fulfillment-77",
            isReturnable: true,
            rightsData: rightsData,
            tag: book.identifier,
            adeptError: nil
        )

        XCTAssertEqual(spy.markedSuccessful, [book.identifier],
                       "Successful handoff must mark the book .downloadSuccessful")
        XCTAssertEqual(spy.failed, [],
                       "Successful handoff must not invoke the failure alert path")
        XCTAssertEqual(spy.broadcastCount, 1,
                       "Successful handoff must broadcast exactly one update")
        XCTAssertEqual(registry.fulfillmentId(forIdentifier: book.identifier), "rmsdk-fulfillment-77",
                       "Returnable + fulfillment ID must be persisted in the registry")

        XCTAssertTrue(FileManager.default.fileExists(atPath: contentDestURL.path),
                      "Adobe-fulfilled bytes must end up at the destination URL")
        let rightsFile = URL(fileURLWithPath: contentDestURL.path.appending("_rights.xml"))
        XCTAssertEqual(try Data(contentsOf: rightsFile), rightsData,
                       "rights_xml sidecar must contain the exact rightsData payload")
    }

    // MARK: - RMSDK failure: didFinishDownload=false propagates

    /// RMSDK signalling didFinishDownload=false (the SDK rejected the
    /// fulfilment — e.g. wrong device activation, expired loan). The
    /// failure must propagate via failDownloadWithAlert AND the registry
    /// must NOT be advanced. Mutation target: ignoring the
    /// `didFinishDownload` parameter would mis-claim success.
    func testHandoff_didFinishFalse_propagatesAsFailureAlert() {
        handler.handleFulfillmentResult(
            didFinishDownload: false,
            to: acsmFulfilledURL,
            fulfillmentID: "rmsdk-77",
            isReturnable: true,
            rightsData: Data("<rights/>".utf8),
            tag: book.identifier,
            adeptError: NSError(domain: "ADEPT", code: 502, userInfo: nil)
        )

        XCTAssertEqual(spy.failed, [book.identifier],
                       "RMSDK didFinishDownload=false must propagate to failDownloadWithAlert")
        XCTAssertEqual(spy.markedSuccessful, [],
                       "Failed handoff must NOT mark .downloadSuccessful")
        XCTAssertEqual(spy.broadcastCount, 0,
                       "Failed handoff must NOT broadcast a successful update")
        XCTAssertNil(registry.fulfillmentId(forIdentifier: book.identifier),
                     "Failed handoff must NOT persist a fulfillment ID")
    }

    /// RMSDK fulfilment ID is nil but didFinishDownload=true and book is
    /// returnable: this is a partial success — content lands on disk
    /// (registry advances) but no fulfillment ID is persisted (so the
    /// book won't appear as returnable). Pin this branch.
    func testHandoff_returnableButNoFulfillmentID_marksSuccessfulButSkipsIDPersistence() {
        handler.handleFulfillmentResult(
            didFinishDownload: true,
            to: acsmFulfilledURL,
            fulfillmentID: nil,
            isReturnable: true,
            rightsData: Data("<r/>".utf8),
            tag: book.identifier,
            adeptError: nil
        )

        XCTAssertEqual(spy.markedSuccessful, [book.identifier],
                       "Successful download must still advance registry — nil fulfillment ID is not a failure")
        XCTAssertNil(registry.fulfillmentId(forIdentifier: book.identifier),
                     "Nil fulfillment ID must NOT be persisted (can't persist nil)")
    }

    /// Non-returnable book: fulfillment ID present but not persisted. The
    /// `isReturnable` flag gates the persistence, not the content move.
    /// Mutation target: dropping the `isReturnable` check would over-persist.
    func testHandoff_nonReturnable_skipsFulfillmentIDPersistence() {
        handler.handleFulfillmentResult(
            didFinishDownload: true,
            to: acsmFulfilledURL,
            fulfillmentID: "rmsdk-non-ret-1",
            isReturnable: false,
            rightsData: Data("<r/>".utf8),
            tag: book.identifier,
            adeptError: nil
        )

        XCTAssertEqual(spy.markedSuccessful, [book.identifier],
                       "Non-returnable must still mark .downloadSuccessful")
        XCTAssertNil(registry.fulfillmentId(forIdentifier: book.identifier),
                     "Non-returnable must NOT persist a fulfillment ID — that's the contract")
    }

    /// adeptToURL nil: even with didFinishDownload=true, the handoff cannot
    /// complete because there are no bytes to move. Must surface as a
    /// failure, not a phantom success.
    func testHandoff_missingAdeptToURL_failsWithAlert() {
        handler.handleFulfillmentResult(
            didFinishDownload: true,
            to: nil,
            fulfillmentID: "rmsdk-1",
            isReturnable: true,
            rightsData: Data("<r/>".utf8),
            tag: book.identifier,
            adeptError: nil
        )

        XCTAssertEqual(spy.failed, [book.identifier],
                       "Missing adeptToURL must surface as failDownloadWithAlert")
        XCTAssertEqual(spy.markedSuccessful, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: contentDestURL.path),
                       "No source URL = no content at destination")
    }

    /// Source file deleted between RMSDK callback and our copy — copy
    /// fails, registry not advanced.
    func testHandoff_sourceFileVanishesBeforeCopy_failsWithAlert() throws {
        // Delete the source before invoking the handler.
        try FileManager.default.removeItem(at: acsmFulfilledURL)

        handler.handleFulfillmentResult(
            didFinishDownload: true,
            to: acsmFulfilledURL,
            fulfillmentID: "rmsdk-1",
            isReturnable: true,
            rightsData: Data("<r/>".utf8),
            tag: book.identifier,
            adeptError: nil
        )

        XCTAssertEqual(spy.failed, [book.identifier],
                       "Vanished source before copy must surface as failure")
        XCTAssertEqual(spy.markedSuccessful, [])
    }

    /// Destination URL resolution returns nil (e.g. unknown account).
    /// Handler must early-return: no failure alert, no success, no
    /// broadcast. Pin this guard.
    func testHandoff_destinationURLUnresolvable_silentEarlyReturn() {
        spy.destURLOverride = nil

        handler.handleFulfillmentResult(
            didFinishDownload: true,
            to: acsmFulfilledURL,
            fulfillmentID: "rmsdk-1",
            isReturnable: true,
            rightsData: Data("<r/>".utf8),
            tag: book.identifier,
            adeptError: nil
        )

        XCTAssertEqual(spy.markedSuccessful, [])
        XCTAssertEqual(spy.failed, [])
        XCTAssertEqual(spy.broadcastCount, 0)
    }

    // MARK: - Cancellation handoff: registry flips to .downloadNeeded

    /// User cancels mid-fulfilment: RMSDK fires `didCancelDownloadWithTag`,
    /// the handler must flip the registry back to .downloadNeeded and
    /// broadcast. Mutation target: a no-op cancellation handler would be
    /// caught by both assertions.
    func testHandoff_cancellation_resetsRegistryAndBroadcasts() {
        handler.handleCancellation(tag: book.identifier)

        XCTAssertEqual(registry.state(for: book.identifier), .downloadNeeded,
                       "Cancellation must roll back the registry to .downloadNeeded")
        XCTAssertEqual(spy.broadcastCount, 1,
                       "Cancellation must broadcast so the UI refreshes")
    }

    // MARK: - No-authorization signal: diagnostic-only (post PP-3649)

    /// Post PP-3649, the no-authorization signal is logged-only. Registry
    /// must NOT be flipped, no alert. Pin the silent path.
    func testHandoff_noAuthorization_isDiagnosticOnly_noRegistryMutation() {
        handler.handleNoAuthorization()

        XCTAssertEqual(spy.failed, [])
        XCTAssertEqual(spy.markedSuccessful, [])
        XCTAssertEqual(spy.broadcastCount, 0)
        XCTAssertEqual(registry.state(for: book.identifier), .downloading,
                       "No-authorization is diagnostic — must not mutate registry")
    }

    // MARK: - Unknown book identifier (lookup miss)

    /// Tag does not resolve to a book in the registry: handler returns
    /// early with no side effects. Pins the lookup guard.
    func testHandoff_unknownTag_silentEarlyReturn() {
        handler.handleFulfillmentResult(
            didFinishDownload: true,
            to: acsmFulfilledURL,
            fulfillmentID: "rmsdk-1",
            isReturnable: true,
            rightsData: Data("<r/>".utf8),
            tag: "tag-not-in-registry",
            adeptError: nil
        )

        XCTAssertEqual(spy.failed, [])
        XCTAssertEqual(spy.markedSuccessful, [])
        XCTAssertEqual(spy.broadcastCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: contentDestURL.path))
    }

    // MARK: - Rights data malformed (non-UTF-8): abort

    /// Rights data not decodable as UTF-8 (corrupted): handler must abort
    /// before marking success. We never want to claim success on corrupt
    /// rights — the rights file is what the reader uses to unlock the
    /// content. Pin the guard.
    func testHandoff_undecodableRightsData_abortsWithoutSuccess() {
        let badBytes = Data([0xC0, 0xC1, 0xFE, 0xFF])

        handler.handleFulfillmentResult(
            didFinishDownload: true,
            to: acsmFulfilledURL,
            fulfillmentID: "rmsdk-1",
            isReturnable: true,
            rightsData: badBytes,
            tag: book.identifier,
            adeptError: nil
        )

        XCTAssertEqual(spy.markedSuccessful, [],
                       "Corrupt rights data must abort the handoff — never mark success")
        XCTAssertEqual(spy.failed, [],
                       "Corrupt rights data is a silent early-return, not an alert")
    }

    // MARK: - Progress forwarding (RMSDK → MBDC pipeline)

    /// RMSDK reports progress via `didUpdateProgress`. The handler must
    /// forward to the delegate's `handleAdobeDownloadProgress` so MBDC can
    /// publish to subscribers. Pin the forwarding plumbing.
    func testHandoff_progressForwarding_invokesDelegateWithExactValues() {
        handler.handleProgress(0.42, for: book.identifier)

        XCTAssertEqual(spy.progressUpdates.count, 1)
        XCTAssertEqual(spy.progressUpdates.first?.0 ?? -1, 0.42, accuracy: 0.0001,
                       "Progress value must be forwarded exactly")
        XCTAssertEqual(spy.progressUpdates.first?.1, book.identifier,
                       "Progress tag must be forwarded exactly")
    }

    /// Multiple progress callbacks accumulate in order — order-preservation
    /// pins how MBDC observers receive monotonic-ish updates.
    func testHandoff_progressForwarding_preservesOrderAcrossMultipleCallbacks() {
        handler.handleProgress(0.1, for: book.identifier)
        handler.handleProgress(0.5, for: book.identifier)
        handler.handleProgress(0.9, for: book.identifier)

        XCTAssertEqual(spy.progressUpdates.map { $0.0 }, [0.1, 0.5, 0.9],
                       "Progress callbacks must be forwarded in submission order")
    }
}

// MARK: - Spy

private final class RMSDKHandoffSpy: AdobeDRMHandlerDelegate {

    let bookRegistry: TPPBookRegistryProvider
    var destURLOverride: URL?

    private(set) var markedSuccessful: [String] = []
    private(set) var failed: [String] = []
    private(set) var broadcastCount = 0
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

#else

// Placeholder when FEATURE_DRM_CONNECTOR is not set. PalaceTests still
// compiles cleanly; we just don't run RMSDK handoff coverage. The Palace
// target in this repo IS compiled with the flag, so production runs the
// real suite. This branch exists so the file still compiles under a
// noDRM build flavour.
final class DownloadRMSDKHandoffTests: XCTestCase {

    func testRMSDKHandoff_featureDRMConnectorDisabled_skipsSuite() {
        XCTAssertTrue(true, "FEATURE_DRM_CONNECTOR is not defined in this build — RMSDK handoff suite is intentionally a no-op here")
    }
}

#endif
