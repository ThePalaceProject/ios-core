//
//  AudiobookPositionAdapterContractTests.swift
//  PalaceTests
//
//  Contract-snapshot tests for `AudiobookBookmarkBusinessLogic.saveListeningPosition`
//  — the swarm_f4fbef9c Module B wiring that funnels audiobook position
//  writes through the canonical `PalaceReadingPosition.PositionWriter`.
//
//  These tests pin the call ORDER between the SUT, the
//  `TPPBookRegistryProvider`, and the injected `PositionWriter`:
//
//    1. Local-save-first invariant — `registry.setLocation(localBookmark)`
//       MUST run synchronously, before the async `Task { writer.save(...) }`
//       hop. This is the swarm_f3b9b087 P0 #4 "user safety net" rule.
//    2. Writer delegation — `writer.save(snapshot)` runs after the local
//       save, with `format == .audiobook` and `bookID == self.book.identifier`.
//    3. Post-save commit — on `.success`, `registry.setLocation(...)` runs
//       a SECOND time to commit the server-assigned `annotationId`.
//    4. Guards (`isAtBeginning`, `timestampNewerRace`) — when triggered,
//       the post-save commit is SUPPRESSED. The snapshot shows only one
//       `registry.setLocation` instead of two — pins the swarm_f3b9b087 P0
//       fix predicates.
//
//  Pattern matches `BorrowReducerContractTests.swift`. Spies record into a
//  shared `CallLog`; `ContractSnapshot.assert(...)` writes/compares JSON.
//
//  **First run:** records baselines at
//  `__Snapshots__/AudiobookPositionAdapterContractTests/<scenario>.json`
//  and FAILS with "snapshot recorded — re-run to verify". Set
//  `CONTRACT_SNAPSHOT_RECORD=1` to deliberately re-record.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import Combine
import UIKit
import PalaceCatalog
@testable import Palace
@testable import PalaceAudiobookToolkit
import PalaceReadingPosition

// MARK: - Spy PositionWriter (records into CallLog)

/// Records `save`/`load`/`cancel` against a shared `CallLog`. The
/// `saveOutcome` controls return shape. The writer is NOT thread-safe in
/// the strictest sense — it relies on the SUT's serial drive of `save`.
private final class CallLogPositionWriter: PositionWriter, @unchecked Sendable {

    enum Outcome {
        case success(ServerPositionID)
        case throttled
        case failure(Error)
    }

    let log: CallLog
    private let lock = NSLock()
    private var _outcome: Outcome = .success("server-stub-id")
    private var _onSave: (() -> Void)?

    init(log: CallLog) {
        self.log = log
    }

    var outcome: Outcome {
        get { lock.lock(); defer { lock.unlock() }; return _outcome }
        set { lock.lock(); defer { lock.unlock() }; _outcome = newValue }
    }

    /// Hook fired synchronously inside `save`, BEFORE the outcome is
    /// returned. Used by the timestamp-race scenario to mutate the
    /// registry between local-save-first and the post-save guard.
    func setOnSave(_ hook: @escaping () -> Void) {
        lock.lock(); defer { lock.unlock() }
        _onSave = hook
    }

    func save(_ snapshot: PositionSnapshot) async throws -> ServerPositionID? {
        let outcome: Outcome
        let hook: (() -> Void)?
        lock.lock()
        outcome = _outcome
        hook = _onSave
        lock.unlock()

        log.record(
            "writer.save",
            args: [
                "bookID": snapshot.bookID,
                "format": snapshot.format.rawValue,
                "payloadIsEmpty": snapshot.payload.isEmpty,
            ]
        )
        hook?()
        switch outcome {
        case .success(let id):
            return id
        case .throttled:
            return nil
        case .failure(let error):
            throw error
        }
    }

    func load(for bookID: String) async throws -> PositionSnapshot? {
        log.record("writer.load", args: ["bookID": bookID])
        return nil
    }

    func cancel(for bookID: String) async {
        log.record("writer.cancel", args: ["bookID": bookID])
    }
}

// MARK: - Recording registry adapter (decorates a real mock)

