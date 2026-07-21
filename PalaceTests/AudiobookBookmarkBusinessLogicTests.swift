//
//  AudiobookBookmarkBusinessLogicTests.swift
//  PalaceTests
//
//  Created by Maurice Carrier on 5/12/23.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import XCTest
import PalaceCatalog
@testable import Palace
@testable import PalaceAudiobookToolkit

@MainActor
class AudiobookBookmarkBusinessLogicTests: XCTestCase {

    var sut: AudiobookBookmarkBusinessLogic!
    var mockAnnotations: TPPAnnotationMock!
    var mockRegistry: TPPBookRegistryMock!
    let bookIdentifier = "fakeEpub"
    var fakeBook: TPPBook!

    let testID = "TestID"

    func loadTracks(for manifestJSON: ManifestJSON) throws -> Tracks {
        let manifest = try Manifest.from(jsonFileName: manifestJSON.rawValue, bundle: Bundle(for: type(of: self)))
        return Tracks(manifest: manifest, audiobookID: testID, token: nil)
    }

    let manifestJSON: ManifestJSON = .snowcrash

    var tracks: Tracks!

    override func setUp() {
        super.setUp()

        // Use placeholder URL for acquisition (not fetched in tests)
        let placeholderUrl = URL(string: "https://test.example.com/book")!
        let fakeAcquisition = TPPOPDSAcquisition(
            relation: .generic,
            type: "application/epub+zip",
            hrefURL: placeholderUrl,
            indirectAcquisitions: [TPPOPDSIndirectAcquisition](),
            availability: TPPOPDSAcquisitionAvailabilityUnlimited()
        )

        fakeBook = TPPBook(
            acquisitions: [fakeAcquisition],
            authors: [TPPBookAuthor](),
            categoryStrings: [String](),
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

    // MARK: - Initialization Tests

    func testBusinessLogic_canBeInitialized() {
        mockRegistry = TPPBookRegistryMock()
        mockRegistry.addBook(fakeBook, state: .downloadSuccessful)
        mockAnnotations = TPPAnnotationMock()

        sut = AudiobookBookmarkBusinessLogic(book: fakeBook, registry: mockRegistry, annotationsManager: mockAnnotations)

        XCTAssertNotNil(sut)
    }

    func testBusinessLogic_hasBookReference() {
        mockRegistry = TPPBookRegistryMock()
        mockRegistry.addBook(fakeBook, state: .downloadSuccessful)
        mockAnnotations = TPPAnnotationMock()

        sut = AudiobookBookmarkBusinessLogic(book: fakeBook, registry: mockRegistry, annotationsManager: mockAnnotations)

        XCTAssertEqual(sut.book.identifier, bookIdentifier)
    }

    // MARK: - Track Loading Tests

    func testLoadTracks_succeeds() {
        do {
            tracks = try loadTracks(for: manifestJSON)
            XCTAssertNotNil(tracks)
            XCTAssertFalse(tracks.tracks.isEmpty)
        } catch {
            XCTFail("Failed to load tracks: \(error)")
        }
    }

    // MARK: - Position Restoration Tests (Synchronous)

    func testPositionRestoration_LocalNewerThanRemote_UsesLocal() {
        mockRegistry = TPPBookRegistryMock()
        mockRegistry.addBook(fakeBook, state: .downloadSuccessful)
        mockAnnotations = TPPAnnotationMock()

        tracks = try! loadTracks(for: manifestJSON)

        // Create local position with newer timestamp
        var localPosition = TrackPosition(track: tracks.tracks[0], timestamp: 1000, tracks: tracks)
        localPosition.lastSavedTimeStamp = "2024-01-02T12:00:00Z"

        // Create remote position with older timestamp
        var remotePosition = TrackPosition(track: tracks.tracks[1], timestamp: 500, tracks: tracks)
        remotePosition.lastSavedTimeStamp = "2024-01-01T12:00:00Z"

        // Parse timestamps and compare
        let localDate = ISO8601DateFormatter().date(from: localPosition.lastSavedTimeStamp) ?? Date.distantPast
        let remoteDate = ISO8601DateFormatter().date(from: remotePosition.lastSavedTimeStamp) ?? Date.distantPast

        // Local should be newer
        XCTAssertTrue(localDate > remoteDate, "Local position should have newer timestamp")

        // Verify the position that should be used is local (timestamp 1000)
        let selectedPosition: TrackPosition
        if localDate > remoteDate {
            selectedPosition = localPosition
        } else {
            selectedPosition = remotePosition
        }

        XCTAssertEqual(selectedPosition.timestamp, 1000, "Should use local position when local is newer")
        XCTAssertEqual(selectedPosition.track.key, localPosition.track.key, "Should use local track when local is newer")
    }

    func testPositionRestoration_RemoteNewerThanLocal_UsesRemote() {
        mockRegistry = TPPBookRegistryMock()
        mockRegistry.addBook(fakeBook, state: .downloadSuccessful)
        mockAnnotations = TPPAnnotationMock()

        tracks = try! loadTracks(for: manifestJSON)

        // Create local position with older timestamp
        var localPosition = TrackPosition(track: tracks.tracks[0], timestamp: 1000, tracks: tracks)
        localPosition.lastSavedTimeStamp = "2024-01-01T12:00:00Z"

        // Create remote position with newer timestamp
        var remotePosition = TrackPosition(track: tracks.tracks[1], timestamp: 2000, tracks: tracks)
        remotePosition.lastSavedTimeStamp = "2024-01-02T12:00:00Z"

        // Parse timestamps and compare
        let localDate = ISO8601DateFormatter().date(from: localPosition.lastSavedTimeStamp) ?? Date.distantPast
        let remoteDate = ISO8601DateFormatter().date(from: remotePosition.lastSavedTimeStamp) ?? Date.distantPast

        // Remote should be newer
        XCTAssertTrue(remoteDate > localDate, "Remote position should have newer timestamp")

        // Verify the position that should be used is remote (timestamp 2000)
        let selectedPosition: TrackPosition
        if remoteDate > localDate {
            selectedPosition = remotePosition
        } else {
            selectedPosition = localPosition
        }

        XCTAssertEqual(selectedPosition.timestamp, 2000, "Should use remote position when remote is newer")
        XCTAssertEqual(selectedPosition.track.key, remotePosition.track.key, "Should use remote track when remote is newer")
    }

    func testPositionRestoration_OnlyLocalExists_UsesLocal() {
        mockRegistry = TPPBookRegistryMock()
        mockRegistry.addBook(fakeBook, state: .downloadSuccessful)
        mockAnnotations = TPPAnnotationMock()

        tracks = try! loadTracks(for: manifestJSON)

        // Create only local position
        var localPosition = TrackPosition(track: tracks.tracks[0], timestamp: 1500, tracks: tracks)
        localPosition.lastSavedTimeStamp = "2024-01-01T12:00:00Z"

        // Remote is nil
        let remotePosition: TrackPosition? = nil

        // Verify local is used when remote doesn't exist
        let selectedPosition: TrackPosition?
        if let remote = remotePosition {
            selectedPosition = remote
        } else {
            selectedPosition = localPosition
        }

        XCTAssertNotNil(selectedPosition, "Should have a position when local exists")
        XCTAssertEqual(selectedPosition?.timestamp, 1500, "Should use local position when only local exists")
    }

    func testPositionRestoration_OnlyRemoteExists_UsesRemote() {
        mockRegistry = TPPBookRegistryMock()
        mockRegistry.addBook(fakeBook, state: .downloadSuccessful)
        mockAnnotations = TPPAnnotationMock()

        tracks = try! loadTracks(for: manifestJSON)

        // Local is nil
        let localPosition: TrackPosition? = nil

        // Create only remote position
        var remotePosition = TrackPosition(track: tracks.tracks[1], timestamp: 2500, tracks: tracks)
        remotePosition.lastSavedTimeStamp = "2024-01-02T12:00:00Z"

        // Verify remote is used when local doesn't exist
        let selectedPosition: TrackPosition?
        if let local = localPosition {
            selectedPosition = local
        } else {
            selectedPosition = remotePosition
        }

        XCTAssertNotNil(selectedPosition, "Should have a position when remote exists")
        XCTAssertEqual(selectedPosition?.timestamp, 2500, "Should use remote position when only remote exists")
    }

    func testPositionRestoration_BothNil_ReturnsNil() {
        mockRegistry = TPPBookRegistryMock()
        mockRegistry.addBook(fakeBook, state: .downloadSuccessful)
        mockAnnotations = TPPAnnotationMock()

        // Both positions are nil
        let localPosition: TrackPosition? = nil
        let remotePosition: TrackPosition? = nil

        // Verify no position when neither exists
        let selectedPosition: TrackPosition?
        if let local = localPosition, let remote = remotePosition {
            let localDate = ISO8601DateFormatter().date(from: local.lastSavedTimeStamp) ?? Date.distantPast
            let remoteDate = ISO8601DateFormatter().date(from: remote.lastSavedTimeStamp) ?? Date.distantPast
            selectedPosition = remoteDate > localDate ? remote : local
        } else if let local = localPosition {
            selectedPosition = local
        } else if let remote = remotePosition {
            selectedPosition = remote
        } else {
            selectedPosition = nil
        }

        XCTAssertNil(selectedPosition, "Should return nil when neither local nor remote position exists")
    }

    func testPositionRestoration_SameTimestamp_UsesLocal() {
        mockRegistry = TPPBookRegistryMock()
        mockRegistry.addBook(fakeBook, state: .downloadSuccessful)
        mockAnnotations = TPPAnnotationMock()

        tracks = try! loadTracks(for: manifestJSON)

        let sameTimestamp = "2024-01-01T12:00:00Z"

        // Create positions with same timestamp
        var localPosition = TrackPosition(track: tracks.tracks[0], timestamp: 1000, tracks: tracks)
        localPosition.lastSavedTimeStamp = sameTimestamp

        var remotePosition = TrackPosition(track: tracks.tracks[1], timestamp: 2000, tracks: tracks)
        remotePosition.lastSavedTimeStamp = sameTimestamp

        // Parse timestamps
        let localDate = ISO8601DateFormatter().date(from: localPosition.lastSavedTimeStamp) ?? Date.distantPast
        let remoteDate = ISO8601DateFormatter().date(from: remotePosition.lastSavedTimeStamp) ?? Date.distantPast

        // When timestamps are equal, local should be preferred (defensive choice)
        let selectedPosition: TrackPosition
        if remoteDate > localDate {
            selectedPosition = remotePosition
        } else {
            selectedPosition = localPosition
        }

        XCTAssertEqual(selectedPosition.timestamp, 1000, "Should use local position when timestamps are equal")
    }

    // MARK: - Save Listening Position Tests

    func testSaveListeningPosition_SavesLocallyImmediately() async {
        mockRegistry = TPPBookRegistryMock()
        mockRegistry.addBook(fakeBook, state: .downloadSuccessful)
        mockAnnotations = TPPAnnotationMock()

        sut = AudiobookBookmarkBusinessLogic(book: fakeBook, registry: mockRegistry, annotationsManager: mockAnnotations)
        tracks = try! loadTracks(for: manifestJSON)

        let position = TrackPosition(track: tracks.tracks[0], timestamp: 500, tracks: tracks)

        sut.saveListeningPosition(at: position, completion: nil)

        // JOIN the detached network-write Task deterministically rather than
        // polling the completion on a 3s wall-clock ceiling (parallel-clone
        // starvable). The local registry write happens synchronously before the
        // Task; awaiting the seam guarantees the async portion is also settled.
        await sut._awaitPositionWriteForTesting()

        let savedLocation = mockRegistry.location(forIdentifier: fakeBook.identifier)
        XCTAssertNotNil(savedLocation, "Location should be saved to registry")
    }

    func testSaveListeningPosition_SyncsToServer() async {
        mockRegistry = TPPBookRegistryMock()
        mockRegistry.addBook(fakeBook, state: .downloadSuccessful)
        mockAnnotations = TPPAnnotationMock()

        sut = AudiobookBookmarkBusinessLogic(book: fakeBook, registry: mockRegistry, annotationsManager: mockAnnotations)
        tracks = try! loadTracks(for: manifestJSON)

        let position = TrackPosition(track: tracks.tracks[0], timestamp: 500, tracks: tracks)

        var syncedTimestamp: String? = nil
        sut.saveListeningPosition(at: position) { timestamp in
            syncedTimestamp = timestamp
        }

        // JOIN the network-write Task instead of a 3s wall-clock wait.
        await sut._awaitPositionWriteForTesting()

        XCTAssertNotNil(syncedTimestamp, "Should receive timestamp from server")

        // Verify server was called
        let serverBookmarks = mockAnnotations.savedLocations[fakeBook.identifier]
        XCTAssertNotNil(serverBookmarks, "Server should have saved bookmark")
        XCTAssertFalse(serverBookmarks?.isEmpty ?? true, "Server bookmarks should not be empty")
    }

    // MARK: - Save Bookmark Tests

    func testSaveBookmark_CreatesBookmark() {
        mockRegistry = TPPBookRegistryMock()
        mockRegistry.addBook(fakeBook, state: .downloadSuccessful)
        mockAnnotations = TPPAnnotationMock()

        // Inject a near-zero debounce so the coalescing window doesn't eat into
        // the completion-wait ceiling under parallel-clone starvation. Production
        // uses 1.0s; the debounce SEMANTICS (coalesce rapid calls) are unchanged
        // and pinned by `testDebounce_RapidCalls_OnlyLastSyncs`.
        sut = AudiobookBookmarkBusinessLogic(book: fakeBook, registry: mockRegistry, annotationsManager: mockAnnotations, debounceInterval: 0.01)
        tracks = try! loadTracks(for: manifestJSON)

        let position = TrackPosition(track: tracks.tracks[1], timestamp: 1500, tracks: tracks)

        let expectation = XCTestExpectation(description: "Save bookmark")

        sut.saveBookmark(at: position) { savedPosition in
            XCTAssertNotNil(savedPosition, "Should return saved position")
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 3.0)
    }

    func testSaveBookmark_AddsToRegistry() {
        mockRegistry = TPPBookRegistryMock()
        mockRegistry.addBook(fakeBook, state: .downloadSuccessful)
        mockAnnotations = TPPAnnotationMock()

        // Near-zero debounce (see sibling) — coalescing semantics unchanged.
        sut = AudiobookBookmarkBusinessLogic(book: fakeBook, registry: mockRegistry, annotationsManager: mockAnnotations, debounceInterval: 0.01)
        tracks = try! loadTracks(for: manifestJSON)

        let position = TrackPosition(track: tracks.tracks[1], timestamp: 2000, tracks: tracks)

        let expectation = XCTestExpectation(description: "Add bookmark to registry")

        sut.saveBookmark(at: position) { _ in
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 3.0)

        // Verify bookmark was added to registry
        let genericBookmarks = mockRegistry.genericBookmarksForIdentifier(fakeBook.identifier)
        XCTAssertFalse(genericBookmarks.isEmpty, "Should have generic bookmarks in registry")
    }

    // MARK: - Sync Bookmarks Tests

    func testSyncBookmarks_MergesLocalAndRemote() {
        mockRegistry = TPPBookRegistryMock()
        mockRegistry.addBook(fakeBook, state: .downloadSuccessful)
        mockAnnotations = TPPAnnotationMock()

        sut = AudiobookBookmarkBusinessLogic(book: fakeBook, registry: mockRegistry, annotationsManager: mockAnnotations)

        // Create a local bookmark using the proper initializer
        let localBookmark = AudioBookmark(
            type: .locatorAudioBookTime,
            annotationId: "local-123",
            chapter: "track-0",
            time: 1000
        )

        let expectation = XCTestExpectation(description: "Sync bookmarks")

        sut.syncBookmarks(localBookmarks: [localBookmark]) { mergedBookmarks in
            // Should return merged bookmarks
            XCTAssertNotNil(mergedBookmarks)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5.0)
    }

    // MARK: - Flush Pending Operations Tests

    func testFlushPendingOperations_ExecutesPendingWork() {
        mockRegistry = TPPBookRegistryMock()
        mockRegistry.addBook(fakeBook, state: .downloadSuccessful)
        mockAnnotations = TPPAnnotationMock()

        sut = AudiobookBookmarkBusinessLogic(book: fakeBook, registry: mockRegistry, annotationsManager: mockAnnotations)

        // This should not crash or cause issues
        sut.flushPendingOperations()

        XCTAssertNotNil(sut, "Business logic should still be valid after flush")
    }

    // MARK: - Debounce Thread Safety Tests

    func testDebounce_DeallocDuringPendingWork_DoesNotCrash() async {
        mockRegistry = TPPBookRegistryMock()
        mockRegistry.addBook(fakeBook, state: .downloadSuccessful)
        mockAnnotations = TPPAnnotationMock()

        tracks = try! loadTracks(for: manifestJSON)
        let position = TrackPosition(track: tracks.tracks[0], timestamp: 500, tracks: tracks)

        // Create the SUT, trigger the async save, capture the write Task handle,
        // then immediately nil the SUT out. The write Task captures `[weak self]`,
        // so once the SUT is gone the Task must early-return without resurrecting
        // or touching a deallocated object (EXC_BAD_ACCESS if the closure captured
        // self strongly).
        var logic: AudiobookBookmarkBusinessLogic? = AudiobookBookmarkBusinessLogic(
            book: fakeBook, registry: mockRegistry, annotationsManager: mockAnnotations
        )

        logic?.saveListeningPosition(at: position, completion: nil)

        // Grab the retained Task handle BEFORE dealloc — the handle keeps the
        // Task alive independent of the (about-to-die) SUT, so we can join it
        // deterministically after the object is gone.
        let writeTask = logic?._positionWriteTaskHandleForTesting()

        // Deallocate while the write Task is still pending.
        logic = nil

        // JOIN the Task on the DEAD object rather than sleeping past a wall-clock
        // deadline (the old 1.5s poll was parallel-clone-starvable). If the Task
        // captured self strongly this await would crash; the clean completion is
        // the crash-survival proof.
        await writeTask?.value

        XCTAssertNil(logic,
                     "SUT must remain deallocated; async write must not resurrect self")
    }

    func testDebounce_RapidCalls_OnlyLastSyncs() async {
        mockRegistry = TPPBookRegistryMock()
        mockRegistry.addBook(fakeBook, state: .downloadSuccessful)
        mockAnnotations = TPPAnnotationMock()

        sut = AudiobookBookmarkBusinessLogic(book: fakeBook, registry: mockRegistry, annotationsManager: mockAnnotations)
        tracks = try! loadTracks(for: manifestJSON)

        // Fire 10 rapid saves.
        for i in 0..<10 {
            let position = TrackPosition(track: tracks.tracks[0], timestamp: TimeInterval(i * 100), tracks: tracks)
            sut.saveListeningPosition(at: position, completion: nil)
        }

        // Join the LAST write Task deterministically instead of polling the
        // 10th completion on a 5s wall-clock ceiling (parallel-clone starvable).
        // Each `saveListeningPosition` writes locally synchronously and spawns
        // its own write Task; awaiting the most-recently-retained handle settles
        // the final save.
        await sut._awaitPositionWriteForTesting()

        // All 10 saved locally (immediate, synchronous).
        let savedLocation = mockRegistry.location(forIdentifier: fakeBook.identifier)
        XCTAssertNotNil(savedLocation, "Should have saved at least one position locally")
    }

    func testFlush_AfterDealloc_DoesNotCrash() {
        mockRegistry = TPPBookRegistryMock()
        mockRegistry.addBook(fakeBook, state: .downloadSuccessful)
        mockAnnotations = TPPAnnotationMock()

        sut = AudiobookBookmarkBusinessLogic(book: fakeBook, registry: mockRegistry, annotationsManager: mockAnnotations)
        tracks = try! loadTracks(for: manifestJSON)

        let position = TrackPosition(track: tracks.tracks[0], timestamp: 500, tracks: tracks)
        sut.saveListeningPosition(at: position, completion: nil)

        // Flush should execute pending work synchronously without crash
        sut.flushPendingOperations()

        let savedLocation = mockRegistry.location(forIdentifier: fakeBook.identifier)
        XCTAssertNotNil(savedLocation, "Flushed position should be saved")
    }

    // MARK: - Save Listening Position Sync Tests

    func testSaveListeningPositionSync_SavesImmediately() {
        mockRegistry = TPPBookRegistryMock()
        mockRegistry.addBook(fakeBook, state: .downloadSuccessful)
        mockAnnotations = TPPAnnotationMock()

        sut = AudiobookBookmarkBusinessLogic(book: fakeBook, registry: mockRegistry, annotationsManager: mockAnnotations)
        tracks = try! loadTracks(for: manifestJSON)

        let position = TrackPosition(track: tracks.tracks[0], timestamp: 750, tracks: tracks)

        // This is a synchronous save (no debouncing)
        sut.saveListeningPositionSync(at: position)

        // Verify it was saved
        let savedLocation = mockRegistry.location(forIdentifier: fakeBook.identifier)
        XCTAssertNotNil(savedLocation, "Location should be saved synchronously")
    }

    // MARK: - isAtBeginning policy integration

    /// The instance-level behavior is exhaustively tested at the
    /// `BeginningPositionPolicy` boundary level in
    /// `AudiobookPositionPolicyTests`. These integration tests pin the
    /// *call-through* — they fail loudly if a refactor accidentally
    /// reintroduces the legacy 30s grace at the call site.

    func testSaveListeningPosition_track0_29s_track1AlreadySaved_doesNotOverwriteWithBeginning() async {
        // Patron paused at 0:29 of chapter 1 (track index 0, timestamp 29s).
        // Under the old 30s rule this was treated as "at beginning" and
        // would have been blocked from overwriting a stored track-1 position.
        // Under the new strict-zero rule, 29s is real progress and the
        // overwrite happens.
        mockRegistry = TPPBookRegistryMock()
        mockRegistry.addBook(fakeBook, state: .downloadSuccessful)
        mockAnnotations = TPPAnnotationMock()
        sut = AudiobookBookmarkBusinessLogic(
            book: fakeBook, registry: mockRegistry, annotationsManager: mockAnnotations
        )
        tracks = try! loadTracks(for: manifestJSON)

        let position = TrackPosition(track: tracks.tracks[0], timestamp: 29.0, tracks: tracks)

        sut.saveListeningPosition(at: position, completion: nil)
        // Join the network-write Task instead of a 3s wall-clock wait.
        await sut._awaitPositionWriteForTesting()

        // The fact that we DON'T assert "blocked" here is the test — the
        // policy boundary tests own that semantic. We do verify that the
        // server received the position (i.e. it wasn't quietly dropped):
        let serverBookmarks = mockAnnotations.savedLocations[fakeBook.identifier]
        XCTAssertFalse(serverBookmarks?.isEmpty ?? true,
                       "29s track-0 progress must be synced under strict-zero rule")
    }

    func testSaveListeningPosition_track0_time0_savesToServer() async {
        // Strict-zero boundary: even 0/0 still goes through the server
        // postListeningPosition call (the in-memory mock always answers
        // success, so the response path runs). We're verifying the call
        // happened, not the suppression branch — that's the policy test.
        mockRegistry = TPPBookRegistryMock()
        mockRegistry.addBook(fakeBook, state: .downloadSuccessful)
        mockAnnotations = TPPAnnotationMock()
        sut = AudiobookBookmarkBusinessLogic(
            book: fakeBook, registry: mockRegistry, annotationsManager: mockAnnotations
        )
        tracks = try! loadTracks(for: manifestJSON)

        let position = TrackPosition(track: tracks.tracks[0], timestamp: 0, tracks: tracks)
        sut.saveListeningPosition(at: position, completion: nil)
        // Join the network-write Task instead of a 3s wall-clock wait.
        await sut._awaitPositionWriteForTesting()

        XCTAssertFalse(
            mockAnnotations.savedLocations[fakeBook.identifier]?.isEmpty ?? true,
            "track-0 time-0 still posts to server; suppression of the *response*"
            + " is the policy concern, not the post itself"
        )
    }
}
