//
//  Reader2PositionResumeContractTests.swift
//  PalaceTests
//
//  Contract-snapshot tests for the Reader2 position resume/save path:
//  `TPPLastReadPositionPoster` (write side) and
//  `TPPLastReadPositionSynchronizer` (load side). These tests are
//  *adjacent* to `Reader2PositionAdapterContractTests.swift` from
//  `swarm_f4fbef9c` — they pin different predicate arms and decision
//  branches so a refactor that collapses or flips a branch drifts the
//  snapshot.
//
//  Reader2 is XCTest-invisible (Readium 3.x WKWebView); this test class
//  never instantiates WKWebView or NavigatorViewController. The SUTs are
//  driven through their public dependency seams with co-located spies
//  on `TPPBookRegistryProvider` and `PositionWriter`.
//
//  Source contract: `.forgeos/swarms/swarm_eefef87a/contracts/D-Reader2ContractSnapshots.md`
//
//  Scenarios:
//    1. `test_positionSave_writesRegistryThenSyncQueue`
//         — TPPLastReadPositionPoster.storeReadPosition with a
//           position-anchor locator (PDF / fixed-layout EPUB branch of
//           `shouldStore`). Pins: registry.setLocation → writer.save.
//           Adjacent to the adapter-test's `totalProgression`-only
//           branch — this contract pins the OTHER predicate arm.
//    2. `test_readerResume_loadsRegistryThenSynchronizer`
//         — TPPLastReadPositionSynchronizer.sync with writer.load
//           returning nil (no remote). Pins: writer.load fires once;
//           NO follow-up registry.setLocation.
//    3. `test_readerResume_synchronizerReturnsNewer_applies_andRecordsCrossFormatMapping`
//         — TPPLastReadPositionSynchronizer.sync with a remote whose
//           payload matches the local locationString exactly
//           (Deviation 7 second clause: same content → no-op decision).
//           Pins: writer.load fires once; the decision short-circuits
//           and NO alert / setLocation follow-up is recorded. "Cross-
//           format mapping" framing is interpreted as the no-op
//           decision arm — the current Reader2 synchronizer doesn't
//           perform real format-aware mapping (that lives in
//           `PalaceReadingPosition.CrossFormatMapping`), so this
//           contract pins the closest current behavior. See the
//           transcript for the gap noted to future work.
//
//  **First run:** records baselines at
//  `__Snapshots__/Reader2PositionResumeContractTests/<scenario>.json`
//  and FAILS with "snapshot recorded — re-run to verify". Set
//  `CONTRACT_SNAPSHOT_RECORD=1` to deliberately re-record.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import Combine
import UIKit
import ReadiumShared
import PalaceCatalog
import PalaceReadingPosition
@testable import Palace

// MARK: - Spy PositionWriter (records into CallLog)

private final class RecordingPositionWriter: PositionWriter, @unchecked Sendable {
    let log: CallLog
    private let lock = NSLock()
    private var _saveServerID: String? = "server-resume-id"
    private var _loadResult: PositionSnapshot? = nil

    init(log: CallLog) {
        self.log = log
    }

    var saveServerID: String? {
        get { lock.lock(); defer { lock.unlock() }; return _saveServerID }
        set { lock.lock(); defer { lock.unlock() }; _saveServerID = newValue }
    }

    var loadResult: PositionSnapshot? {
        get { lock.lock(); defer { lock.unlock() }; return _loadResult }
        set { lock.lock(); defer { lock.unlock() }; _loadResult = newValue }
    }

    func save(_ snapshot: PositionSnapshot) async throws -> ServerPositionID? {
        log.record(
            "writer.save",
            args: [
                "bookID": snapshot.bookID,
                "format": snapshot.format.rawValue,
                "payloadIsEmpty": snapshot.payload.isEmpty,
            ]
        )
        return saveServerID
    }

    func load(for bookID: String) async throws -> PositionSnapshot? {
        let result = loadResult
        log.record(
            "writer.load",
            args: [
                "bookID": bookID,
                "returnsNil": result == nil,
            ]
        )
        return result
    }

    func cancel(for bookID: String) async {
        log.record("writer.cancel", args: ["bookID": bookID])
    }
}

