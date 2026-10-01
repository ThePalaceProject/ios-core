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
import PalaceBookRegistry
@preconcurrency import PalaceAudiobookToolkit
import PalaceBookModel
import PalaceUtilities

// `@unchecked Sendable` invariant: injected dependencies are immutable `let`s,
// and all mutable sync state is accessed only through `onStateQueue` (or, for
// `debounceWorkItem`, on the serial work `queue`).
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
    // join it instead of polling a deadline. Access is confined to `queue`.
    private var _positionWriteTaskForTesting: Task<Void, Never>?

    // MARK: - Serialized sync state
    // `isSyncing`, `completionHandlersQueue`, and `deletedBookmarkIds` are
    // touched from the UI thread, URLSession completions and the work `queue`.
    // Concurrent mutation corrupted the collections' buffers (Crashlytics
    // abfef568), so all access goes through `onStateQueue`.
    private var isSyncing: Bool = false
    // Boxed so the drained handlers can be captured by the `@Sendable`
    // `DispatchQueue.main.async` closure in `finalizeSync` without crossing a
    // non-Sendable boundary (each element wraps a `([AudioBookmark]) -> Void`).
    private var completionHandlersQueue: [AudioBookmarkListCompletionBox] = []
    private var deletedBookmarkIds = Set<String>()

    @objc convenience init(book: TPPBook) {
        self.init(book: book, positionTrace: nil)
    }

    /// Production entry point that also wires the PP-4963 trace.
    convenience init(book: TPPBook, positionTrace: AudiobookPositionTraceRecorder?) {
        self.init(
            book: book,
            registry: AppContainer.production().bookRegistry,
            annotationsManager: TPPAnnotationsWrapper(),
            positionWriter: nil,
            positionTrace: positionTrace
        )
    }

    init(
        book: TPPBook,
        registry: TPPBookRegistryProvider,
        annotationsManager: AnnotationsManager,
        positionWriter: PositionWriter? = nil,
        positionTrace: AudiobookPositionTraceRecorder? = nil
    ) {
        self.positionTrace = positionTrace
        self.book = book
        self.registry = registry
        self.annotationsManager = annotationsManager
        // Default wraps the same `AnnotationsManager` the rest of this class uses.
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

    /// PP-4963 position trace, notified on every local position write (a
    /// successful save leaves no other record).
    ///
    /// A `let` so the `@unchecked Sendable` invariant holds, and held strongly
    /// here because this object lives for the whole session (via
    /// `AudiobookManager.bookmarkDelegate`); held elsewhere, the recorder
    /// deallocated seconds after playback began.
    private let positionTrace: AudiobookPositionTraceRecorder?

    // MARK: - Remote-write cancellation (3.2.3 Cause 2)

    /// Cancels any pending throttled remote listening-position write for this
    /// book so a queued snapshot can't flush AFTER session teardown / return
    /// cleanup and resurrect a stale server position.
    /// Idempotent; a no-op when the writer has nothing queued for this book.
    func cancelPendingRemotePositionWrite() async {
        await positionWriter.cancel(for: book.identifier)
    }

    // MARK: - Bookmark Management

    public func saveListeningPosition(at position: TrackPosition, completion: ((String?) -> Void)?) {
        let audioBookmark = position.toAudioBookmark()
        audioBookmark.lastSavedTimeStamp = Date().iso8601

        // Save to the local registry before any async work, so a crash or
        // background mid-flight never loses position state.
        guard let tppLocation = audioBookmark.toTPPBookLocation() else {
            completion?(nil)
            return
        }
        registry.setLocation(tppLocation, forIdentifier: self.book.identifier)
        Log.debug(#file, "💾 Immediately saved position locally: track=\(position.track.key), time=\(position.timestamp)")
        // PP-4963: the LOCAL write is what decides whether the patron keeps
        // their place, so the trace is notified here rather than after the
        // annotation post below (whose failures are a separate defect).
        positionTrace?.noteSave(at: Date())

        // Throttling, queueing and background-task lifetime live in the
        // PositionWriter; this method keeps audiobook-specific conflict resolution.
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

        // Box the non-Sendable completion and bookmark for the `@Sendable` Task;
        // the bookmark is owned exclusively by that Task from here on.
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

                // Conflict resolution: the timestamp-newer check and the
                // strict-zero isAtBeginning guard keep a valid local position
                // from being overwritten by an older upload result.
                //
                // The tolerance must be 0. `isDate` computes `d1 + delay > d2`,
                // and `lastSavedTimeStamp` has second granularity, so any positive
                // delay makes every same-second pair a tie that discards the
                // just-saved position. Do not change `isDate` itself: its other
                // callers use the delay deliberately as a grace window.
                if let currentLocal = self.registry.location(forIdentifier: self.book.identifier),
                   let currentDict = currentLocal.locationStringDictionary(),
                   let currentBookmark = AudioBookmark.create(locatorData: currentDict) {

                    let currentLocalTimestamp = currentBookmark.lastSavedTimeStamp ?? ""

                    if !currentLocalTimestamp.isEmpty && !sentTimestamp.isEmpty,
                       String.isDate(currentLocalTimestamp, moreRecentThan: sentTimestamp, with: 0) {
                        Log.warn(#file, "⚠️ Race condition detected: Local position is newer. Keeping local.")
                        Log.warn(#file, "  Sent: track=\(sentTrackKey), time=\(sentPlaybackTime), timestamp=\(sentTimestamp)")
                        Log.warn(#file, "  Current local: track=\(currentBookmark.chapter ?? "?"), timestamp=\(currentLocalTimestamp)")
                        completionBox.call?(serverID)
                        return
                    }

                    // Strict zero (see AudiobookPositionPolicy.swift): a grace
                    // window would discard real pauses early in chapter 1.
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

    /// Test-only join seam: awaits the most recent `saveListeningPosition` write
    /// `Task`, including its conflict resolution and completion. No-op if no
    /// write is in flight.
    func _awaitPositionWriteForTesting() async {
        let handle = onStateQueue { self._positionWriteTaskForTesting }
        await handle?.value
    }

    public func saveBookmark(at position: TrackPosition, completion: ((_ position: TrackPosition?) -> Void)? = nil) {
        // Boxed for the `@Sendable` debounce Task; invoked only on the main queue.
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
        // Boxed for the `@Sendable` closures below; invoked only on the main queue.
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

                // See `TrackPositionListBox`.
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
        // Boxed for the `@Sendable` main-queue hops; invoked only on the main queue.
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

        // A `let` so the `@Sendable` closures below capture an immutable value.
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
        // Boxed for the `@Sendable` Task; the values are only touched on `queue`
        // or the main queue.
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
        // PP-4963: the termination path is a save like any other, and leaving
        // it out would make a session that only ever saved on termination look
        // as though it had never saved at all.
        positionTrace?.noteSave(at: Date())
    }

    // `action` is `@Sendable` because `DispatchWorkItem(block:)` requires it.
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

/// Sendable carrier for `saveBookmark`'s completion, so `@Sendable` does not
/// ripple onto the public signature. Invariant: invoked only on the main queue.
private final class TrackPositionCompletionBox: @unchecked Sendable {
    let call: ((TrackPosition?) -> Void)?
    init(_ call: ((TrackPosition?) -> Void)?) { self.call = call }
}

// MARK: - Sendable carriers for the bookmark-sync @Sendable-closure captures

/// Sendable carrier for a non-Sendable `[TrackPosition]` completion closure
/// captured by the `@Sendable` work-`queue` / `DispatchQueue.main.async` chain
/// in `fetchBookmarks`. Invariant: invoked only on the main queue.
private final class TrackPositionListCompletionBox: @unchecked Sendable {
    let call: ([TrackPosition]) -> Void
    init(_ call: @escaping ([TrackPosition]) -> Void) { self.call = call }
}

/// Sendable carrier for a non-Sendable `[AudioBookmark]` completion closure
/// captured by the `@Sendable` `Task` in `syncBookmarks` and the
/// `DispatchQueue.main.async` drain in `finalizeSync`. Invariant: invoked only
/// on the main queue.
private final class AudioBookmarkListCompletionBox: @unchecked Sendable {
    let call: (([AudioBookmark]) -> Void)?
    init(_ call: (([AudioBookmark]) -> Void)?) { self.call = call }
}

/// Sendable carrier for a non-Sendable `[AudioBookmark]` value crossing a
/// `@Sendable` `Task` / `DispatchQueue.main.async` boundary (the sync input in
/// `syncBookmarks`, the result in `finalizeSync`). The wrapped array and its
/// `AudioBookmark` elements are only produced, merged and consumed on the
/// serial work `queue` or the main queue, never concurrently.
private final class AudioBookmarkListBox: @unchecked Sendable {
    let bookmarks: [AudioBookmark]
    init(_ bookmarks: [AudioBookmark]) { self.bookmarks = bookmarks }
}

/// Sendable carrier for a non-Sendable `[TrackPosition]` value crossing the
/// `@Sendable` `DispatchQueue.main.async` boundary in `fetchBookmarks`.
/// `@preconcurrency import` covers `TrackPosition`'s conformance but region
/// isolation still flags sending the array. Invariant: produced on the work
/// `queue`, consumed exactly once on the main queue.
private final class TrackPositionListBox: @unchecked Sendable {
    let positions: [TrackPosition]
    init(_ positions: [TrackPosition]) { self.positions = positions }
}

/// Sendable carrier for a single non-Sendable `AudioBookmark` handed off to the
/// `@Sendable` `Task` in `saveListeningPosition`. Invariant: created immediately
/// before the Task and owned exclusively by it.
private final class AudioBookmarkBox: @unchecked Sendable {
    let bookmark: AudioBookmark
    init(_ bookmark: AudioBookmark) { self.bookmark = bookmark }
}

/// Sendable carrier for a non-Sendable `String?` completion closure captured by
/// the `@Sendable` `Task` in `saveListeningPosition`. Invariant: invoked only
/// inside that Task.
private final class StringCompletionBox: @unchecked Sendable {
    let call: ((String?) -> Void)?
    init(_ call: ((String?) -> Void)?) { self.call = call }
}

/// Sendable carrier for a non-Sendable `Bool` completion closure captured by the
/// `@Sendable` `DispatchQueue.main.async` blocks in `deleteBookmark` /
/// `deleteBookmarkByContentMatch`. Invariant: invoked only on the main queue,
/// exactly once per delete request.
private final class BoolCompletionBox: @unchecked Sendable {
    let call: ((Bool) -> Void)?
    init(_ call: ((Bool) -> Void)?) { self.call = call }
}
