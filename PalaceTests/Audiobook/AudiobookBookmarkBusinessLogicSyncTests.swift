//
//  AudiobookBookmarkBusinessLogicSyncTests.swift
//  PalaceTests
//
//  Audiobook bookmark sync against a server that returns, rejects or keeps
//  bookmarks: merge, upload of unsynced bookmarks, and deletes that must not
//  come back on the next sync.
//

import XCTest
import PalaceCatalog
@testable import Palace
@testable import PalaceAudiobookToolkit
import PalaceBookModel

@MainActor
final class AudiobookBookmarkBusinessLogicSyncTests: XCTestCase {

    /// Scriptable server. Calls arrive from the SUT's work queue and Tasks, so
    /// all state sits behind one lock.
    private final class ScriptedAnnotationsServer: NSObject, AnnotationsManager, @unchecked Sendable {
        private let lock = NSLock()
        private var _serverBookmarks: [Bookmark]?
        private var _deleteResults: [String: Bool] = [:]
        private var _deleteCalls: [String] = []
        private var _postedSelectors: [String] = []
        private var _postOutcome: Result<AnnotationResponse?, Error> = .success(nil)

        var serverBookmarks: [Bookmark]? {
            get { lock.withLock { _serverBookmarks } }
            set { lock.withLock { _serverBookmarks = newValue } }
        }
        /// Result per annotation ID; IDs not listed succeed.
        var deleteResults: [String: Bool] {
            get { lock.withLock { _deleteResults } }
            set { lock.withLock { _deleteResults = newValue } }
        }
        var postOutcome: Result<AnnotationResponse?, Error> {
            get { lock.withLock { _postOutcome } }
            set { lock.withLock { _postOutcome = newValue } }
        }
        var deleteCalls: [String] { lock.withLock { _deleteCalls } }
        var postedSelectors: [String] { lock.withLock { _postedSelectors } }

        var syncIsPossibleAndPermitted: Bool { true }

        func postListeningPosition(forBook bookID: String, selectorValue: String, completion: ((AnnotationResponse?) -> Void)?) {
            completion?(nil)
        }

        func postAudiobookBookmark(forBook bookID: String, selectorValue: String) async throws -> AnnotationResponse? {
            let outcome: Result<AnnotationResponse?, Error> = lock.withLock {
                _postedSelectors.append(selectorValue)
                return _postOutcome
            }
            return try outcome.get()
        }

        func getServerBookmarks(forBook book: TPPBook?, atURL annotationURL: URL?, motivation: TPPBookmarkSpec.Motivation, completion: @escaping ([Bookmark]?) -> Void) {
            completion(serverBookmarks)
        }

        func deleteBookmark(annotationId: String, completionHandler: @escaping (Bool) -> Void) {
            let result: Bool = lock.withLock {
                _deleteCalls.append(annotationId)
                return _deleteResults[annotationId] ?? true
            }
            completionHandler(result)
        }

        func deleteAllBookmarks(forBook book: TPPBook, completion: @escaping () -> Void) {
            completion()
        }
    }

    private let bookIdentifier = "urn:uuid:sync-tests-audiobook"
    private var book: TPPBook!
    private var registry: TPPBookRegistryMock!
    private var server: ScriptedAnnotationsServer!
    private var sut: AudiobookBookmarkBusinessLogic!
    private var tracks: Tracks!