/// Wraps `TPPBookRegistryMock` to record every `setLocation` call into a
/// `CallLog` while still updating the underlying mock for the SUT's
/// guards to read from. We don't subclass `TPPBookRegistryMock` because
/// the SUT uses `TPPBookRegistryProvider` directly — we conform to the
/// protocol and forward every call.
private final class RecordingRegistry: NSObject, TPPBookRegistryProvider, @unchecked Sendable {
    let log: CallLog
    let inner: TPPBookRegistryMock

    init(log: CallLog, inner: TPPBookRegistryMock) {
        self.log = log
        self.inner = inner
    }

    // MARK: TPPBookRegistryProvider (recording the ONLY two methods the
    // audiobook save path touches)

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
        // Reads are observed via the SUT's behavior, not recorded into
        // the contract — recording every read would noise-up the snapshot
        // (the SUT does multiple read passes through the guards).
        return inner.location(forIdentifier: identifier)
    }

    // MARK: Forward-only — not part of the contract surface

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
final class AudiobookPositionAdapterContractTests: XCTestCase {

    private let bookIdentifier = "contract-audiobook-1"
    private let manifestJSON: ManifestJSON = .snowcrash

    private var book: TPPBook!
    private var innerRegistry: TPPBookRegistryMock!
    private var registry: RecordingRegistry!
    private var annotations: TPPAnnotationMock!
    private var writer: CallLogPositionWriter!
    private var sut: AudiobookBookmarkBusinessLogic!
    private var tracks: Tracks!
    private var log: CallLog!

