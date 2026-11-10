//
//  AudiobookAutosaveRegistryWriteTests.swift
//  PalaceTests
//
//  PP-5500: each audiobook autosave persists the registry once, whatever the
//  annotation post returns, and the stored location still ends up carrying the
//  server annotation id when the post succeeds.
//
//  Copyright 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace
@testable import PalaceAudiobookToolkit
import PalaceReadingPosition
import PalaceBookModel
@testable import PalaceBookRegistry

/// Returns a fixed outcome for every position post.
private final class StubPositionWriter: PositionWriter, @unchecked Sendable {
    enum Outcome {
        case posted(ServerPositionID)
        case queued
        case failed
    }

    struct Failure: Error {}

    private let lock = NSLock()
    private var _outcome: Outcome = .posted("stub-server-id")
    private var _onSave: (() -> Void)?

    var outcome: Outcome {
        get { lock.withLock { _outcome } }
        set { lock.withLock { _outcome = newValue } }
    }

    /// Runs between the local write and the conflict check, to stage a newer
    /// local position.
    func setOnSave(_ hook: @escaping () -> Void) {
        lock.withLock { _onSave = hook }
    }

    func save(_ snapshot: PositionSnapshot) async throws -> ServerPositionID? {
        let (outcome, hook) = lock.withLock { (_outcome, _onSave) }
        hook?()
        switch outcome {
        case .posted(let id): return id
        case .queued: return nil
        case .failed: throw Failure()
        }
    }

    func load(for bookID: String) async throws -> PositionSnapshot? { nil }
    func cancel(for bookID: String) async {}
}

/// Routes location reads and writes through the production `BookmarkManager`
/// and counts the registry persists it asks for.
private final class PersistCountingRegistry: TPPBookRegistryMock, @unchecked Sendable {
    let store = BookRegistryStore()
    private(set) var manager: BookmarkManager!
    private let lock = NSLock()
    private var _persistCount = 0

    var persistCount: Int { lock.withLock { _persistCount } }

    override init() {
        super.init()
        let count: (String) -> Void = { [weak self] _ in
            guard let self else { return }
            self.lock.withLock { self._persistCount += 1 }
        }
        manager = BookmarkManager(store: store, save: count, savePosition: { account, _ in count(account) }, saveSync: count)
    }

    override func addBook(_ book: TPPBook, location: TPPBookLocation? = nil, state: TPPBookState, fulfillmentId: String? = nil, readiumBookmarks: [TPPReadiumBookmark]? = nil, genericBookmarks: [TPPBookLocation]? = nil) {
        super.addBook(book, location: location, state: state, fulfillmentId: fulfillmentId,
                      readiumBookmarks: readiumBookmarks, genericBookmarks: genericBookmarks)
        let added = DispatchSemaphore(value: 0)
        store.addBook(book, state: state, genericBookmarks: genericBookmarks ?? []) { _ in added.signal() }
        added.wait()
    }

    override func setLocation(_ location: TPPBookLocation?, forIdentifier identifier: String) {
        manager.setLocation(location, forIdentifier: identifier, account: "persist-counting-account")
    }

    override func setLocationDeferringSave(_ location: TPPBookLocation?, forIdentifier identifier: String) {
        manager.setLocationDeferringSave(location, forIdentifier: identifier)
    }

    override func location(forIdentifier identifier: String) -> TPPBookLocation? {
        manager.location(forIdentifier: identifier)
    }
}

@MainActor
final class AudiobookAutosaveRegistryWriteTests: XCTestCase {

    private let bookIdentifier = "autosave-write-book"

