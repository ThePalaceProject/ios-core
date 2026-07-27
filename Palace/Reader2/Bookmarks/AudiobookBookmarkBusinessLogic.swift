//
//  AudiobookBookmarkBusinessLogic.swift
//  Palace
//
//  Created by Maurice Carrier on 4/12/23.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Foundation
import PalaceLogging
import PalaceReadingPosition
@preconcurrency import PalaceAudiobookToolkit
import PalaceBookModel

// Swift 6 `complete`: `@unchecked Sendable`. This class is captured by the
// `@Sendable` `Task` / work-`queue` / `DispatchQueue.main.async` / `DispatchWorkItem`
// closures throughout (save / fetch / delete / sync / debounce). INVARIANT:
//   • The injected dependencies (`book`, `registry`, `annotationsManager`,
//     `positionWriter`) are immutable `let`s assigned once in `init`.
//   • All mutable sync state (`isSyncing`, `completionHandlersQueue`,
//     `deletedBookmarkIds`) is only ever read/written through `onStateQueue`, and
//     `debounceWorkItem` only on the serial work `queue` — the file's single
//     serialization domain (see the "Serialized sync state" note below). No
//     unsynchronized mutable state crosses the closure boundaries.
// This waives no real race; it matches the existing per-closure boxing strategy.
@objc public class AudiobookBookmarkBusinessLogic: NSObject, @unchecked Sendable {
    public let book: TPPBook
    private let registry: TPPBookRegistryProvider
    private let annotationsManager: AnnotationsManager
    private let positionWriter: PositionWriter
    private let queue = DispatchQueue(label: "com.palace.audiobookBookmarkBusinessLogic")
    /// Identifies execution already on `queue` so `onStateQueue` runs inline
    /// instead of a nested `queue.sync` (which would deadlock).
    private let queueKey = DispatchSpecificKey<Void>()
    private let debounceInterval: TimeInterval = 1.0
    private var debounceWorkItem: DispatchWorkItem?  // Access only on `queue`

    // MARK: - Test join seam
    // Retains the most recent `saveListeningPosition` write `Task` so tests can
    // deterministically JOIN the actual work unit (`await handle.value`) instead
    // of polling a wall-clock deadline (`wait(for:timeout:)`), which starves
    // under CI sim-clone oversubscription. Production behavior is unchanged: the
    // Task runs and calls its completion exactly as before; this reference is
    // write-only outside of `_awaitPositionWriteForTesting()`. Access is confined
    // to `queue` (the file's single serialization domain).
    private var _positionWriteTaskForTesting: Task<Void, Never>?

    // MARK: - Serialized sync state
    // `isSyncing`, `completionHandlersQueue`, and `deletedBookmarkIds` are read
    // and written from the UI thread, URLSession completion threads, AND the
    // work `queue`. Concurrent mutation of the Swift Set/Array corrupted its
    // copy-on-write buffer refcount → an over-release that surfaced in the
    // captured network-completion closure chain (Crashlytics abfef568). All
    // access now goes through `onStateQueue` so the serial `queue` is the single
    // serialization domain for this state.
    private var isSyncing: Bool = false
    // Boxed so the drained handlers can be captured by the `@Sendable`
    // `DispatchQueue.main.async` closure in `finalizeSync` without crossing a
    // non-Sendable boundary (each element wraps a `([AudioBookmark]) -> Void`).
    private var completionHandlersQueue: [AudioBookmarkListCompletionBox] = []
    private var deletedBookmarkIds = Set<String>()

    @objc convenience init(book: TPPBook) {
        self.init(
            book: book,
            registry: AppContainer.production().bookRegistry,
            annotationsManager: TPPAnnotationsWrapper(),
            positionWriter: nil
        )
    }

    init(
        book: TPPBook,
        registry: TPPBookRegistryProvider,
        annotationsManager: AnnotationsManager,
        positionWriter: PositionWriter? = nil
    ) {
        self.book = book
        self.registry = registry
        self.annotationsManager = annotationsManager
        // Default: build a `RemotePositionWriter` from an adapter that
        // wraps the same `AnnotationsManager` the rest of this class uses.
        // This keeps the dependency injection seam in one place — tests
        // and overrides can pass a spy via the `positionWriter:` argument.
        self.positionWriter = positionWriter ?? RemotePositionWriter(
            network: AudiobookPositionAdapter(annotations: annotationsManager)
        )
        super.init()
        queue.setSpecific(key: queueKey, value: ())
    }