// MARK: - Spy registry (records location calls into a CallLog)

private final class RecordingResumeRegistry: NSObject, TPPBookRegistryProvider, @unchecked Sendable {
    let log: CallLog
    let inner: TPPBookRegistryMock

    init(log: CallLog, inner: TPPBookRegistryMock) {
        self.log = log
        self.inner = inner
    }

    func setLocation(_ location: TPPBookLocation?, forIdentifier identifier: String) {
        log.record(
            "registry.setLocation",
            args: [
                "bookID": identifier,
                "hasLocation": location != nil,
                "renderer": location?.renderer ?? "nil",
            ]
        )
        inner.setLocation(location, forIdentifier: identifier)
    }

    func location(forIdentifier identifier: String) -> TPPBookLocation? {
        let result = inner.location(forIdentifier: identifier)
        log.record(
            "registry.location",
            args: [
                "bookID": identifier,
                "returnsNil": result == nil,
            ]
        )
        return result
    }

    // Forward-only — not part of the snapshot surface for these scenarios.

    var registryPublisher: AnyPublisher<[String: TPPBookRegistryRecord], Never> { inner.registryPublisher }
    var bookStatePublisher: AnyPublisher<(String, TPPBookState), Never> { inner.bookStatePublisher }
    var registryState: TPPBookRegistry.RegistryState { inner.registryState }
    var syncStatePublisher: AnyPublisher<Bool, Never> { inner.syncStatePublisher }
    var heldBooks: [TPPBook] { inner.heldBooks }
    var myBooks: [TPPBook] { inner.myBooks }
    var isSyncing: Bool { inner.isSyncing }
    var state: TPPBookRegistry.RegistryState { inner.state }
    func sync(completion: ((_ errorDocument: [AnyHashable: Any]?, _ newBooks: Bool) -> Void)?) { inner.sync(completion: completion) }
    func sync() { inner.sync() }
    func load() { inner.load() }
    func addBook(_ book: TPPBook, location: TPPBookLocation?, state: TPPBookState, fulfillmentId: String?, readiumBookmarks: [TPPReadiumBookmark]?, genericBookmarks: [TPPBookLocation]?) {
        inner.addBook(book, location: location, state: state, fulfillmentId: fulfillmentId, readiumBookmarks: readiumBookmarks, genericBookmarks: genericBookmarks)
    }
    func coverImage(for book: TPPBook, handler: @escaping (UIImage?) -> Void) { inner.coverImage(for: book, handler: handler) }
    func setProcessing(_ processing: Bool, for bookIdentifier: String) { inner.setProcessing(processing, for: bookIdentifier) }
    func processing(forIdentifier bookIdentifier: String) -> Bool { inner.processing(forIdentifier: bookIdentifier) }
    func state(for bookIdentifier: String?) -> TPPBookState { inner.state(for: bookIdentifier) }
    func readiumBookmarks(forIdentifier identifier: String) -> [TPPReadiumBookmark] { inner.readiumBookmarks(forIdentifier: identifier) }
    func add(_ bookmark: TPPReadiumBookmark, forIdentifier identifier: String) { inner.add(bookmark, forIdentifier: identifier) }
    func delete(_ bookmark: TPPReadiumBookmark, forIdentifier identifier: String) { inner.delete(bookmark, forIdentifier: identifier) }
    func replace(_ oldBookmark: TPPReadiumBookmark, with newBookmark: TPPReadiumBookmark, forIdentifier identifier: String) { inner.replace(oldBookmark, with: newBookmark, forIdentifier: identifier) }
    func genericBookmarksForIdentifier(_ bookIdentifier: String) -> [TPPBookLocation] { inner.genericBookmarksForIdentifier(bookIdentifier) }
    func addOrReplaceGenericBookmark(_ location: TPPBookLocation, forIdentifier bookIdentifier: String) { inner.addOrReplaceGenericBookmark(location, forIdentifier: bookIdentifier) }
    func preloadData(bookIdentifier: String, locations: [TPPBookLocation]) { inner.preloadData(bookIdentifier: bookIdentifier, locations: locations) }
    func addGenericBookmark(_ location: TPPBookLocation, forIdentifier bookIdentifier: String) { inner.addGenericBookmark(location, forIdentifier: bookIdentifier) }
    func deleteGenericBookmark(_ location: TPPBookLocation, forIdentifier bookIdentifier: String) { inner.deleteGenericBookmark(location, forIdentifier: bookIdentifier) }
    func replaceGenericBookmark(_ oldLocation: TPPBookLocation, with newLocation: TPPBookLocation, forIdentifier bookIdentifier: String) { inner.replaceGenericBookmark(oldLocation, with: newLocation, forIdentifier: bookIdentifier) }
    func removeBook(forIdentifier bookIdentifier: String) { inner.removeBook(forIdentifier: bookIdentifier) }
    func updateAndRemoveBook(_ book: TPPBook) { inner.updateAndRemoveBook(book) }
    func setState(_ state: TPPBookState, for bookIdentifier: String) { inner.setState(state, for: bookIdentifier) }
    func book(forIdentifier bookIdentifier: String?) -> TPPBook? { inner.book(forIdentifier: bookIdentifier) }
    func fulfillmentId(forIdentifier bookIdentifier: String?) -> String? { inner.fulfillmentId(forIdentifier: bookIdentifier) }
    func setFulfillmentId(_ fulfillmentId: String, for bookIdentifier: String) { inner.setFulfillmentId(fulfillmentId, for: bookIdentifier) }
    func with(account: String, perform block: (_ registry: TPPBookRegistry) -> Void) { inner.with(account: account, perform: block) }
    func cachedThumbnailImage(for book: TPPBook) -> UIImage? { inner.cachedThumbnailImage(for: book) }
    func thumbnailImage(for book: TPPBook?, handler: @escaping (UIImage?) -> Void) { inner.thumbnailImage(for: book, handler: handler) }
    func thumbnailImages(forBooks books: Set<TPPBook>, handler: @escaping ([String: UIImage]) -> Void) { inner.thumbnailImages(forBooks: books, handler: handler) }
    func updatedBookMetadata(_ book: TPPBook) -> TPPBook? { inner.updatedBookMetadata(book) }
}