    private var registry: PersistCountingRegistry!
    private var writer: StubPositionWriter!
    private var sut: AudiobookBookmarkBusinessLogic!
    private var tracks: Tracks!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let book = TPPBookMocker.mockBook(identifier: bookIdentifier, title: "Autosave", distributorType: .OpenAccessAudiobook)
        registry = PersistCountingRegistry()
        registry.addBook(book, state: .downloadSuccessful)
        writer = StubPositionWriter()
        sut = AudiobookBookmarkBusinessLogic(
            book: book,
            registry: registry,
            annotationsManager: TPPAnnotationMock(),
            positionWriter: writer
        )
        let manifest = try Manifest.from(jsonFileName: ManifestJSON.snowcrash.rawValue, bundle: Bundle(for: type(of: self)))
        tracks = Tracks(manifest: manifest, audiobookID: bookIdentifier, token: nil)
    }

    override func tearDown() {
        sut = nil
        writer = nil
        registry = nil
        tracks = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func position(trackIndex: Int, time: Double) -> TrackPosition {
        TrackPosition(track: tracks.tracks[trackIndex], timestamp: time, tracks: tracks)
    }

    /// Runs one autosave to completion, including the registry's queued writes,
    /// and returns how many registry persists it caused.
    private func persistsDuringOneAutosave(at position: TrackPosition) async -> Int {
        await registry.store._awaitPendingWritesForTesting()
        let before = registry.persistCount
        sut.saveListeningPosition(at: position, completion: nil)
        await sut._awaitPositionWriteForTesting()
        await registry.store._awaitPendingWritesForTesting()
        return registry.persistCount - before
    }

    private func storedBookmark() throws -> AudioBookmark {
        let location = try XCTUnwrap(registry.location(forIdentifier: bookIdentifier))
        let dict = try XCTUnwrap(location.locationStringDictionary())
        return try XCTUnwrap(AudioBookmark.create(locatorData: dict))
    }

    // MARK: - Tests

    func testAutosave_WhenPostReturnsAnnotationId_PersistsOnceAndStoresTheId() async throws {
        writer.outcome = .posted("https://example.org/annotations/42")

        let persists = await persistsDuringOneAutosave(at: position(trackIndex: 2, time: 37))

        XCTAssertEqual(persists, 1, "an online autosave must persist the registry once")
        let stored = try storedBookmark()
        XCTAssertEqual(stored.annotationId, "https://example.org/annotations/42")
        XCTAssertEqual(stored.readingOrderItem, tracks.tracks[2].key)
        XCTAssertEqual(stored.readingOrderItemOffsetMilliseconds, 37_000)
    }

    func testAutosave_WhenPostFails_PersistsOnceAndStoresThePositionWithoutAnId() async throws {
        writer.outcome = .failed

        let persists = await persistsDuringOneAutosave(at: position(trackIndex: 1, time: 12))

        XCTAssertEqual(persists, 1)
        let stored = try storedBookmark()
        XCTAssertEqual(stored.annotationId, "")
        XCTAssertEqual(stored.readingOrderItem, tracks.tracks[1].key)
        XCTAssertEqual(stored.readingOrderItemOffsetMilliseconds, 12_000)
    }

    func testAutosave_WhenPostIsQueuedOffline_PersistsOnceAndStoresThePositionWithoutAnId() async throws {
        writer.outcome = .queued

        let persists = await persistsDuringOneAutosave(at: position(trackIndex: 3, time: 5))

        XCTAssertEqual(persists, 1)
        let stored = try storedBookmark()
        XCTAssertEqual(stored.annotationId, "")
        XCTAssertEqual(stored.readingOrderItem, tracks.tracks[3].key)
        XCTAssertEqual(stored.readingOrderItemOffsetMilliseconds, 5_000)
    }

    /// The id commit must not replace a newer local position written while the
    /// post was in flight.
    func testAutosave_WhenANewerLocalPositionLandsDuringThePost_KeepsTheNewerPositionWithoutTheId() async throws {
        writer.outcome = .posted("https://example.org/annotations/stale")
        let newer = position(trackIndex: 4, time: 90).toAudioBookmark()
        newer.lastSavedTimeStamp = "2999-01-01T00:00:00Z"
        let newerLocation = try XCTUnwrap(newer.toTPPBookLocation())
        writer.setOnSave { [registry, bookIdentifier] in
            registry?.manager.setLocation(newerLocation, forIdentifier: bookIdentifier, account: nil)
        }

        _ = await persistsDuringOneAutosave(at: position(trackIndex: 2, time: 37))

        let stored = try storedBookmark()
        XCTAssertEqual(stored.readingOrderItem, tracks.tracks[4].key)
        XCTAssertEqual(stored.annotationId, "")
    }
}
