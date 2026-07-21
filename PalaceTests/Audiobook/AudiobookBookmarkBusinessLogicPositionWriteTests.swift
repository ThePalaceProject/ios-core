//
//  AudiobookBookmarkBusinessLogicPositionWriteTests.swift
//  PalaceTests
//
//  Tests for the audiobook position-write migration onto the unified
//  `PalaceReadingPosition.PositionWriter` protocol (swarm_f4fbef9c
//  Module B). Pins the swarm_f3b9b087 P0 conflict-resolution predicates
//  so they cannot regress under the migration.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceCatalog
@testable import Palace
@testable import PalaceAudiobookToolkit
import PalaceReadingPosition

// MARK: - Spy

/// Records every `save` / `load` / `cancel` call against the writer.
/// `saveResult` controls the outcome of the next `save` call. Tests that
/// need to verify "local save unaffected by writer queueing" set
/// `saveResult = .throttled` (writer returns nil — queued, not posted).
private final class SpyPositionWriter: PositionWriter, @unchecked Sendable {

    enum SaveOutcome {
        case success(ServerPositionID)
        case throttled  // writer returns nil, simulating queued/throttled
        case failure(Error)
    }

    private let lock = NSLock()
    private var _savedSnapshots: [PositionSnapshot] = []
    private var _saveResult: SaveOutcome = .success("spy-server-id")
    private var _loadResult: PositionSnapshot? = nil
    private var _cancelledBookIDs: [String] = []
    private var _onSave: (() -> Void)?

    func setOnSave(_ hook: @escaping () -> Void) {
        lock.lock(); defer { lock.unlock() }
        _onSave = hook
    }

    var savedSnapshots: [PositionSnapshot] {
        lock.lock(); defer { lock.unlock() }
        return _savedSnapshots
    }

    var saveResult: SaveOutcome {
        get {
            lock.lock(); defer { lock.unlock() }
            return _saveResult
        }
        set {
            lock.lock(); defer { lock.unlock() }
            _saveResult = newValue
        }
    }

    var cancelledBookIDs: [String] {
        lock.lock(); defer { lock.unlock() }
        return _cancelledBookIDs
    }

    func save(_ snapshot: PositionSnapshot) async throws -> ServerPositionID? {
        let (result, hook) = lock.withLock { () -> (SaveOutcome, (() -> Void)?) in
            _savedSnapshots.append(snapshot)
            return (_saveResult, _onSave)
        }

        hook?()  // race-window injection: tests can mutate registry between SUT's local-save and post-save guard

        switch result {
        case .success(let id):
            return id
        case .throttled:
            return nil
        case .failure(let error):
            throw error
        }
    }

    func load(for bookID: String) async throws -> PositionSnapshot? {
        return lock.withLock { _loadResult }
    }

    func cancel(for bookID: String) async {
        lock.withLock { _cancelledBookIDs.append(bookID) }
    }
}

// MARK: - Tests

@MainActor
final class AudiobookBookmarkBusinessLogicPositionWriteTests: XCTestCase {

    private let bookIdentifier = "spy-book-1"
    private let manifestJSON: ManifestJSON = .snowcrash

    private var fakeBook: TPPBook!
    private var mockRegistry: TPPBookRegistryMock!
    private var mockAnnotations: TPPAnnotationMock!
    private var spyWriter: SpyPositionWriter!
    private var sut: AudiobookBookmarkBusinessLogic!
    private var tracks: Tracks!