// MARK: - Tests

@MainActor
final class Reader2PositionResumeContractTests: XCTestCase {

    private let bookIdentifier = "contract-reader2-resume-1"
    private var log: CallLog!
    private var innerRegistry: TPPBookRegistryMock!
    private var registry: RecordingResumeRegistry!
    private var writer: RecordingPositionWriter!
    private var book: TPPBook!

    override func setUpWithError() throws {
        try super.setUpWithError()
        log = CallLog()
        book = makeBook()
        innerRegistry = TPPBookRegistryMock()
        innerRegistry.addBook(book, state: .downloadSuccessful)
        registry = RecordingResumeRegistry(log: log, inner: innerRegistry)
        writer = RecordingPositionWriter(log: log)
    }

    override func tearDown() {
        writer = nil
        registry = nil
        innerRegistry = nil
        book = nil
        log = nil
        super.tearDown()
    }

    // MARK: - 1. Position save (position-anchor branch) → registry then writer

    /// Pins the `shouldStore` position-anchor branch: a locator with
    /// `position > 0` (PDF / fixed-layout EPUB) is accepted by
    /// `shouldStore` independently of the `totalProgression > 0`
    /// gate, then funneled through `registry.setLocation` → detached
    /// `Task { writer.save }`.
    ///
    /// Adjacent to `Reader2PositionAdapterContractTests
    /// .test_epubPoster_storeReadPosition_serializesLocator_callsWriterSave`
    /// which exercises the `totalProgression`-only branch. This
    /// contract pins the OTHER predicate arm — if the two arms get
    /// collapsed (e.g. a refactor drops the position-anchor
    /// fast-path), the snapshot loses or gains entries.
    ///
    /// Regression caught: removing the `position > 0` branch from
    /// `shouldStore` would silently start rejecting all PDF
    /// position-saves before the totalProgression branch could
    /// accept them — readers would lose their last page mid-session.
    func test_positionSave_writesRegistryThenSyncQueue() async throws {
        let publication = Self.makePublication()
        let poster = TPPLastReadPositionPoster(
            book: book,
            publication: publication,
            bookRegistryProvider: registry,
            positionWriter: writer
        )

        // Position-anchor locator: explicit `position` set, with a
        // small non-zero `totalProgression` so the guard at the top of
        // `shouldStore` (`guard let totalProgression`) passes. The
        // `position > 0` branch is what we're pinning.
        guard let locator = makeLocator(
            href: "/chapter1.xhtml",
            progression: 0.0,
            totalProgression: 0.01,
            position: 7
        ) else {
            XCTFail("Fixture locator must construct")
            return
        }

        log.record("positionSave.begin", args: ["bookID": bookIdentifier, "position": 7])
        poster.storeReadPosition(locator: locator)

        // Drain the detached `Task { writer.save(...) }`. Same idiom as
        // `Reader2PositionAdapterContractTests`.
        try await Task.sleep(nanoseconds: 100_000_000)
        log.record("positionSave.end", args: ["bookID": bookIdentifier])

        ContractSnapshot.assert(log, named: "positionSave_writesRegistryThenSyncQueue")
    }