    override func setUp() {
        super.setUp()
        book = TPPBook(
            acquisitions: [TPPOPDSAcquisition(
                relation: .generic,
                type: "application/audiobook+json",
                hrefURL: URL(string: "https://test.example.com/audiobook")!,
                indirectAcquisitions: [],
                availability: TPPOPDSAcquisitionAvailabilityUnlimited()
            )],
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
        registry = TPPBookRegistryMock()
        registry.addBook(book, state: .downloadSuccessful)
        server = ScriptedAnnotationsServer()
        sut = AudiobookBookmarkBusinessLogic(book: book, registry: registry, annotationsManager: server)
        let manifest = try! Manifest.from(jsonFileName: ManifestJSON.snowcrash.rawValue, bundle: Bundle(for: type(of: self)))
        tracks = Tracks(manifest: manifest, audiobookID: "sync-tests", token: nil)
    }

    override func tearDown() {
        sut = nil
        server = nil
        registry = nil
        book = nil
        tracks = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func bookmark(_ annotationId: String, trackIndex: Int = 0, offsetMs: Int = 5_000) -> AudioBookmark {
        AudioBookmark(
            type: .locatorAudioBookTime,
            version: 2,
            timeStamp: "2026-01-01T00:00:00Z",
            annotationId: annotationId,
            readingOrderItem: tracks.tracks[trackIndex].key,
            readingOrderItemOffsetMilliseconds: offsetMs
        )
    }

    private func storeLocally(_ bookmark: AudioBookmark) {
        registry.addGenericBookmark(bookmark.toTPPBookLocation()!, forIdentifier: bookIdentifier)
    }

    private var localBookmarks: [AudioBookmark] {
        registry.genericBookmarksForIdentifier(bookIdentifier).compactMap {
            $0.locationStringDictionary().flatMap { AudioBookmark.create(locatorData: $0) }
        }
    }

    private func sync(_ local: [AudioBookmark]) -> [AudioBookmark] {
        let done = expectation(description: "sync completes")
        var result: [AudioBookmark] = []
        sut.syncBookmarks(localBookmarks: local) { bookmarks in
            result = bookmarks
            done.fulfill()
        }
        wait(for: [done], timeout: 5.0)
        return result
    }

    private func delete(_ bookmark: AudioBookmark) -> Bool? {
        let done = expectation(description: "delete completes")
        var result: Bool?
        sut.deleteBookmark(at: bookmark) { success in
            result = success
            done.fulfill()
        }
        wait(for: [done], timeout: 5.0)
        return result
    }

    private func fetch() -> [TrackPosition] {
        let done = expectation(description: "fetch completes")
        var result: [TrackPosition] = []
        sut.fetchBookmarks(for: tracks, toc: []) { positions in
            result = positions
            done.fulfill()
        }
        wait(for: [done], timeout: 5.0)
        return result
    }

    // MARK: - Merge

    /// A bookmark made on another device appears locally after a sync.
    func testSync_ServerBookmarkMissingLocally_IsStoredAndReturned() {
        server.serverBookmarks = [bookmark("srv-1", trackIndex: 2, offsetMs: 42_000)]

        let result = sync([])

        XCTAssertEqual(result.map(\.annotationId), ["srv-1"])
        XCTAssertEqual(localBookmarks.map(\.annotationId), ["srv-1"])
        XCTAssertEqual(localBookmarks.first?.readingOrderItemOffsetMilliseconds, 42_000)
    }

    /// The server copy of a bookmark already held locally is not stored twice.
    func testSync_ServerBookmarkAlreadyHeldLocally_IsNotDuplicated() {
        let local = bookmark("srv-1")
        storeLocally(local)
        server.serverBookmarks = [bookmark("srv-1")]

        let result = sync([local])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(localBookmarks.count, 1)
    }

    /// A server response that is not audiobook bookmarks is treated as empty,
    /// leaving the local bookmarks as the result.
    func testSync_ServerReturnsNonAudiobookBookmarks_KeepsOnlyLocalBookmarks() {
        let local = bookmark("local-1")
        storeLocally(local)
        server.serverBookmarks = [TPPReadiumBookmark(annotationId: "epub-1", href: "/c1.html", chapter: nil, page: nil,
                                                      locationString: "{}", progressWithinChapter: 0, progressWithinBook: 0,
                                                      readingOrderItem: nil, readingOrderItemOffsetMilliseconds: 0,
                                                      time: "2026-01-01T00:00:00Z", device: nil)]

        let result = sync([local])

        XCTAssertEqual(result.map(\.annotationId), ["local-1"])
        XCTAssertEqual(localBookmarks.map(\.annotationId), ["local-1"])
    }

    /// The public entry point returns local and server bookmarks as positions
    /// on the right tracks, without duplicates.
    func testFetchBookmarks_LocalAndServerBookmarks_ReturnsEachOnceAsTrackPositions() {
        storeLocally(bookmark("local-1", trackIndex: 1, offsetMs: 1_000))
        server.serverBookmarks = [bookmark("local-1", trackIndex: 1, offsetMs: 1_000),
                                  bookmark("srv-2", trackIndex: 3, offsetMs: 9_000)]

        let positions = fetch()

        XCTAssertEqual(Set(positions.map(\.annotationId)), ["local-1", "srv-2"])
        XCTAssertEqual(positions.count, 2)
        let serverPosition = positions.first { $0.annotationId == "srv-2" }
        XCTAssertEqual(serverPosition?.track.key, tracks.tracks[3].key)
        XCTAssertEqual(serverPosition?.timestamp ?? -1, 9.0, accuracy: 0.001)
    }

    // MARK: - Upload of unsynced bookmarks

    /// An unsynced local bookmark is posted, and the local copy takes the
    /// server's ID so it is not posted again.
    func testSync_UnsyncedLocalBookmark_IsUploadedAndTakesServerID() {
        let unsynced = bookmark("")
        storeLocally(unsynced)
        server.postOutcome = .success(AnnotationResponse(serverId: "srv-assigned", timeStamp: "2026-01-02T00:00:00Z"))

        _ = sync([unsynced])

        XCTAssertEqual(server.postedSelectors.count, 1)
        XCTAssertEqual(localBookmarks.map(\.annotationId), ["srv-assigned"])
        XCTAssertEqual(localBookmarks.first?.lastSavedTimeStamp, "2026-01-02T00:00:00Z")
    }

    /// A failed upload keeps the bookmark locally, still unsynced, and the
    /// sync still completes.
    func testSync_UploadThrows_BookmarkStaysLocalAndUnsynced() {
        let unsynced = bookmark("")
        storeLocally(unsynced)
        server.postOutcome = .failure(NSError(domain: "test", code: 1))

        let result = sync([unsynced])

        XCTAssertEqual(server.postedSelectors.count, 1)
        XCTAssertEqual(result.map(\.annotationId), [""])
        XCTAssertEqual(localBookmarks.map(\.annotationId), [""])
    }

    /// A server that accepts the post but returns no annotation leaves the
    /// bookmark unsynced rather than giving it an empty server link.
    func testSync_UploadReturnsNoAnnotation_BookmarkStaysUnsynced() {
        let unsynced = bookmark("")
        storeLocally(unsynced)
        server.postOutcome = .success(nil)

        _ = sync([unsynced])

        XCTAssertEqual(server.postedSelectors.count, 1)
        XCTAssertEqual(localBookmarks.map(\.annotationId), [""])
    }

    // MARK: - Deletes that must stay deleted

    /// The server can still list a bookmark just deleted; the next sync must
    /// not bring it back.
    func testSync_AfterDeletingSyncedBookmark_ServerCopyDoesNotReturn() {
        let synced = bookmark("srv-1")
        storeLocally(synced)
        XCTAssertEqual(delete(synced), true)
        server.serverBookmarks = [bookmark("srv-1")]

        let result = sync([])

        XCTAssertTrue(result.isEmpty)
        XCTAssertTrue(localBookmarks.isEmpty)
        XCTAssertEqual(server.deleteCalls, ["srv-1"])
    }

    /// A deleted bookmark is also blocked when the server lists the same
    /// position under a different annotation ID.
    func testSync_AfterDelete_ServerCopyWithOtherIDAtSamePosition_DoesNotReturn() {
        let synced = bookmark("srv-1", trackIndex: 1, offsetMs: 7_000)
        storeLocally(synced)
        XCTAssertEqual(delete(synced), true)
        server.serverBookmarks = [bookmark("srv-duplicate", trackIndex: 1, offsetMs: 7_000)]

        let result = sync([])

        XCTAssertTrue(result.isEmpty)
        XCTAssertTrue(localBookmarks.isEmpty)
    }

    /// A deleted bookmark written back to the registry by another path is
    /// still left out of what the patron sees.
    func testFetchBookmarks_DeletedBookmarkWrittenBackLocally_IsNotReturned() {
        let synced = bookmark("srv-1", trackIndex: 1, offsetMs: 7_000)
        let kept = bookmark("srv-2", trackIndex: 2, offsetMs: 3_000)
        storeLocally(synced)
        storeLocally(kept)
        XCTAssertEqual(delete(synced), true)
        storeLocally(synced)

        let positions = fetch()

        XCTAssertEqual(positions.map(\.annotationId), ["srv-2"])
    }

    /// When the delete by ID fails, the server copy at the same position is
    /// found and deleted under the ID the server actually uses.
    func testDelete_ServerRejectsID_DeletesServerCopyFoundByPosition() {
        let local = bookmark("stale-id", trackIndex: 1, offsetMs: 7_000)
        storeLocally(local)
        server.deleteResults = ["stale-id": false]
        server.serverBookmarks = [bookmark("srv-real", trackIndex: 1, offsetMs: 7_000),
                                  bookmark("srv-other", trackIndex: 2, offsetMs: 7_000)]

        let success = delete(local)

        XCTAssertEqual(success, true, "The local delete succeeded, which is what the caller reports")
        XCTAssertEqual(server.deleteCalls, ["stale-id", "srv-real"])
        XCTAssertTrue(localBookmarks.isEmpty)
    }

    /// Even when the content-matched delete also fails, the bookmark stays
    /// blocked from reappearing.
    func testDelete_ServerRejectsBothDeletes_BookmarkStillDoesNotReturn() {
        let local = bookmark("stale-id", trackIndex: 1, offsetMs: 7_000)
        storeLocally(local)
        server.deleteResults = ["stale-id": false, "srv-real": false]
        server.serverBookmarks = [bookmark("srv-real", trackIndex: 1, offsetMs: 7_000)]

        XCTAssertEqual(delete(local), true)
        XCTAssertEqual(server.deleteCalls, ["stale-id", "srv-real"])

        XCTAssertTrue(sync([]).isEmpty)
        XCTAssertTrue(localBookmarks.isEmpty)
    }

    /// No server copy to match: the delete completes and the original ID stays
    /// blocked, so a server that lists it later does not restore it.
    func testDelete_ServerRejectsIDAndHasNoMatch_IDStaysBlocked() {
        let local = bookmark("stale-id", trackIndex: 1, offsetMs: 7_000)
        storeLocally(local)
        server.deleteResults = ["stale-id": false]
        server.serverBookmarks = []

        XCTAssertEqual(delete(local), true)
        XCTAssertEqual(server.deleteCalls, ["stale-id"])

        server.serverBookmarks = [bookmark("stale-id", trackIndex: 1, offsetMs: 7_000)]
        XCTAssertTrue(sync([]).isEmpty)
        XCTAssertTrue(localBookmarks.isEmpty)
    }

    /// Deleting by track position removes the stored bookmark at that position.
    func testDeleteAtTrackPosition_RemovesStoredBookmarkAtThatPosition() {
        let kept = bookmark("", trackIndex: 2, offsetMs: 3_000)
        storeLocally(bookmark("", trackIndex: 1, offsetMs: 7_000))
        storeLocally(kept)
        let position = TrackPosition(track: tracks.tracks[1], timestamp: 7.0, tracks: tracks)

        let done = expectation(description: "delete completes")
        var success: Bool?
        sut.deleteBookmark(at: position) { result in
            success = result
            done.fulfill()
        }
        wait(for: [done], timeout: 5.0)

        XCTAssertEqual(success, true)
        XCTAssertEqual(localBookmarks.map(\.readingOrderItem), [tracks.tracks[2].key])
        XCTAssertTrue(server.deleteCalls.isEmpty, "An unsynced bookmark has nothing to delete on the server")
    }
}