    override func setUpWithError() throws {
        try super.setUpWithError()

        let url = URL(string: "https://test.example.com/book")!
        let acq = TPPOPDSAcquisition(
            relation: .generic,
            type: "application/epub+zip",
            hrefURL: url,
            indirectAcquisitions: [],
            availability: TPPOPDSAcquisitionAvailabilityUnlimited()
        )
        fakeBook = TPPBook(
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

        mockRegistry = TPPBookRegistryMock()
        mockRegistry.addBook(fakeBook, state: .downloadSuccessful)
        mockAnnotations = TPPAnnotationMock()
        spyWriter = SpyPositionWriter()

        sut = AudiobookBookmarkBusinessLogic(
            book: fakeBook,
            registry: mockRegistry,
            annotationsManager: mockAnnotations,
            positionWriter: spyWriter
        )

        let manifest = try Manifest.from(jsonFileName: manifestJSON.rawValue, bundle: Bundle(for: type(of: self)))
        tracks = Tracks(manifest: manifest, audiobookID: bookIdentifier, token: nil)
    }

    override func tearDown() {
        sut = nil
        spyWriter = nil
        mockAnnotations = nil
        mockRegistry = nil
        fakeBook = nil
        tracks = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// Build a `TrackPosition` for a given track index and timestamp.
    private func position(trackIndex: Int, time: Double) -> TrackPosition {
        TrackPosition(track: tracks.tracks[trackIndex], timestamp: time, tracks: tracks)
    }

    /// Drive `saveListeningPosition` and JOIN its detached network-write Task
    /// deterministically via `_awaitPositionWriteForTesting()` — no wall-clock
    /// `wait(for:timeout:)`. The write runs in a detached `Task` that the
    /// cooperative pool can defer past any fixed timeout under parallel-sim-
    /// clone oversubscription (the parallel-only executionTimeAllowance
    /// blowouts this de-flake targets). Awaiting the retained handle blocks
    /// exactly until the write finishes, independent of pool load, so this
    /// completes in ms even when starved. The completion still supplies the
    /// captured server-ID return value.
    @discardableResult
    private func saveAndWait(position: TrackPosition) async -> String? {
        var captured: String? = nil
        sut.saveListeningPosition(at: position) { result in
            captured = result
        }
        await sut._awaitPositionWriteForTesting()
        return captured
    }

    // MARK: - 1. Local-save-first invariant

    /// Local registry MUST be written before any async write goes out.
    /// This is the swarm_f3b9b087 P0 #4 invariant — a crash/background
    /// between the call and the async hop never loses position state.
    func testSaveListeningPosition_savesLocallyImmediately() {
        let position = position(trackIndex: 1, time: 42.0)
        XCTAssertNil(mockRegistry.location(forIdentifier: bookIdentifier),
                     "Pre-state must have no stored location")

        sut.saveListeningPosition(at: position, completion: nil)

        // The synchronous portion of saveListeningPosition writes locally
        // BEFORE the Task hop. No expectation/wait required.
        let stored = mockRegistry.location(forIdentifier: bookIdentifier)
        XCTAssertNotNil(stored, "Local registry must be written before async work")
        XCTAssertEqual(stored?.renderer, "PalaceAudiobookToolkit")
    }

    // MARK: - 2. Delegation to PositionWriter

    func testSaveListeningPosition_delegatesNetworkSaveToPositionWriter() async {
        spyWriter.saveResult = .success("server-abc")
        let position = position(trackIndex: 1, time: 100.0)

        let returned = await saveAndWait(position: position)

        XCTAssertEqual(spyWriter.savedSnapshots.count, 1,
                       "Writer.save MUST be called exactly once")
        let snap = spyWriter.savedSnapshots[0]
        XCTAssertEqual(snap.bookID, bookIdentifier,
                       "Snapshot bookID must match the SUT's book")
        XCTAssertEqual(snap.format, .audiobook,
                       "Audiobook write path must tag format=.audiobook")
        XCTAssertFalse(snap.payload.isEmpty,
                       "Snapshot must carry the encoded locator payload")
        let decoded = String(data: snap.payload, encoding: .utf8) ?? ""
        XCTAssertTrue(decoded.contains("@type"),
                      "Payload must encode the AudioBookmark locator JSON " +
                      "(must contain '@type'); got: \(decoded)")

        XCTAssertEqual(returned, "server-abc",
                       "On success, completion is called with the server ID")
    }

    // MARK: - 3. Writer throttled → local still committed

    func testSaveListeningPosition_writerThrottled_localStillCommitted() async {
        // Writer returns nil — simulating throttled/queued state. The local
        // save must already be in place; the registry write does not depend
        // on the writer's outcome.
        spyWriter.saveResult = .throttled
        let position = position(trackIndex: 2, time: 200.0)

        let returned = await saveAndWait(position: position)

        XCTAssertNotNil(mockRegistry.location(forIdentifier: bookIdentifier),
                        "Local registry must be written even when writer queues")
        XCTAssertEqual(spyWriter.savedSnapshots.count, 1,
                       "Writer is still called once (and returns nil)")
        XCTAssertNil(returned,
                     "Throttled save resolves completion with nil (no server ID)")
    }

    // MARK: - 4. Writer error → completion called with nil, no crash

    func testSaveListeningPosition_writerError_doesNotCrash_completionCalledWithError() async {
        struct WriterError: Error {}
        spyWriter.saveResult = .failure(WriterError())
        let position = position(trackIndex: 1, time: 50.0)

        let returned = await saveAndWait(position: position)

        XCTAssertNotNil(mockRegistry.location(forIdentifier: bookIdentifier),
                        "Local registry must be preserved when writer throws")
        XCTAssertEqual(spyWriter.savedSnapshots.count, 1)
        XCTAssertNil(returned,
                     "On writer error, completion is called with nil " +
                     "(local is safe; the user's data is not lost)")
    }

    // MARK: - 5. isAtBeginning guard preserved (swarm_f3b9b087 #4)

    /// Pin the swarm_f3b9b087 P0 #4 predicate: when a save is at the
    /// STRICT-ZERO beginning (track 0 AND playbackTime == 0) AND a
    /// later-track position already exists locally, the post-save commit
    /// MUST NOT overwrite the later-track bookmark with the "beginning"
    /// position. The annotationId update is suppressed, preserving the
    /// local later-track state.
    ///
    /// NOTE: this test was originally authored against the legacy `time
    /// < 30s` predicate (PR #980). swarm_f3b9b087 P0 #4 tightened the
    /// predicate to strict-zero (see `AudiobookBookmarkBusinessLogic.swift`
    /// lines 117–125: "Strict zero is correct"). The input below uses
    /// `time: 0` to match the strict-zero contract. A `time: 5.0` input
    /// would (correctly) bypass the guard under the new predicate.
    func testIsAtBeginning_preservedAfterMigration_doesNotOverwriteValidPosition() async throws {
        // Arrange: pre-seed a "later track" position in the registry that
        // a stale beginning-of-book save must NOT clobber. The chapter
        // string is parsed by the predicate at lines 87-89 of the SUT —
        // `currentChapter.split(separator: "-").last` must yield "3".
        let laterBookmark = AudioBookmark(
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
        guard let laterLocation = laterBookmark.toTPPBookLocation() else {
            XCTFail("Failed to build later-track TPPBookLocation")
            return
        }
        // NOTE on test scaffolding: the SUT's `saveListeningPosition` always
        // runs `registry.setLocation(localBookmark)` synchronously BEFORE the
        // async writer hop (the swarm_f3b9b087 P0 #4 "user safety net"
        // invariant). To exercise the isAtBeginning guard scenario, we need
        // the registry to read back the later-track bookmark when the
        // POST-SAVE guard runs — not the beginning bookmark the SUT just
        // wrote. We use the spy's onSave hook to restore the later-track
        // location mid-flight, simulating a parallel write (e.g. the user
        // skipping ahead while the upload is in-flight).
        spyWriter.setOnSave { [weak self] in
            guard let self else { return }
            self.mockRegistry.setLocation(laterLocation, forIdentifier: self.bookIdentifier)
        }

        // Configure writer to "succeed" so we exercise the guard branch
        // that runs AFTER the writer returns.
        spyWriter.saveResult = .success("server-beginning-id")

        // Act: try to save a strict-zero beginning-of-book position
        // (track 0, time == 0). The legacy `< 30s` window was tightened
        // to strict-zero by swarm_f3b9b087 P0 #4; any positive time
        // bypasses the guard under the new predicate.
        let beginningPosition = position(trackIndex: 0, time: 0)
        let returned = await saveAndWait(position: beginningPosition)

        // Assert: writer was called (local-save-first ordering preserved),
        // but the registry location is the ORIGINAL later-track bookmark —
        // the post-save commit was suppressed by the isAtBeginning guard.
        XCTAssertEqual(spyWriter.savedSnapshots.count, 1,
                       "Writer should still be called; the guard runs AFTER save")
        XCTAssertEqual(returned, "server-beginning-id",
                       "Completion still receives server ID on guarded path")

        // Verify the later-track chapter survived — annotationId was NOT
        // overwritten with the new server ID.
        guard let finalLocation = mockRegistry.location(forIdentifier: bookIdentifier),
              let dict = finalLocation.locationStringDictionary(),
              let finalBookmark = AudioBookmark.create(locatorData: dict) else {
            XCTFail("Final registry state missing or malformed")
            return
        }
        XCTAssertEqual(finalBookmark.chapter, "chapter-3",
                       "Later-track chapter MUST survive — beginning save MUST NOT clobber it")
        XCTAssertNotEqual(finalBookmark.annotationId, "server-beginning-id",
                          "AnnotationId from the beginning save MUST NOT be committed")
    }

    // MARK: - 6. Timestamp-newer race-check preserved (swarm_f3b9b087 #4)

    /// Pin the swarm_f3b9b087 P0 #4 race-check predicate: when a save's
    /// timestamp is older than the current local timestamp by more than
    /// the 1.0-second window (the implementation passes `with: 1.0` to
    /// `String.isDate(_:moreRecentThan:with:)`), the post-save commit MUST
    /// be suppressed so a stale upload result cannot overwrite a fresh
    /// local position.
    func testTimestampNewerRace_preservedAfterMigration_keepsLocal() async throws {
        // The sentTimestamp the SUT sets is `Date().iso8601` at the moment
        // of the save call. To make the post-save guard fire, the
        // "fresh local" registry entry must carry a timestamp NEWER than
        // that by more than the 1.0-second grace window. We add a full
        // hour to today's date — well outside any grace window.
        let freshLocalDate = Date().addingTimeInterval(3600)  // +1 hour
        let freshLocalTimestamp = ISO8601DateFormatter().string(from: freshLocalDate)
        // Arrange: pre-seed a "freshly-updated" local position that the
        // post-save guard will compare against.
        let freshLocal = AudioBookmark(
            type: .locatorAudioBookTime,
            version: 1,
            timeStamp: freshLocalTimestamp,
            annotationId: "ann-fresh-local",
            readingOrderItem: "track-2",
            readingOrderItemOffsetMilliseconds: 30_000,
            chapter: "chapter-2",
            title: "Chapter 2",
            part: nil,
            time: 30
        )
        guard let freshLocalLocation = freshLocal.toTPPBookLocation() else {
            XCTFail("Failed to build fresh-local TPPBookLocation")
            return
        }
        // Save the SUT's NEW position first (this sets a stale timestamp
        // string on the bookmark) — then immediately overwrite with the
        // fresh-local bookmark in the registry to simulate "user moved
        // ahead between the write start and the writer resolution."

        // Configure writer to resume only after we mutate registry.
        spyWriter.saveResult = .success("server-stale-id")

        // Act: drive a save whose audiobook lastSavedTimeStamp will be the
        // current Date(). To make the comparison meaningful, we replace
        // the registry value AFTER the synchronous local save but BEFORE
        // the writer resolves. The simplest way to control this is to
        // do the local-overwrite inside the spy's save() hook.
        final class TimeRaceWriter: PositionWriter, @unchecked Sendable {
            let onSave: () -> Void
            init(onSave: @escaping () -> Void) { self.onSave = onSave }
            func save(_ snapshot: PositionSnapshot) async throws -> ServerPositionID? {
                onSave()
                return "server-stale-id"
            }
            func load(for bookID: String) async throws -> PositionSnapshot? { nil }
            func cancel(for bookID: String) async {}
        }
        let raceWriter = TimeRaceWriter { [weak self] in
            // Simulate "user moved ahead" between snapshot capture and
            // writer response — overwrite the registry with a fresher
            // local bookmark.
            self?.mockRegistry.setLocation(freshLocalLocation,
                                           forIdentifier: self?.bookIdentifier ?? "")
        }
        sut = AudiobookBookmarkBusinessLogic(
            book: fakeBook,
            registry: mockRegistry,
            annotationsManager: mockAnnotations,
            positionWriter: raceWriter
        )

        let stalePosition = position(trackIndex: 0, time: 5.0)
        let returned = await saveAndWait(position: stalePosition)

        // Assert: completion received the server ID (post-save flow did
        // run) but the registry retains the fresh-local bookmark — the
        // stale server-assigned annotationId was NOT committed.
        XCTAssertEqual(returned, "server-stale-id",
                       "Completion still receives server ID on race-check guard path")
        guard let finalLocation = mockRegistry.location(forIdentifier: bookIdentifier),
              let dict = finalLocation.locationStringDictionary(),
              let finalBookmark = AudioBookmark.create(locatorData: dict) else {
            XCTFail("Final registry state missing or malformed")
            return
        }
        XCTAssertEqual(finalBookmark.annotationId, "ann-fresh-local",
                       "Fresh-local annotationId MUST survive a stale upload result")
        XCTAssertEqual(finalBookmark.chapter, "chapter-2",
                       "Fresh-local chapter MUST survive a stale upload result")
    }
}