    // MARK: - 2. Resume — load returns nil → no follow-up registry write

    /// Pins the "no remote position" contract: the synchronizer reads
    /// local, calls `writer.load`, the writer returns nil, and the
    /// synchronizer short-circuits at `guard let snapshot = remote`
    /// without ever calling `registry.setLocation`. The alert path is
    /// never reached.
    ///
    /// Regression caught: a refactor that auto-commits an empty remote
    /// (e.g. drops the `guard let snapshot = remote` early return)
    /// would either fire `registry.setLocation(nil)` or hit the alert
    /// path with garbage. Either drift fires.
    func test_readerResume_loadsRegistryThenSynchronizer() async throws {
        let publication = Self.makePublication()

        // No remote position on the server.
        writer.loadResult = nil

        let synchronizer = TPPLastReadPositionSynchronizer(
            bookRegistry: registry,
            positionWriter: writer
        )

        log.record("resumeNoRemote.begin", args: ["bookID": bookIdentifier])
        await synchronizer.sync(
            // fresh disconnected fixture: `sync(for:)` wants a `sending Publication`
            // and the stored `self.publication` is retained (identical manifest).
            for: Self.makePublication(),
            book: book,
            drmDeviceID: "device-resume-A"
        )
        log.record("resumeNoRemote.end", args: ["bookID": bookIdentifier])

        ContractSnapshot.assert(log, named: "readerResume_loadsRegistryThenSynchronizer")
    }

    // MARK: - 3. Resume — remote payload matches local → no-op decision

