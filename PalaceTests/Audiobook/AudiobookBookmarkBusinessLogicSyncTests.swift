//
//  AudiobookBookmarkBusinessLogicSyncTests.swift
//  PalaceTests
//
//  Audiobook bookmark sync against a server that returns, rejects or keeps
//  bookmarks: merge, upload of unsynced bookmarks, and deletes that must not
//  come back on the next sync. The registry is the production BookmarkManager,
//  because the outcome depends on how stored records are matched.
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
        private var _onPost: (@Sendable () -> Void)?

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
        /// Runs while a bookmark POST is in flight, before the response returns.
        var onPost: (@Sendable () -> Void)? {
            get { lock.withLock { _onPost } }
            set { lock.withLock { _onPost = newValue } }
        }
        var deleteCalls: [String] { lock.withLock { _deleteCalls } }
        var postedSelectors: [String] { lock.withLock { _postedSelectors } }

        private var _syncPermitted = true
        var syncPermitted: Bool {
            get { lock.withLock { _syncPermitted } }
            set { lock.withLock { _syncPermitted = newValue } }
        }
        var syncIsPossibleAndPermitted: Bool { syncPermitted }

        func postListeningPosition(forBook bookID: String, selectorValue: String, completion: ((AnnotationResponse?) -> Void)?) {
            completion?(nil)
        }

        func postAudiobookBookmark(forBook bookID: String, selectorValue: String) async throws -> AnnotationResponse? {
            let (outcome, hook): (Result<AnnotationResponse?, Error>, (@Sendable () -> Void)?) = lock.withLock {
                _postedSelectors.append(selectorValue)
                return (_postOutcome, _onPost)
            }
            hook?()
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
    private var registry: BookmarkManagerBackedRegistry!
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
        registry = BookmarkManagerBackedRegistry()
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

    /// Carries a callback's non-Sendable result across the continuation.
    private final class ResultBox<Value>: @unchecked Sendable {
        let value: Value
        init(_ value: Value) { self.value = value }
    }

    /// Stored records exactly as the registry holds them.
    private var storedRecords: [String] {
        registry.genericBookmarksForIdentifier(bookIdentifier).map(\.locationString)
    }

    private var storedDictionaries: [[String: Any]] {
        registry.genericBookmarksForIdentifier(bookIdentifier).compactMap { $0.locationStringDictionary() }
    }

    // The SUT calls each completion exactly once, so the helpers await the
    // completion itself rather than a wall-clock deadline.
    private func sync() async -> [AudioBookmark] {
        let box: ResultBox<[AudioBookmark]> = await withCheckedContinuation { continuation in
            sut.syncBookmarks { bookmarks in
                continuation.resume(returning: ResultBox(bookmarks))
            }
        }
        return box.value
    }

    private func delete(_ bookmark: AudioBookmark) async -> Bool {
        await withCheckedContinuation { continuation in
            sut.deleteBookmark(at: bookmark) { success in
                continuation.resume(returning: success)
            }
        }
    }

    private func fetch() async -> [TrackPosition] {
        let box: ResultBox<[TrackPosition]> = await withCheckedContinuation { continuation in
            sut.fetchBookmarks(for: tracks, toc: []) { positions in
                continuation.resume(returning: ResultBox(positions))
            }
        }
        return box.value
    }

    // MARK: - Merge

    /// A bookmark made on another device appears locally after a sync.
    func testSync_ServerBookmarkMissingLocally_IsStoredAndReturned() async {
        server.serverBookmarks = [bookmark("srv-1", trackIndex: 2, offsetMs: 42_000)]

        let result = await sync()

        XCTAssertEqual(result.map(\.annotationId), ["srv-1"])
        XCTAssertEqual(localBookmarks.map(\.annotationId), ["srv-1"])
        XCTAssertEqual(localBookmarks.first?.readingOrderItemOffsetMilliseconds, 42_000)
    }

    /// The server copy of a bookmark already held locally is not stored twice.
    func testSync_ServerBookmarkAlreadyHeldLocally_IsNotDuplicated() async {
        let local = bookmark("srv-1")
        storeLocally(local)
        server.serverBookmarks = [bookmark("srv-1")]

        let result = await sync()

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(localBookmarks.count, 1)
    }

    /// A server response that is not audiobook bookmarks is treated as empty,
    /// leaving the local bookmarks as the result.
    func testSync_ServerReturnsNonAudiobookBookmarks_KeepsOnlyLocalBookmarks() async {
        let local = bookmark("local-1")
        storeLocally(local)
        server.serverBookmarks = [TPPReadiumBookmark(annotationId: "epub-1", href: "/c1.html", chapter: nil, page: nil,
                                                      locationString: "{}", progressWithinChapter: 0, progressWithinBook: 0,
                                                      readingOrderItem: nil, readingOrderItemOffsetMilliseconds: 0,
                                                      time: "2026-01-01T00:00:00Z", device: nil)]

        let result = await sync()

        XCTAssertEqual(result.map(\.annotationId), ["local-1"])
        XCTAssertEqual(localBookmarks.map(\.annotationId), ["local-1"])
    }

    /// The public entry point returns local and server bookmarks as positions
    /// on the right tracks, without duplicates.
    func testFetchBookmarks_LocalAndServerBookmarks_ReturnsEachOnceAsTrackPositions() async {
        storeLocally(bookmark("local-1", trackIndex: 1, offsetMs: 1_000))
        server.serverBookmarks = [bookmark("local-1", trackIndex: 1, offsetMs: 1_000),
                                  bookmark("srv-2", trackIndex: 3, offsetMs: 9_000)]

        let positions = await fetch()

        XCTAssertEqual(Set(positions.map(\.annotationId)), ["local-1", "srv-2"])
        XCTAssertEqual(positions.count, 2)
        let serverPosition = positions.first { $0.annotationId == "srv-2" }
        XCTAssertEqual(serverPosition?.track.key, tracks.tracks[3].key)
        XCTAssertEqual(serverPosition?.timestamp ?? -1, 9.0, accuracy: 0.001)
    }

    /// With sync off, server bookmarks are not merged; only local ones return.
    func testSync_SyncNotPermitted_ServerBookmarksAreNotStored() async {
        let local = bookmark("local-1")
        storeLocally(local)
        server.syncPermitted = false
        server.serverBookmarks = [bookmark("srv-2", trackIndex: 3, offsetMs: 9_000)]

        let result = await sync()

        XCTAssertEqual(result.map(\.annotationId), ["local-1"])
        XCTAssertEqual(localBookmarks.map(\.annotationId), ["local-1"])
    }

    // MARK: - Upload of unsynced bookmarks

    /// An unsynced local bookmark is posted, and the local copy takes the
    /// server's ID so it is not posted again.
    func testSync_UnsyncedLocalBookmark_IsUploadedAndTakesServerID() async {
        let unsynced = bookmark("")
        storeLocally(unsynced)
        server.postOutcome = .success(AnnotationResponse(serverId: "srv-assigned", timeStamp: "2026-01-02T00:00:00Z"))

        _ = await sync()

        XCTAssertEqual(server.postedSelectors.count, 1)
        XCTAssertEqual(localBookmarks.map(\.annotationId), ["srv-assigned"])
        XCTAssertEqual(localBookmarks.first?.lastSavedTimeStamp, "2026-01-02T00:00:00Z")
    }

    /// A failed upload keeps the bookmark locally, still unsynced, and the
    /// sync still completes.
    func testSync_UploadThrows_BookmarkStaysLocalAndUnsynced() async {
        let unsynced = bookmark("")
        storeLocally(unsynced)
        server.postOutcome = .failure(NSError(domain: "test", code: 1))

        let result = await sync()

        XCTAssertEqual(server.postedSelectors.count, 1)
        XCTAssertEqual(result.map(\.annotationId), [""])
        XCTAssertEqual(localBookmarks.map(\.annotationId), [""])
    }

    /// A server that accepts the post but returns no annotation leaves the
    /// bookmark unsynced rather than giving it an empty server link.
    func testSync_UploadReturnsNoAnnotation_BookmarkStaysUnsynced() async {
        let unsynced = bookmark("")
        storeLocally(unsynced)
        server.postOutcome = .success(nil)

        _ = await sync()

        XCTAssertEqual(server.postedSelectors.count, 1)
        XCTAssertEqual(localBookmarks.map(\.annotationId), [""])
        XCTAssertEqual(localBookmarks.map(\.lastSavedTimeStamp), ["2026-01-01T00:00:00Z"])
    }

    /// A response without a server ID is not a sync: the stored record is left
    /// exactly as it was, unsynced, so the next sync uploads it again.
    func testSync_UploadResponseWithoutServerID_LeavesStoredRecordUntouched() async {
        storeLocally(bookmark(""))
        let before = storedRecords
        server.postOutcome = .success(AnnotationResponse(serverId: nil, timeStamp: nil))

        _ = await sync()

        XCTAssertEqual(server.postedSelectors.count, 1)
        XCTAssertEqual(storedRecords, before)
    }

    /// An empty server ID is treated as no server ID.
    func testSync_UploadResponseWithEmptyServerID_LeavesStoredRecordUntouched() async {
        storeLocally(bookmark(""))
        let before = storedRecords
        server.postOutcome = .success(AnnotationResponse(serverId: "", timeStamp: "2026-01-02T00:00:00Z"))

        _ = await sync()

        XCTAssertEqual(storedRecords, before)
    }

    /// A response with an ID but no time links the bookmark and keeps its own time.
    func testSync_UploadResponseWithIDButNoTimestamp_KeepsStoredTimestamp() async {
        storeLocally(bookmark(""))
        server.postOutcome = .success(AnnotationResponse(serverId: "srv-1", timeStamp: nil))

        _ = await sync()

        XCTAssertEqual(storedDictionaries.count, 1)
        XCTAssertEqual(storedDictionaries.first?["annotationId"] as? String, "srv-1")
        XCTAssertEqual(storedDictionaries.first?["timeStamp"] as? String, "2026-01-01T00:00:00Z")
    }

    /// An empty time in the response is treated as no time.
    func testSync_UploadResponseWithIDAndEmptyTimestamp_KeepsStoredTimestamp() async {
        storeLocally(bookmark(""))
        server.postOutcome = .success(AnnotationResponse(serverId: "srv-1", timeStamp: ""))

        _ = await sync()

        XCTAssertEqual(storedDictionaries.first?["annotationId"] as? String, "srv-1")
        XCTAssertEqual(storedDictionaries.first?["timeStamp"] as? String, "2026-01-01T00:00:00Z")
    }

    /// The upload writes the server's ID and time into the stored record and
    /// leaves its other fields as stored; parsing adds a `chapter` the record
    /// never had, and that must not be written back.
    func testSync_UploadedRecord_KeepsItsOtherFields() async {
        storeLocally(bookmark(""))
        let keysBefore = Set(storedDictionaries.first?.keys.map { $0 } ?? [])
        server.postOutcome = .success(AnnotationResponse(serverId: "srv-1", timeStamp: "2026-01-02T00:00:00Z"))

        _ = await sync()

        XCTAssertEqual(storedDictionaries.count, 1)
        let record = storedDictionaries.first ?? [:]
        XCTAssertEqual(Set(record.keys), keysBefore)
        XCTAssertEqual(record["annotationId"] as? String, "srv-1")
        XCTAssertEqual(record["timeStamp"] as? String, "2026-01-02T00:00:00Z")
        XCTAssertEqual(record["readingOrderItem"] as? String, tracks.tracks[0].key)
        XCTAssertEqual(record["readingOrderItemOffsetMilliseconds"] as? Int, 5_000)
    }

    /// A bookmark deleted while its upload is in flight is not written back
    /// when the response arrives.
    func testSync_BookmarkDeletedDuringUpload_IsNotWrittenBack() async {
        storeLocally(bookmark(""))
        server.postOutcome = .success(AnnotationResponse(serverId: "srv-1", timeStamp: "2026-01-02T00:00:00Z"))
        let registry: BookmarkManagerBackedRegistry = self.registry
        let bookID = bookIdentifier
        server.onPost = {
            for record in registry.genericBookmarksForIdentifier(bookID) {
                registry.deleteGenericBookmark(record, forIdentifier: bookID)
            }
        }

        _ = await sync()

        XCTAssertEqual(server.postedSelectors.count, 1)
        XCTAssertTrue(storedRecords.isEmpty)
    }

    /// A bookmark the patron deletes while another one uploads is not posted
    /// afterwards, which would recreate it on the server.
    func testSync_BookmarkDeletedWhileAnotherUploads_IsNotPosted() async {
        storeLocally(bookmark("", trackIndex: 1, offsetMs: 1_000))
        storeLocally(bookmark("", trackIndex: 2, offsetMs: 2_000))
        server.postOutcome = .success(AnnotationResponse(serverId: "srv-1", timeStamp: "2026-01-02T00:00:00Z"))
        let logic: AudiobookBookmarkBusinessLogic = sut
        let deletedTrackKey = tracks.tracks[2].key
        server.onPost = {
            logic.deleteBookmark(at: AudioBookmark(type: .locatorAudioBookTime, version: 2, timeStamp: "2026-01-01T00:00:00Z",
                                                   readingOrderItem: deletedTrackKey, readingOrderItemOffsetMilliseconds: 2_000))
        }

        _ = await sync()

        XCTAssertEqual(server.postedSelectors.count, 1)
        XCTAssertEqual(localBookmarks.map(\.readingOrderItem), [tracks.tracks[1].key])
    }

    /// A lone unsynced bookmark is uploaded once; later syncs post nothing.
    func testSync_LoneUnsyncedBookmark_IsUploadedOnceAcrossSyncs() async {
        storeLocally(bookmark(""))
        server.postOutcome = .success(AnnotationResponse(serverId: "srv-1", timeStamp: "2026-01-02T00:00:00Z"))

        _ = await sync()
        _ = await sync()

        XCTAssertEqual(server.postedSelectors.count, 1)
        XCTAssertEqual(localBookmarks.map(\.annotationId), ["srv-1"])
    }

    // MARK: - Bookmark added while offline

    private func addBookmark(at position: TrackPosition) async {
        let _: ResultBox<TrackPosition?> = await withCheckedContinuation { continuation in
            sut.saveBookmark(at: position) { saved in
                continuation.resume(returning: ResultBox(saved))
            }
        }
    }

    private func deleteFromList(_ position: TrackPosition) async -> Bool {
        await withCheckedContinuation { continuation in
            sut.deleteBookmark(at: position) { success in
                continuation.resume(returning: success)
            }
        }
    }

    /// Adds a bookmark while its POST fails, as it does offline, then opens
    /// the bookmark list once the server answers.
    private func addOfflineThenOpenList() async {
        server.postOutcome = .failure(NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet))
        await addBookmark(at: TrackPosition(track: tracks.tracks[1], timestamp: 7.0, tracks: tracks))
        server.postOutcome = .success(AnnotationResponse(serverId: "srv-9", timeStamp: "2026-02-02T00:00:00Z"))
        _ = await fetch()
    }

    /// A bookmark added offline and synced once is stored once, as the synced record.
    func testSync_BookmarkAddedOffline_IsStoredOnceAsTheSyncedRecord() async {
        await addOfflineThenOpenList()

        XCTAssertEqual(localBookmarks.map(\.annotationId), ["srv-9"])
    }

    /// Once a bookmark added offline has synced, opening the list again posts nothing.
    func testSync_BookmarkAddedOffline_IsNotPostedAgainOnNextSync() async {
        await addOfflineThenOpenList()
        let postsAfterFirstSync = server.postedSelectors.count

        _ = await fetch()

        XCTAssertEqual(server.postedSelectors.count, postsAfterFirstSync)
    }

    /// Deleting a bookmark added offline, after it synced, deletes it on the server.
    func testDelete_BookmarkAddedOfflineThenSynced_SendsServerDelete() async {
        await addOfflineThenOpenList()
        let shown = await fetch()
        XCTAssertEqual(shown.map(\.annotationId), ["srv-9"])
        guard let position = shown.first else { return XCTFail("The synced bookmark is not listed") }

        let deleted = await deleteFromList(position)

        XCTAssertTrue(deleted)
        XCTAssertEqual(server.deleteCalls, ["srv-9"])
        XCTAssertTrue(storedRecords.isEmpty)
    }

    /// After deleting that bookmark and reopening the book, it stays deleted.
    func testReopen_AfterDeletingBookmarkAddedOffline_BookmarkStaysDeleted() async {
        await addOfflineThenOpenList()
        server.serverBookmarks = [bookmark("srv-9", trackIndex: 1, offsetMs: 7_000)]
        let shown = await fetch()
        guard let position = shown.first else { return XCTFail("The synced bookmark is not listed") }
        _ = await deleteFromList(position)
        // The server keeps the bookmark unless it was asked to delete it.
        if server.deleteCalls.contains("srv-9") { server.serverBookmarks = [] }

        sut = AudiobookBookmarkBusinessLogic(book: book, registry: registry, annotationsManager: server)
        let reopened = await fetch()

        XCTAssertTrue(reopened.isEmpty)
        XCTAssertTrue(storedRecords.isEmpty)
    }

    // MARK: - Duplicate records stored by earlier versions

    /// Stores the pair earlier versions left behind: the unsynced original,
    /// without a chapter, and the synced copy the upload appended with
    /// chapter "0". Returns the synced copy's stored record.
    @discardableResult
    private func storeDuplicatePair(trackIndex: Int = 1, offsetMs: Int = 7_000) -> String {
        storeLocally(bookmark("", trackIndex: trackIndex, offsetMs: offsetMs))
        let syncedCopy = bookmark("srv-9", trackIndex: trackIndex, offsetMs: offsetMs)
        syncedCopy.chapter = "0"
        storeLocally(syncedCopy)
        return storedRecords.last ?? ""
    }

    /// The pair collapses to the synced record and nothing is posted.
    func testSync_DuplicatePairFromEarlierVersion_CollapsesToTheSyncedRecord() async {
        let syncedRecord = storeDuplicatePair()
        server.postOutcome = .success(AnnotationResponse(serverId: "srv-other", timeStamp: nil))

        _ = await sync()

        XCTAssertEqual(storedRecords, [syncedRecord])
        XCTAssertTrue(server.postedSelectors.isEmpty)
    }

    /// Later syncs leave the collapsed record as it is.
    func testSync_DuplicatePairFromEarlierVersion_StaysCollapsedAcrossSyncs() async {
        let syncedRecord = storeDuplicatePair()

        _ = await sync()
        _ = await sync()

        XCTAssertEqual(storedRecords, [syncedRecord])
        XCTAssertTrue(server.postedSelectors.isEmpty)
    }

    /// When the unsynced copy and the synced record have the same fields apart
    /// from ID and time, only the unsynced copy is removed.
    func testSync_UnsyncedCopyBesideSyncedRecordWithSameFields_KeepsTheSyncedRecord() async {
        storeLocally(bookmark("", trackIndex: 1, offsetMs: 7_000))
        storeLocally(bookmark("srv-9", trackIndex: 1, offsetMs: 7_000))
        let syncedRecord = storedRecords.last ?? ""

        _ = await sync()

        XCTAssertEqual(storedRecords, [syncedRecord])
        XCTAssertTrue(server.postedSelectors.isEmpty)
    }

    /// An unsynced bookmark is not collapsed into a synced one at a different
    /// position, even one millisecond or one track away; it is uploaded.
    func testSync_UnsyncedNextToSyncedAtOtherPositions_IsUploadedAndOthersUntouched() async {
        storeLocally(bookmark("", trackIndex: 1, offsetMs: 7_000))
        storeLocally(bookmark("srv-near", trackIndex: 1, offsetMs: 7_001))
        storeLocally(bookmark("srv-track", trackIndex: 2, offsetMs: 7_000))
        let untouched = Array(storedRecords.dropFirst())
        server.postOutcome = .success(AnnotationResponse(serverId: "srv-1", timeStamp: "2026-01-02T00:00:00Z"))

        _ = await sync()

        XCTAssertEqual(server.postedSelectors.count, 1)
        XCTAssertEqual(localBookmarks.map(\.annotationId), ["srv-1", "srv-near", "srv-track"])
        XCTAssertEqual(Array(storedRecords.dropFirst()), untouched)
    }

    /// The unsynced copy an earlier response without an ID left beside the
    /// original (chapter "0", empty time) collapses once the original syncs.
    func testSync_TwoUnsyncedCopiesOfOneBookmark_EndAsOneSyncedRecord() async {
        storeLocally(bookmark("", trackIndex: 1, offsetMs: 7_000))
        let leftover = bookmark("", trackIndex: 1, offsetMs: 7_000)
        leftover.chapter = "0"
        leftover.lastSavedTimeStamp = ""
        storeLocally(leftover)
        server.postOutcome = .success(AnnotationResponse(serverId: "srv-1", timeStamp: "2026-01-02T00:00:00Z"))

        _ = await sync()

        XCTAssertEqual(server.postedSelectors.count, 1)
        XCTAssertEqual(localBookmarks.map(\.annotationId), ["srv-1"])
    }

    // MARK: - Deletes that must stay deleted

    /// The server can still list a bookmark just deleted; the next sync must
    /// not bring it back.
    func testSync_AfterDeletingSyncedBookmark_ServerCopyDoesNotReturn() async {
        let synced = bookmark("srv-1")
        storeLocally(synced)
        let deleted = await delete(synced)
        XCTAssertTrue(deleted)
        server.serverBookmarks = [bookmark("srv-1")]

        let result = await sync()

        XCTAssertTrue(result.isEmpty)
        XCTAssertTrue(localBookmarks.isEmpty)
        XCTAssertEqual(server.deleteCalls, ["srv-1"])
    }

    /// A deleted bookmark is also blocked when the server lists the same
    /// position under a different annotation ID.
    func testSync_AfterDelete_ServerCopyWithOtherIDAtSamePosition_DoesNotReturn() async {
        let synced = bookmark("srv-1", trackIndex: 1, offsetMs: 7_000)
        storeLocally(synced)
        let deleted = await delete(synced)
        XCTAssertTrue(deleted)
        server.serverBookmarks = [bookmark("srv-duplicate", trackIndex: 1, offsetMs: 7_000)]

        let result = await sync()

        XCTAssertTrue(result.isEmpty)
        XCTAssertTrue(localBookmarks.isEmpty)
    }

    /// A deleted bookmark written back to the registry by another path is
    /// still left out of what the patron sees.
    func testFetchBookmarks_DeletedBookmarkWrittenBackLocally_IsNotReturned() async {
        let synced = bookmark("srv-1", trackIndex: 1, offsetMs: 7_000)
        let kept = bookmark("srv-2", trackIndex: 2, offsetMs: 3_000)
        storeLocally(synced)
        storeLocally(kept)
        let deleted = await delete(synced)
        XCTAssertTrue(deleted)
        storeLocally(synced)

        let positions = await fetch()

        XCTAssertEqual(positions.map(\.annotationId), ["srv-2"])
    }

    /// A deleted bookmark written back under another annotation ID is still
    /// left out: the position alone marks it as deleted.
    func testFetchBookmarks_DeletedBookmarkWrittenBackUnderOtherID_IsNotReturned() async {
        let synced = bookmark("srv-1", trackIndex: 1, offsetMs: 7_000)
        storeLocally(synced)
        let deleted = await delete(synced)
        XCTAssertTrue(deleted)
        storeLocally(bookmark("srv-other", trackIndex: 1, offsetMs: 7_000))

        let positions = await fetch()

        XCTAssertTrue(positions.isEmpty)
    }

    /// When the delete by ID fails, the server copy at the same position is
    /// found and deleted under the ID the server actually uses.
    func testDelete_ServerRejectsID_DeletesServerCopyFoundByPosition() async {
        let local = bookmark("stale-id", trackIndex: 1, offsetMs: 7_000)
        storeLocally(local)
        server.deleteResults = ["stale-id": false]
        server.serverBookmarks = [bookmark("srv-real", trackIndex: 1, offsetMs: 7_000),
                                  bookmark("srv-other", trackIndex: 2, offsetMs: 7_000)]

        let success = await delete(local)

        XCTAssertTrue(success, "The local delete succeeded, which is what the caller reports")
        XCTAssertEqual(server.deleteCalls, ["stale-id", "srv-real"])
        XCTAssertTrue(localBookmarks.isEmpty)
    }

    /// Even when the content-matched delete also fails, the bookmark stays
    /// blocked from reappearing.
    func testDelete_ServerRejectsBothDeletes_BookmarkStillDoesNotReturn() async {
        let local = bookmark("stale-id", trackIndex: 1, offsetMs: 7_000)
        storeLocally(local)
        server.deleteResults = ["stale-id": false, "srv-real": false]
        server.serverBookmarks = [bookmark("srv-real", trackIndex: 1, offsetMs: 7_000)]

        let deleted = await delete(local)
        XCTAssertTrue(deleted)
        XCTAssertEqual(server.deleteCalls, ["stale-id", "srv-real"])

        let resynced = await sync()
        XCTAssertTrue(resynced.isEmpty)
        XCTAssertTrue(localBookmarks.isEmpty)
    }

    /// No server copy to match: the delete completes and the original ID stays
    /// blocked, so a server that lists it later does not restore it.
    func testDelete_ServerRejectsIDAndHasNoMatch_IDStaysBlocked() async {
        let local = bookmark("stale-id", trackIndex: 1, offsetMs: 7_000)
        storeLocally(local)
        server.deleteResults = ["stale-id": false]
        server.serverBookmarks = []

        let deleted = await delete(local)
        XCTAssertTrue(deleted)
        XCTAssertEqual(server.deleteCalls, ["stale-id"])

        server.serverBookmarks = [bookmark("stale-id", trackIndex: 1, offsetMs: 7_000)]
        let resynced = await sync()
        XCTAssertTrue(resynced.isEmpty)
        XCTAssertTrue(localBookmarks.isEmpty)
    }

    /// Deleting by track position removes the stored bookmark at that position.
    func testDeleteAtTrackPosition_RemovesStoredBookmarkAtThatPosition() async {
        let kept = bookmark("", trackIndex: 2, offsetMs: 3_000)
        storeLocally(bookmark("", trackIndex: 1, offsetMs: 7_000))
        storeLocally(kept)
        let position = TrackPosition(track: tracks.tracks[1], timestamp: 7.0, tracks: tracks)

        let success: Bool = await withCheckedContinuation { continuation in
            sut.deleteBookmark(at: position) { result in
                continuation.resume(returning: result)
            }
        }

        XCTAssertTrue(success)
        XCTAssertEqual(localBookmarks.map(\.readingOrderItem), [tracks.tracks[2].key])
        XCTAssertTrue(server.deleteCalls.isEmpty, "An unsynced bookmark has nothing to delete on the server")
    }
}