    override func setUpWithError() throws {
        try super.setUpWithError()
        log = CallLog()

        let url = URL(string: "https://test.example.com/book")!
        let acq = TPPOPDSAcquisition(
            relation: .generic,
            type: "application/epub+zip",
            hrefURL: url,
            indirectAcquisitions: [],
            availability: TPPOPDSAcquisitionAvailabilityUnlimited()
        )
        book = TPPBook(
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

        innerRegistry = TPPBookRegistryMock()
        innerRegistry.addBook(book, state: .downloadSuccessful)
        registry = RecordingRegistry(log: log, inner: innerRegistry)
        annotations = TPPAnnotationMock()
        writer = CallLogPositionWriter(log: log)

        sut = AudiobookBookmarkBusinessLogic(
            book: book,
            registry: registry,
            annotationsManager: annotations,
            positionWriter: writer
        )

        let manifest = try Manifest.from(jsonFileName: manifestJSON.rawValue, bundle: Bundle(for: type(of: self)))
        tracks = Tracks(manifest: manifest, audiobookID: bookIdentifier, token: nil)
    }

    override func tearDown() {
        sut = nil
        writer = nil
        annotations = nil
        registry = nil
        innerRegistry = nil
        book = nil
        tracks = nil
        log = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func position(trackIndex: Int, time: Double) -> TrackPosition {
        TrackPosition(track: tracks.tracks[trackIndex], timestamp: time, tracks: tracks)
    }

    /// Drive `saveListeningPosition` and wait for the async Task to drain.
    private func saveAndWait(position: TrackPosition, timeout: TimeInterval = 2.0) {
        let exp = expectation(description: "saveListeningPosition completes")
        sut.saveListeningPosition(at: position) { _ in exp.fulfill() }
        wait(for: [exp], timeout: timeout)
    }

    // MARK: - 1. Local-first → writer.save → registry-second commit

    /// Pins the canonical happy-path call order:
    ///   1. `registry.setLocation(localBookmark)` (synchronous, before the
    ///      async hop)
    ///   2. `writer.save(snapshot)` with `format == .audiobook`
    ///   3. `registry.setLocation(serverEnrichedBookmark)` after `.success`
    ///
    /// Regression caught: swapping #1 and #2 (a refactor that defers the
    /// local save into the async Task) deletes line #1 from the snapshot
    /// — that's swarm_f3b9b087 P0 #4 regressing.
    func test_audiobookSave_localFirstThenWriter() {
        writer.outcome = .success("server-canonical-id")
        let p = position(trackIndex: 1, time: 100.0)

        saveAndWait(position: p)

        ContractSnapshot.assert(log, named: "audiobookSave_localFirstThenWriter")
    }

    // MARK: - 2. isAtBeginning guard — second registry write is suppressed

    /// Pins the swarm_f3b9b087 P0 #4 guard predicate:
    ///   When (incoming trackIndex == 0 AND playbackTime < 30.0) AND the
    ///   current local bookmark is in a LATER track, the post-save commit
    ///   MUST be suppressed — the snapshot shows ONE `registry.setLocation`
    ///   (the initial local save) and ONE `writer.save`, with NO follow-up
    ///   `registry.setLocation`.
    ///
    /// Regression caught: if the predicate inverts (e.g. `trackIndex == 0`
    /// → `trackIndex != 0`) the snapshot grows a second
    /// `registry.setLocation` line — the user's later-chapter position
    /// gets clobbered by a stale beginning-of-book save.
    func test_audiobookSave_preservesIsAtBeginningGuard() throws {
        // Pre-seed a later-track bookmark. The guard reads the chapter
        // string and parses the trailing integer ("chapter-3" → 3 > 0).
        let later = AudioBookmark(
            type: .locatorAudioBookTime,
            version: 1,
            timeStamp: "2025-12-31T23:59:59Z",
            annotationId: "ann-later",
            readingOrderItem: "track-3",
            readingOrderItemOffsetMilliseconds: 60_000,
            chapter: "chapter-3",
            title: "Chapter 3",
            part: nil,
            time: 60
        )
        let laterLoc = try XCTUnwrap(later.toTPPBookLocation())
        // Pre-seed via the INNER mock so the pre-state setLocation isn't
        // captured by the CallLog (we want the snapshot to start at the
        // SUT's first call, not at test setup).
        innerRegistry.setLocation(laterLoc, forIdentifier: bookIdentifier)

        writer.outcome = .success("server-beginning-id")
        let p = position(trackIndex: 0, time: 5.0)  // < 30.0 → guard fires
        saveAndWait(position: p)

        ContractSnapshot.assert(log, named: "audiobookSave_preservesIsAtBeginningGuard")
    }

    // MARK: - 3. Timestamp-newer race-check — second registry write suppressed

    /// Pins the swarm_f3b9b087 P0 #4 race-check:
    ///   When the post-save guard reads the current local bookmark and
    ///   finds its timestamp is newer than the sent timestamp by more
    ///   than the 1.0s grace window, the post-save commit MUST be
    ///   suppressed. The snapshot records ONE initial `registry.setLocation`
    ///   (the local-first invariant), ONE `writer.save`, and NO follow-up
    ///   `registry.setLocation`.
    ///
    /// We trigger the race by mutating the registry inside the spy
    /// writer's `save` hook — between the SUT's synchronous local save
    /// and the post-save guard.
    func test_audiobookSave_preservesTimestampNewerRace() throws {
        // Build a "fresh local" bookmark with a timestamp 1 hour in the
        // future — well outside the 1.0s grace window that the SUT's
        // `String.isDate(_:moreRecentThan:with:1.0)` check uses.
        let freshTimestamp = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        let fresh = AudioBookmark(
            type: .locatorAudioBookTime,
            version: 1,
            timeStamp: freshTimestamp,
            annotationId: "ann-fresh-local",
            readingOrderItem: "track-2",
            readingOrderItemOffsetMilliseconds: 30_000,
            chapter: "chapter-2",
            title: "Chapter 2",
            part: nil,
            time: 30
        )
        let freshLoc = try XCTUnwrap(fresh.toTPPBookLocation())

        // Race window: the SUT's synchronous local save commits the new
        // "track 0, t=5s" bookmark. Inside writer.save, we overwrite that
        // with the fresh-local bookmark. The SUT's post-save guard reads
        // the registry NOW and sees the fresh timestamp → suppresses the
        // post-save commit.
        writer.outcome = .success("server-stale-id")
        writer.setOnSave { [weak self] in
            // Mutate via INNER so the contract snapshot doesn't grow a
            // synthetic registry.setLocation. The point is to make the
            // SUT's read-side guard see the fresh state.
            self?.innerRegistry.setLocation(freshLoc, forIdentifier: self?.bookIdentifier ?? "")
        }

        let p = position(trackIndex: 0, time: 5.0)
        saveAndWait(position: p)

        ContractSnapshot.assert(log, named: "audiobookSave_preservesTimestampNewerRace")
    }
}