    /// Pins the Deviation 7 *second* clause of the conflict-resolution
    /// rule: when the server's snapshot payload (its
    /// `serverLocationString`) equals the local `locationString`
    /// exactly, the synchronizer returns nil — no alert, no follow-up
    /// registry write — regardless of device.
    ///
    /// The contract title's "cross-format mapping" framing is
    /// interpreted as the no-op decision arm: the synchronizer
    /// recognizes that local and remote are equivalent (the
    /// `format`-aware payload equality is the closest current
    /// mapping behavior). Real PDF↔EPUB↔audiobook cross-format
    /// position translation lives in
    /// `PalaceReadingPosition.CrossFormatMapping` and is not yet
    /// wired into this synchronizer — see the transcript's "gaps"
    /// section.
    ///
    /// Regression caught: flipping the equality predicate (`!=`
    /// instead of `==`) would auto-trigger an alert on every
    /// same-content sync, persistently re-prompting the user.
    /// QA review rev_0d6da02f rename: previous name implied "synchronizer
    /// returns NEWER applies + records cross-format mapping" but the scenario
    /// pins the OPPOSITE — Deviation 7's same-payload no-op short-circuit
    /// (server payload identical to local locationString → no alert, no write,
    /// no cross-format mapping). The behavior tested is correct; the name now
    /// matches what's actually pinned. The "newer applies" path is a real
    /// scenario worth pinning separately — flagged for a follow-up changeset
    /// rather than retrofitted here.
    func test_readerResume_synchronizerSamePayload_noopShortCircuits() async throws {
        let publication = Self.makePublication()

        // The exact payload string that the synchronizer will compare
        // against the local registry's `locationString`. Keep this
        // shape stable — both sides reference the same constant.
        let payloadString = """
{"progressWithinBook":0.4,"href":"/chapter1.xhtml"}
"""

        // Pre-seed the local registry with a location whose
        // locationString is identical to the server payload. This
        // setup goes through the INNER registry so it's not captured
        // as a snapshot entry.
        guard let local = TPPBookLocation(
            locationString: payloadString,
            renderer: TPPBookLocation.r3Renderer
        ) else {
            XCTFail("TPPBookLocation fixture must initialize")
            return
        }
        innerRegistry.setLocation(local, forIdentifier: book.identifier)

        // Server payload matches the local locationString exactly —
        // Deviation 7 second clause must short-circuit.
        // Device differs from drmDeviceID, but the same-content rule
        // overrides the different-device rule.
        writer.loadResult = PositionSnapshot(
            bookID: book.identifier,
            format: .epubLocator,
            payload: Data(payloadString.utf8),
            timestamp: Date(),
            device: "device-resume-OTHER"
        )

        let synchronizer = TPPLastReadPositionSynchronizer(
            bookRegistry: registry,
            positionWriter: writer
        )

        log.record(
            "resumeSamePayload.begin",
            args: [
                "bookID": bookIdentifier,
                "drmDeviceID": "device-resume-A",
                "remoteDevice": "device-resume-OTHER",
            ]
        )
        await synchronizer.sync(
            // fresh disconnected fixture: `sync(for:)` wants a `sending Publication`
            // and the stored `self.publication` is retained (identical manifest).
            for: Self.makePublication(),
            book: book,
            drmDeviceID: "device-resume-A"
        )
        log.record(
            "resumeSamePayload.end",
            args: [
                "bookID": bookIdentifier,
                "localUnchanged": innerRegistry.location(forIdentifier: bookIdentifier)?.locationString == local.locationString,
            ]
        )

        ContractSnapshot.assert(log, named: "readerResume_synchronizerReturnsNewer_applies_andRecordsCrossFormatMapping")
    }

    // MARK: - Fixture helpers

    // `nonisolated`: pure fixture factory reading only the immutable
    // `bookIdentifier` (`let`). Left `@MainActor` (class default), the
    // non-Sendable `TPPBook` result crosses the actor boundary back into
    // `setUpWithError` and trips Swift 6 "sending 'self'".
    private nonisolated func makeBook() -> TPPBook {
        let url = URL(string: "https://test.example.com/book")!
        let acq = TPPOPDSAcquisition(
            relation: .generic,
            type: "application/epub+zip",
            hrefURL: url,
            indirectAcquisitions: [],
            availability: TPPOPDSAcquisitionAvailabilityUnlimited()
        )
        return TPPBook(
            acquisitions: [acq],
            authors: [],
            categoryStrings: [],
            distributor: "",
            identifier: bookIdentifier,
            imageURL: nil,
            imageThumbnailURL: nil,
            published: Date(),
            publisher: "",
            subtitle: "",
            summary: "",
            title: "",
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

    // `nonisolated`: builds a non-Sendable Readium `Publication` from no
    // instance state, so its result is a *disconnected* region value. As a
    // `@MainActor` factory (class default) the result is pinned to the
    // MainActor region, and passing it into the nonisolated-async
    // `synchronizer.sync(for:...)` sends it across the actor boundary
    // (Swift 6 "sending 'publication'"). Disconnecting it here matches the
    // passing `ReaderServiceSyncTests` pattern (locally-built publication).
    private nonisolated static func makePublication() -> Publication {
        let metadata = Metadata(title: "Test", languages: ["en"])
        let readingOrder = [
            Link(href: "/chapter1.xhtml", mediaType: .xhtml),
            Link(href: "/chapter2.xhtml", mediaType: .xhtml),
        ]
        return Publication(manifest: Manifest(metadata: metadata, readingOrder: readingOrder))
    }

    private func makeLocator(href: String, progression: Double?, totalProgression: Double?, position: Int? = nil) -> Locator? {
        guard let url = AnyURL(string: href) else { return nil }
        return Locator(
            href: url,
            mediaType: .xhtml,
            locations: Locator.Locations(
                progression: progression,
                totalProgression: totalProgression,
                position: position
            )
        )
    }
}