    /// Serializes access to the mutable sync state (`isSyncing`,
    /// `completionHandlersQueue`, `deletedBookmarkIds`) through the work `queue`.
    /// Reentrancy-safe: runs inline when already on `queue`, otherwise blocks on
    /// `queue.sync`. Critical sections must stay O(1)/O(n) — never await network
    /// inside `work`.
    @discardableResult
    private func onStateQueue<T>(_ work: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return work()
        } else {
            return queue.sync(execute: work)
        }
    }

    // MARK: - Bookmark Management

    public func saveListeningPosition(at position: TrackPosition, completion: ((String?) -> Void)?) {
        let audioBookmark = position.toAudioBookmark()
        audioBookmark.lastSavedTimeStamp = Date().iso8601

        // Save to local registry immediately - this is the user's safety net.
        // This MUST happen before any async work so a crash/background mid-flight
        // never loses position state. (swarm_f3b9b087 P0 #4 invariant.)
        guard let tppLocation = audioBookmark.toTPPBookLocation() else {
            completion?(nil)
            return
        }
        registry.setLocation(tppLocation, forIdentifier: self.book.identifier)
        Log.debug(#file, "💾 Immediately saved position locally: track=\(position.track.key), time=\(position.timestamp)")

        // Delegate the network write to the unified PositionWriter. Throttling,
        // queue management, and background-task lifetime now live in one place
        // (RemotePositionWriter); this method retains audiobook-specific
        // conflict resolution after the writer resolves.
        let sentTimestamp = audioBookmark.lastSavedTimeStamp ?? ""
        let sentTrackKey = position.track.key
        let sentTrackIndex = position.track.index
        let sentPlaybackTime = position.timestamp

        let snapshot = PositionSnapshot(
            bookID: self.book.identifier,
            format: .audiobook,
            payload: Data(tppLocation.locationString.utf8),
            timestamp: Date(),
            device: AnnotationDevice.currentID()
        )

        // Swift 6 `complete`: box the non-Sendable `String?` completion closure
        // and the non-Sendable `AudioBookmark` (a Palace-owned mutable class) so
        // the `@Sendable` `Task` below captures Sendable carriers. INVARIANT: the
        // boxed `audioBookmark` is created here and handed off exclusively to
        // this single `Task` — the synchronous prefix above finishes touching it
        // before the Task is enqueued, and no other task aliases it — so the
        // `annotationId` mutation inside the Task is race-free.
        let completionBox = StringCompletionBox(completion)
        let audioBookmarkBox = AudioBookmarkBox(audioBookmark)

        let writeTask = Task { [weak self] in
            guard let self else { return }
            let audioBookmark = audioBookmarkBox.bookmark
            do {
                guard let serverID = try await self.positionWriter.save(snapshot) else {
                    // Throttled or queued — local position is already saved,
                    // and the writer will flush later. Nothing else to do here.
                    completionBox.call?(nil)
                    return
                }

                // Conflict resolution against the current local state.
                // Preserved verbatim from swarm_f3b9b087 P0 #4/#5: the
                // timestamp-newer race check (5s window) and the strict-
                // zero isAtBeginning guard protect a valid local position
                // from being overwritten by a stale upload result.
                if let currentLocal = self.registry.location(forIdentifier: self.book.identifier),
                   let currentDict = currentLocal.locationStringDictionary(),
                   let currentBookmark = AudioBookmark.create(locatorData: currentDict) {

                    let currentLocalTimestamp = currentBookmark.lastSavedTimeStamp ?? ""

                    if !currentLocalTimestamp.isEmpty && !sentTimestamp.isEmpty,
                       String.isDate(currentLocalTimestamp, moreRecentThan: sentTimestamp, with: 1.0) {
                        Log.warn(#file, "⚠️ Race condition detected: Local position is newer. Keeping local.")
                        Log.warn(#file, "  Sent: track=\(sentTrackKey), time=\(sentPlaybackTime), timestamp=\(sentTimestamp)")
                        Log.warn(#file, "  Current local: track=\(currentBookmark.chapter ?? "?"), timestamp=\(currentLocalTimestamp)")
                        completionBox.call?(serverID)
                        return
                    }

                    // Decision delegated to BeginningPositionPolicy. Was previously
                    // `sentTrackIndex == 0 && sentPlaybackTime < 30.0` — the 30s grace
                    // discarded real 0:25-of-chapter-1 pauses. Strict zero is correct:
                    // the upstream timestamp-newer race check (lines 76–82) already
                    // handles "newer-wins" semantics. See AudiobookPositionPolicy.swift.
                    let isAtBeginning = BeginningPositionPolicy.isAtBeginning(
                        trackIndex: sentTrackIndex,
                        playbackTime: sentPlaybackTime
                    )
                    if isAtBeginning {
                        if let currentChapter = currentBookmark.chapter,
                           let currentTrackIndex = Int(currentChapter.split(separator: "-").last ?? ""),
                           currentTrackIndex > 0 {
                            Log.warn(#file, "⚠️ Prevented 'beginning' position from overwriting progress!")
                            Log.warn(#file, "  Attempting to save: track 0, time \(sentPlaybackTime)")
                            Log.warn(#file, "  Current position: track \(currentTrackIndex)")
                            completionBox.call?(serverID)
                            return
                        }
                    }
                }

                // Commit the server-assigned annotationId to the local
                // registry so subsequent reads carry the server linkage.
                audioBookmark.annotationId = serverID

                self.registry.setLocation(audioBookmark.toTPPBookLocation(), forIdentifier: self.book.identifier)
                Log.debug(#file, "☁️ Synced position to server: track=\(sentTrackKey), annotationId=\(audioBookmark.annotationId)")
                completionBox.call?(serverID)
            } catch {
                Log.warn(#file, "⚠️ Server sync failed, but local position was already saved: \(error)")
                completionBox.call?(nil)
            }
        }
        onStateQueue { self._positionWriteTaskForTesting = writeTask }
    }

    /// Test-only join seam. Awaits the most recent `saveListeningPosition`
    /// write `Task` so a test can deterministically block on the actual async
    /// work unit (including the post-save conflict-resolution branch and the
    /// completion call) rather than a wall-clock `wait(for:timeout:)` poll that
    /// starves under CI oversubscription. No-op if no write is in flight.
    /// Behavior-identical for production: nothing calls this outside tests.
    func _awaitPositionWriteForTesting() async {
        let handle = onStateQueue { self._positionWriteTaskForTesting }
        await handle?.value
    }

    public func saveBookmark(at position: TrackPosition, completion: ((_ position: TrackPosition?) -> Void)? = nil) {
        // Swift 6 `targeted`: box the non-Sendable `completion` closure so the
        // `@Sendable` `Task` closure inside the debounce captures a Sendable
        // carrier rather than the raw closure. INVARIANT: the boxed completion
        // is only ever invoked on the main queue (the two `DispatchQueue.main
        // .async` blocks below). Mirrors `ImageCompletionBox` in `ImageLoaderImpl`.
        let completionBox = TrackPositionCompletionBox(completion)
        debounce {
            Task { [weak self] in
                guard let self else { return }
                let location = position.toAudioBookmark()
                var updatedPosition = position

                defer {
                    updatedPosition.lastSavedTimeStamp = location.lastSavedTimeStamp ?? Date().iso8601
                    updatedPosition.annotationId = location.annotationId
                    if let updatedLocation = updatedPosition.toAudioBookmark().toTPPBookLocation() {
                        self.registry.addOrReplaceGenericBookmark(updatedLocation, forIdentifier: self.book.identifier)
                    }
                    // Swift 6 `complete`: snapshot the mutated `var updatedPosition`
                    // to a `let` before the `@Sendable` `DispatchQueue.main.async`
                    // closure so it captures an immutable value, not the captured var.
                    let finalPosition = updatedPosition
                    DispatchQueue.main.async { completionBox.call?(finalPosition) }
                }

                guard let data = location.toData(), let locationString = String(data: data, encoding: .utf8) else {
                    Log.error(#file, "Failed to encode location data for bookmark.")
                    DispatchQueue.main.async { completionBox.call?(nil) }
                    return
                }

                if let annotationResponse = try? await self.annotationsManager.postAudiobookBookmark(forBook: self.book.identifier, selectorValue: locationString) {
                    location.annotationId = annotationResponse.serverId ?? ""
                    location.lastSavedTimeStamp = annotationResponse.timeStamp ?? ""
                }
            }
        }
    }

    public func fetchBookmarks(for tracks: Tracks, toc: [Chapter], completion: @escaping ([TrackPosition]) -> Void) {
        // Swift 6 `complete`: box the non-Sendable `completion` closure so the
        // `@Sendable` work-`queue` closure (and the nested `syncBookmarks`
        // handler + `DispatchQueue.main.async`) capture a Sendable carrier
        // rather than the raw closure. `AudioBookmark` is a Palace-owned
        // mutable class (not covered by `@preconcurrency import
        // PalaceAudiobookToolkit`), so the `[AudioBookmark]` snapshots that
        // flow through the sync handler are boxed the same way. INVARIANT: the
        // boxed completion is only ever invoked on the main queue (the
        // `DispatchQueue.main.async` below). Mirrors `ReadiumBookmarkBox`.
        let completionBox = TrackPositionListCompletionBox(completion)
        queue.async { [weak self] in
            guard let self else { return }

            Log.info(#file, "📚 BOOKMARK FETCH START for book: \(self.book.identifier)")

            let localBookmarks: [AudioBookmark] = self.fetchLocalBookmarks()
            Log.info(#file, "📱 LOCAL BOOKMARKS COUNT: \(localBookmarks.count)")

            for (index, bookmark) in localBookmarks.enumerated() {
                Log.info(#file, "📱 Local Bookmark #\(index): version=\(bookmark.version), timestamp=\(bookmark.lastSavedTimeStamp ?? "nil"), annotationId=\(bookmark.annotationId.isEmpty ? "UNSYNCED" : bookmark.annotationId), chapter=\(bookmark.chapter ?? "nil"), readingOrderItem=\(bookmark.readingOrderItem ?? "nil")")
            }

            self.syncBookmarks(localBookmarks: localBookmarks) { syncedBookmarks in
                Log.info(#file, "☁️ SYNCED BOOKMARKS COUNT: \(syncedBookmarks.count)")

                for (index, bookmark) in syncedBookmarks.enumerated() {
                    Log.info(#file, "☁️ Synced Bookmark #\(index): version=\(bookmark.version), timestamp=\(bookmark.lastSavedTimeStamp ?? "nil"), annotationId=\(bookmark.annotationId.isEmpty ? "UNSYNCED" : bookmark.annotationId), chapter=\(bookmark.chapter ?? "nil"), readingOrderItem=\(bookmark.readingOrderItem ?? "nil")")
                }

                let combinedBookmarks = syncedBookmarks.combineAndRemoveDuplicates(with: localBookmarks)
                Log.info(#file, "🔀 COMBINED BOOKMARKS COUNT (after dedup): \(combinedBookmarks.count)")

                let trackPositions = combinedBookmarks.compactMap { TrackPosition(audioBookmark: $0, toc: toc, tracks: tracks) }
                Log.info(#file, "✅ FINAL TRACK POSITIONS COUNT: \(trackPositions.count)")

                if trackPositions.count != combinedBookmarks.count {
                    Log.warn(#file, "⚠️ BOOKMARK CONVERSION ISSUE: \(combinedBookmarks.count - trackPositions.count) bookmarks failed to convert to TrackPosition")
                }

                // Swift 6 `complete`: box the non-Sendable `[TrackPosition]` value
                // (produced here on the serial work `queue`, consumed once on main)
                // before the `@Sendable` `DispatchQueue.main.async` boundary — see
                // `TrackPositionListBox`. `@preconcurrency import` covers the type's
                // conformance but not this region-isolation `sending` of the array.
                let trackPositionsBox = TrackPositionListBox(trackPositions)
                DispatchQueue.main.async {
                    completionBox.call(trackPositionsBox.positions)
                }
            }
        }
    }

    public func deleteBookmark(at position: TrackPosition, completion: ((Bool) -> Void)? = nil) {
        let bookmark = position.toAudioBookmark()
        deleteBookmark(at: bookmark, completion: completion)
    }

    public func deleteBookmark(at bookmark: AudioBookmark, completion: ((Bool) -> Void)? = nil) {
        // Swift 6 `complete`: box the non-Sendable `Bool` completion closure so
        // the `@Sendable` `DispatchQueue.main.async` blocks (here and threaded
        // into `deleteBookmarkByContentMatch`) capture a Sendable carrier.
        // INVARIANT: the boxed completion is only ever invoked on the main queue.
        let completionBox = BoolCompletionBox(completion)
        deleteBookmark(at: bookmark, completion: completionBox)
    }

    private func deleteBookmark(at bookmark: AudioBookmark, completion: BoolCompletionBox) {
        Log.info(#file, "🗑️ DELETE BOOKMARK REQUEST for book: \(self.book.identifier)")
        Log.info(#file, "🗑️ Bookmark Details: version=\(bookmark.version), timestamp=\(bookmark.lastSavedTimeStamp ?? "nil"), annotationId=\(bookmark.annotationId.isEmpty ? "UNSYNCED" : bookmark.annotationId), chapter=\(bookmark.chapter ?? "nil"), readingOrderItem=\(bookmark.readingOrderItem ?? "nil")")

        // Track this bookmark as deleted (prevents it from coming back from server)
        let contentHash = bookmark.uniqueIdentifier
        onStateQueue {
            if !bookmark.annotationId.isEmpty {
                deletedBookmarkIds.insert(bookmark.annotationId)
                Log.info(#file, "🗑️ Tracking deleted annotationId: \(bookmark.annotationId)")
            }
            // Also track by content hash for bookmarks that might have different annotation IDs
            if !contentHash.isEmpty {
                deletedBookmarkIds.insert("content:\(contentHash)")
                Log.info(#file, "🗑️ Tracking deleted by content hash: \(contentHash)")
            }
        }

        // Swift 6 `complete`: compute the local-deletion outcome as a `let` so the
        // downstream `@Sendable` `DispatchQueue.main.async` / server-deletion
        // completion closures capture an immutable value, not a captured `var`.
        // `Bool` is already Sendable; the `let` clears the "reference to captured
        // var 'localDeletionSucceeded' in concurrently-executing code" diagnostic.
        let localDeletionSucceeded: Bool
        if let genericLocation = bookmark.toTPPBookLocation() {
            self.registry.deleteGenericBookmark(genericLocation, forIdentifier: self.book.identifier)
            Log.info(#file, "🗑️ ✅ Local bookmark deleted from registry")
            localDeletionSucceeded = true
        } else {
            Log.error(#file, "🗑️ ❌ Failed to convert bookmark to TPPBookLocation for local deletion")
            localDeletionSucceeded = false
        }

        guard !bookmark.isUnsynced else {
            Log.info(#file, "🗑️ Bookmark was unsynced (local only), deletion complete")
            DispatchQueue.main.async { completion.call?(localDeletionSucceeded) }
            return
        }

        Log.info(#file, "🗑️ Attempting server deletion with annotationId: \(bookmark.annotationId)")

        annotationsManager.deleteBookmark(annotationId: bookmark.annotationId) { [weak self] serverSuccess in
            if serverSuccess {
                Log.info(#file, "🗑️ ✅ Server deletion successful for annotationId: \(bookmark.annotationId)")
                DispatchQueue.main.async { completion.call?(localDeletionSucceeded) }
            } else {
                Log.warn(#file, "🗑️ ⚠️ Direct server deletion failed - attempting content-based match")
                self?.deleteBookmarkByContentMatch(bookmark, localDeletionSucceeded: localDeletionSucceeded, completion: completion)
            }
        }
    }

    private func deleteBookmarkByContentMatch(_ bookmark: AudioBookmark, localDeletionSucceeded: Bool, completion: BoolCompletionBox) {
        Log.info(#file, "🔍 CONTENT-BASED DELETE: Fetching server bookmarks to find match")

        // Temporarily remove from deleted tracking to allow fetching
        let tempAnnotationId = bookmark.annotationId
        let tempContentHash = bookmark.uniqueIdentifier
        onStateQueue {
            deletedBookmarkIds.remove(tempAnnotationId)
            if !tempContentHash.isEmpty {
                deletedBookmarkIds.remove("content:\(tempContentHash)")
            }
        }

        fetchServerBookmarks { [weak self] serverBookmarks in
            guard let self = self else {
                DispatchQueue.main.async { completion.call?(localDeletionSucceeded) }
                return
            }

            // Find matching bookmark by content (same position/time)
            if let matchingServerBookmark = serverBookmarks.first(where: { $0.isSimilar(to: bookmark) }) {
                Log.info(#file, "🔍 ✅ Found matching server bookmark by content!")
                Log.info(#file, "🔍 Original annotationId: \(tempAnnotationId)")
                Log.info(#file, "🔍 Server annotationId: \(matchingServerBookmark.annotationId)")

                // Update tracking with correct server annotation ID
                self.onStateQueue { self.deletedBookmarkIds.insert(matchingServerBookmark.annotationId) }

                // Delete using the correct server annotation ID
                self.annotationsManager.deleteBookmark(annotationId: matchingServerBookmark.annotationId) { success in
                    if success {
                        Log.info(#file, "🔍 ✅ Content-matched bookmark deleted from server!")
                    } else {
                        Log.error(#file, "🔍 ❌ Content-matched deletion also failed - blocking bookmark from reappearing anyway")
                    }
                    DispatchQueue.main.async { completion.call?(localDeletionSucceeded) }
                }
            } else {
                Log.warn(#file, "🔍 ⚠️ No matching bookmark found on server - may have already been deleted")
                // Re-add to tracking
                self.onStateQueue {
                    self.deletedBookmarkIds.insert(tempAnnotationId)
                    if !tempContentHash.isEmpty {
                        self.deletedBookmarkIds.insert("content:\(tempContentHash)")
                    }
                }
                DispatchQueue.main.async { completion.call?(localDeletionSucceeded) }
            }
        }
    }

    // MARK: - Sync Logic

    func syncBookmarks(localBookmarks: [AudioBookmark], completion: (([AudioBookmark]) -> Void)? = nil) {
        // Swift 6 `complete`: box the non-Sendable `[AudioBookmark]` input and
        // the non-Sendable `completion` closure so the `@Sendable` `Task` below
        // captures Sendable carriers instead of the raw values. `AudioBookmark`
        // is a Palace-owned mutable class and must NOT be made `: Sendable` (9
        // mutable `var`s) — see `AudioBookmarkListBox` / `ReadiumBookmarkBox`
        // precedent. The serial work `queue` remains the single serialization
        // domain (see the `isSyncing`/`completionHandlersQueue` note above), so
        // boxing is safe: the boxed values are only ever touched on `queue` or
        // the main queue, never concurrently.
        let localBox = AudioBookmarkListBox(localBookmarks)
        let completionBox = AudioBookmarkListCompletionBox(completion)
        // Atomically test-and-set `isSyncing`. If a sync is already in flight we
        // enqueue this completion under the same lock that `finalizeSync` drains
        // — without serialization the append raced the drain (CoW corruption).
        let shouldStartSync = onStateQueue { () -> Bool in
            if isSyncing {
                if completionBox.call != nil {
                    completionHandlersQueue.append(completionBox)
                }
                return false
            }
            isSyncing = true
            return true
        }
        guard shouldStartSync else { return }

        Task { [weak self] in
            guard let self else { return }
            await uploadUnsyncedBookmarks(localBox.bookmarks)

            fetchServerBookmarks { [weak self] remoteBookmarks in
                guard let strongSelf = self else { return }

                strongSelf.updateLocalBookmarks(with: remoteBookmarks) { updatedBookmarks in
                    strongSelf.finalizeSync(with: updatedBookmarks, completion: completionBox)
                }
            }
        }
    }

    private func fetchLocalBookmarks() -> [AudioBookmark] {
        let allBookmarks: [AudioBookmark] = registry.genericBookmarksForIdentifier(book.identifier).compactMap { bookmark -> AudioBookmark? in
            guard let dictionary = bookmark.locationStringDictionary(),
                  let localBookmark = AudioBookmark.create(locatorData: dictionary) else {
                return nil
            }
            return localBookmark
        }

        // Filter out bookmarks that user has deleted (belt and suspenders approach).
        // Snapshot the deleted-id set under the lock so the filter reads a stable
        // copy instead of racing concurrent inserts/removes on the live Set.
        let deletedIds = onStateQueue { deletedBookmarkIds }
        let filteredBookmarks = allBookmarks.filter { bookmark in
            let isDeletedById = deletedIds.contains(bookmark.annotationId)
            let contentHash = bookmark.uniqueIdentifier
            let isDeletedByContent = !contentHash.isEmpty && deletedIds.contains("content:\(contentHash)")

            if isDeletedById || isDeletedByContent {
                Log.info(#file, "🗑️ Filtering out deleted bookmark from local fetch: \(bookmark.annotationId)")
                return false
            }
            return true
        }

        if filteredBookmarks.count < allBookmarks.count {
            Log.info(#file, "🗑️ Filtered \(allBookmarks.count - filteredBookmarks.count) deleted bookmark(s) from local storage")
        }

        return filteredBookmarks
    }

    private func fetchServerBookmarks(completion: @escaping ([AudioBookmark]) -> Void) {
        Log.info(#file, "☁️ FETCHING SERVER BOOKMARKS for book: \(self.book.identifier)")
        Log.info(#file, "☁️ Annotations URL: \(self.book.annotationsURL?.absoluteString ?? "nil")")

        annotationsManager.getServerBookmarks(forBook: book, atURL: self.book.annotationsURL, motivation: .bookmark) { serverBookmarks in
            Log.info(#file, "☁️ SERVER RESPONSE: Received \(serverBookmarks?.count ?? 0) bookmarks")

            guard let audioBookmarks = serverBookmarks as? [AudioBookmark] else {
                if let bookmarks = serverBookmarks {
                    Log.warn(#file, "☁️ SERVER BOOKMARKS TYPE MISMATCH: Expected [AudioBookmark] but got \(type(of: bookmarks))")
                    Log.warn(#file, "☁️ Bookmark types: \(bookmarks.map { type(of: $0) })")
                } else {
                    Log.info(#file, "☁️ No server bookmarks found (nil response)")
                }
                completion([])
                return
            }

            Log.info(#file, "☁️ Successfully parsed \(audioBookmarks.count) audio bookmarks from server")
            for (index, bookmark) in audioBookmarks.enumerated() {
                Log.info(#file, "☁️ Server Bookmark #\(index): version=\(bookmark.version), timestamp=\(bookmark.lastSavedTimeStamp ?? "nil"), annotationId=\(bookmark.annotationId), chapter=\(bookmark.chapter ?? "nil"), readingOrderItem=\(bookmark.readingOrderItem ?? "nil")")
            }

            completion(audioBookmarks)
        }
    }

    private func uploadUnsyncedBookmarks(_ localBookmarks: [AudioBookmark]) async {
        for bookmark in localBookmarks where bookmark.isUnsynced {
            do {
                try await uploadBookmark(bookmark)
            } catch {
                Log.debug(#file, "Failed to save annotation with error: \(error.localizedDescription)")
            }
        }
    }

    private func uploadBookmark(_ bookmark: AudioBookmark) async throws {
        guard let data = bookmark.toData(),
              let locationString = String(data: data, encoding: .utf8) else { return }

        guard let annotationResponse = try await annotationsManager.postAudiobookBookmark(forBook: self.book.identifier, selectorValue: locationString) else {
            return
        }

        updateLocalBookmark(bookmark, with: annotationResponse)
    }

    private func updateLocalBookmark(_ bookmark: AudioBookmark, with annotationResponse: AnnotationResponse) {
        if let updatedBookmark = bookmark.copy() as? AudioBookmark {
            updatedBookmark.annotationId = annotationResponse.serverId ?? ""
            updatedBookmark.lastSavedTimeStamp = annotationResponse.timeStamp ?? ""
            replace(oldLocation: bookmark, with: updatedBookmark)
        }
    }

    private func updateLocalBookmarks(with remoteBookmarks: [AudioBookmark], completion: @escaping ([AudioBookmark]) -> Void) {
        Log.info(#file, "🔄 UPDATE LOCAL BOOKMARKS: Merging remote bookmarks with local")

        let localBookmarks = fetchLocalBookmarks()
        Log.info(#file, "🔄 Current local bookmarks: \(localBookmarks.count)")

        guard annotationsManager.syncIsPossibleAndPermitted else {
            Log.info(#file, "🔄 Sync not possible or not permitted, returning local bookmarks only")
            completion(localBookmarks)
            return
        }

        // Filter out bookmarks that user has deleted (even if server still returns them).
        // Snapshot under the lock — see `fetchLocalBookmarks`.
        let deletedIds = onStateQueue { deletedBookmarkIds }
        let filteredRemoteBookmarks = remoteBookmarks.filter { remoteBookmark in
            let isDeletedById = deletedIds.contains(remoteBookmark.annotationId)
            let contentHash = remoteBookmark.uniqueIdentifier
            let isDeletedByContent = !contentHash.isEmpty && deletedIds.contains("content:\(contentHash)")

            if isDeletedById || isDeletedByContent {
                Log.info(#file, "🗑️ BLOCKING deleted bookmark from re-appearing: annotationId=\(remoteBookmark.annotationId), timestamp=\(remoteBookmark.lastSavedTimeStamp ?? "nil")")
                return false
            }
            return true
        }

        if filteredRemoteBookmarks.count < remoteBookmarks.count {
            Log.info(#file, "🗑️ Blocked \(remoteBookmarks.count - filteredRemoteBookmarks.count) previously-deleted bookmark(s) from server")
        }

        var updatedLocalBookmarks = localBookmarks

        let newRemoteBookmarks = filteredRemoteBookmarks.filter { remoteBookmark in
            let isSimilar = localBookmarks.contains { $0.isSimilar(to: remoteBookmark) }
            if isSimilar {
                Log.debug(#file, "🔄 Remote bookmark already exists locally: chapter=\(remoteBookmark.chapter ?? "nil"), timestamp=\(remoteBookmark.lastSavedTimeStamp ?? "nil")")
            }
            return !isSimilar
        }

        Log.info(#file, "🔄 NEW REMOTE BOOKMARKS to add locally: \(newRemoteBookmarks.count)")
        for (index, bookmark) in newRemoteBookmarks.enumerated() {
            Log.info(#file, "🔄 New Remote #\(index): version=\(bookmark.version), timestamp=\(bookmark.lastSavedTimeStamp ?? "nil"), annotationId=\(bookmark.annotationId), chapter=\(bookmark.chapter ?? "nil"), readingOrderItem=\(bookmark.readingOrderItem ?? "nil")")
        }

        addNewBookmarksToLocalStore(newRemoteBookmarks)

        updatedLocalBookmarks = fetchLocalBookmarks()
        Log.info(#file, "🔄 FINAL LOCAL BOOKMARKS after merge: \(updatedLocalBookmarks.count)")

        completion(updatedLocalBookmarks)
    }

    private func addNewBookmarksToLocalStore(_ bookmarks: [AudioBookmark]) {
        Log.info(#file, "💾 Adding \(bookmarks.count) server bookmarks to local store")
        bookmarks.forEach { bookmark in
            Log.info(#file, "💾 Storing server bookmark: version=\(bookmark.version), timestamp=\(bookmark.lastSavedTimeStamp ?? "nil"), serverAnnotationId=\(bookmark.annotationId)")
            if let location = bookmark.toTPPBookLocation() {
                registry.addOrReplaceGenericBookmark(location, forIdentifier: book.identifier)
            }
        }
    }

    private func deleteBookmarks(_ bookmarks: [AudioBookmark]) {
        bookmarks.forEach { bookmark in
            deleteBookmark(at: bookmark)
            annotationsManager.deleteBookmark(annotationId: bookmark.annotationId) { _ in }
        }
    }

    private func finalizeSync(with bookmarks: [AudioBookmark], completion: AudioBookmarkListCompletionBox?) {
        // Swift 6 `complete`: box the `[AudioBookmark]` result so it — and the
        // already-boxed queued handlers — cross the `@Sendable`
        // `DispatchQueue.main.async` boundary as Sendable carriers.
        let bookmarksBox = AudioBookmarkListBox(bookmarks)
        // Reset `isSyncing` and drain the queued handlers atomically, then fire
        // them off-lock on main. Draining inside the lock prevents a handler
        // enqueued by a concurrent `syncBookmarks` from being lost or
        // double-invoked while the array is being iterated/cleared.
        let queuedHandlers: [AudioBookmarkListCompletionBox] = onStateQueue {
            isSyncing = false
            let drained = completionHandlersQueue
            completionHandlersQueue.removeAll()
            return drained
        }
        DispatchQueue.main.async {
            completion?.call?(bookmarksBox.bookmarks)
            queuedHandlers.forEach { $0.call?(bookmarksBox.bookmarks) }
        }
    }

    private func replace(oldLocation: AudioBookmark, with newLocation: AudioBookmark) {
        guard
            let oldLocation = oldLocation.toTPPBookLocation(),
            let newLocation = newLocation.toTPPBookLocation() else { return }
        registry.replaceGenericBookmark(oldLocation, with: newLocation, forIdentifier: book.identifier)
    }

    // MARK: - Helpers

    /// Immediately flushes any pending debounced operations
    /// Call this on app lifecycle events (willTerminate, didEnterBackground) to ensure no data loss
    public func flushPendingOperations() {
        queue.sync {
            guard let workItem = debounceWorkItem else { return }
            Log.debug(#file, "Flushing pending operations immediately")
            workItem.cancel()
            workItem.perform()
            debounceWorkItem = nil
        }
    }

    public func saveListeningPositionSync(at position: TrackPosition) {
        let audioBookmark = position.toAudioBookmark()
        audioBookmark.lastSavedTimeStamp = Date().iso8601

        guard let tppLocation = audioBookmark.toTPPBookLocation() else { return }

        if let registryWithSync = registry as? TPPBookRegistry {
            registryWithSync.setLocationSync(tppLocation, forIdentifier: self.book.identifier)
            Log.debug(#file, "🔒 SYNC: Saved position for termination: track=\(position.track.key), time=\(position.timestamp)")
        } else {
            registry.setLocation(tppLocation, forIdentifier: self.book.identifier)
            Log.warn(#file, "⚠️ Registry doesn't support sync save, using async fallback")
        }
    }

    // Swift 6 `complete`: `action` is `@Sendable` because it is captured by the
    // `@Sendable` work-`queue` closure and wrapped in a `DispatchWorkItem` (whose
    // `block:` init requires a `@Sendable` block). The sole caller (`saveBookmark`)
    // passes a closure that captures only Sendable carriers (a `TrackPositionCompletionBox`
    // and the `@preconcurrency`-imported `TrackPosition`), so this does not ripple.
    private func debounce(action: @escaping @Sendable () -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            self.debounceWorkItem?.cancel()

            let workItem = DispatchWorkItem(block: action)
            self.debounceWorkItem = workItem
            DispatchQueue.global(qos: .userInitiated).asyncAfter(
                deadline: .now() + self.debounceInterval,
                execute: workItem
            )
        }
    }
}

private extension Array where Element == AudioBookmark {
    func combineAndRemoveDuplicates(with otherArray: [AudioBookmark]) -> [AudioBookmark] {
        var uniqueArray: [AudioBookmark] = []

        for location in (self + otherArray) where !uniqueArray.contains(where: { $0.isSimilar(to: location) }) {
            uniqueArray.append(location)
        }

        return uniqueArray
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

extension AudiobookBookmarkBusinessLogic: AudiobookBookmarkDelegate {}

// MARK: - Sendable carrier for `saveBookmark`'s @Sendable-closure capture

/// Sendable carrier for the non-Sendable `completion` closure captured by the
/// `@Sendable` `Task` closure in `saveBookmark`. Wrapping the closure lets the
/// Task capture this box (Sendable) instead of the raw closure, clearing the
/// `targeted` capture diagnostic WITHOUT rippling `@Sendable` onto the public
/// `saveBookmark(at:completion:)` signature (which would ripple to every caller).
///
/// INVARIANT — the boxed closure is only ever invoked on the main queue: both
/// call sites are inside `DispatchQueue.main.async` blocks (the `defer` success
/// path and the encode-failure early return). It is never invoked concurrently.
/// Mirrors `ImageCompletionBox` in `ImageLoaderImpl`.
private final class TrackPositionCompletionBox: @unchecked Sendable {
    let call: ((TrackPosition?) -> Void)?
    init(_ call: ((TrackPosition?) -> Void)?) { self.call = call }
}

// MARK: - Sendable carriers for the bookmark-sync @Sendable-closure captures

/// Sendable carrier for a non-Sendable `[TrackPosition]` completion closure
/// captured by the `@Sendable` work-`queue` / `DispatchQueue.main.async` chain
/// in `fetchBookmarks`. INVARIANT — invoked only on the main queue.
/// Mirrors `TrackPositionCompletionBox` / `ReadiumBookmarkBox`.
private final class TrackPositionListCompletionBox: @unchecked Sendable {
    let call: ([TrackPosition]) -> Void
    init(_ call: @escaping ([TrackPosition]) -> Void) { self.call = call }
}

/// Sendable carrier for a non-Sendable `[AudioBookmark]` completion closure
/// captured by the `@Sendable` `Task` in `syncBookmarks` and the
/// `DispatchQueue.main.async` drain in `finalizeSync`. `AudioBookmark` is a
/// Palace-owned mutable class (9 mutable `var`s) that must NOT be made
/// `: Sendable` — boxing the closure is the correct ceiling, mirroring
/// `ReadiumBookmarkBox` (Decision 3). INVARIANT — the boxed closure is only
/// ever invoked on the main queue (the `finalizeSync` drain). The serial work
/// `queue` remains the single serialization domain for the sync state, so no
/// two invocations race.
private final class AudioBookmarkListCompletionBox: @unchecked Sendable {
    let call: (([AudioBookmark]) -> Void)?
    init(_ call: (([AudioBookmark]) -> Void)?) { self.call = call }
}

/// Sendable carrier for a non-Sendable `[AudioBookmark]` value crossing a
/// `@Sendable` `Task` / `DispatchQueue.main.async` boundary (the sync input in
/// `syncBookmarks`, the result in `finalizeSync`). The wrapped array and its
/// `AudioBookmark` elements are only ever produced, merged, and consumed on the
/// serial work `queue` or the main queue — never mutated concurrently across
/// the box — so `@unchecked Sendable` waives no real race.
private final class AudioBookmarkListBox: @unchecked Sendable {
    let bookmarks: [AudioBookmark]
    init(_ bookmarks: [AudioBookmark]) { self.bookmarks = bookmarks }
}

/// Sendable carrier for a non-Sendable `[TrackPosition]` value crossing the
/// `@Sendable` `DispatchQueue.main.async` boundary in `fetchBookmarks`.
/// `TrackPosition` is a `@preconcurrency`-imported PalaceAudiobookToolkit value
/// type: the pre-concurrency import covers its missing `Sendable` conformance,
/// but region isolation still flags *sending* the array across the async hop.
/// INVARIANT — the array is produced on the serial work `queue` and consumed
/// exactly once on the main queue; no two contexts touch it concurrently, so
/// `@unchecked Sendable` waives no real race. Mirrors `AudioBookmarkListBox`.
private final class TrackPositionListBox: @unchecked Sendable {
    let positions: [TrackPosition]
    init(_ positions: [TrackPosition]) { self.positions = positions }
}

/// Sendable carrier for a single non-Sendable `AudioBookmark` handed off to the
/// `@Sendable` `Task` in `saveListeningPosition`. INVARIANT — the wrapped
/// bookmark is created immediately before the Task and owned exclusively by it;
/// the synchronous prefix finishes touching it before the Task is enqueued and
/// no other task aliases it, so the in-Task `annotationId` mutation is race-free.
private final class AudioBookmarkBox: @unchecked Sendable {
    let bookmark: AudioBookmark
    init(_ bookmark: AudioBookmark) { self.bookmark = bookmark }
}

/// Sendable carrier for a non-Sendable `String?` completion closure captured by
/// the `@Sendable` `Task` in `saveListeningPosition`. INVARIANT — invoked only
/// inside that single Task (server-sync terminal paths). Mirrors
/// `TrackPositionCompletionBox`.
private final class StringCompletionBox: @unchecked Sendable {
    let call: ((String?) -> Void)?
    init(_ call: ((String?) -> Void)?) { self.call = call }
}

/// Sendable carrier for a non-Sendable `Bool` completion closure captured by the
/// `@Sendable` `DispatchQueue.main.async` blocks in `deleteBookmark` /
/// `deleteBookmarkByContentMatch`. INVARIANT — invoked only on the main queue,
/// exactly once per delete request (the terminal paths are mutually exclusive).
/// Mirrors `TrackPositionCompletionBox`.
private final class BoolCompletionBox: @unchecked Sendable {
    let call: ((Bool) -> Void)?
    init(_ call: ((Bool) -> Void)?) { self.call = call }
}
