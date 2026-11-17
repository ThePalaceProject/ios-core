//
//  AudiobookPositionResolver.swift
//  Palace
//
//  Decides which position an audiobook opens at: the locally-saved one, the
//  server-synced one, or the beginning (PP-4542). The bounded network await
//  (`awaitRemotePosition`) is separate from the pure choice
//  (`chooseInitialPosition`), which is tested as a table in
//  `AudiobookPositionResolverDecisionTableTests`. A class because it depends
//  on `bookRegistry` and an injected `[AUDIOPOS]` logger.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
@preconcurrency import PalaceAudiobookToolkit
import PalaceBookModel
import PalaceBookRegistry
import PalaceLogging

/// Resolves the `TrackPosition` an audiobook should open at.
///
/// `@MainActor` to match the isolation it had inside `AudiobookSessionManager`.
@MainActor
final class AudiobookPositionResolver {

    /// PP-4542: maximum time to wait for the server-synced position before
    /// opening at the local/beginning position, so a slow backend can't stall
    /// audiobook open. Audiobook bookmarks normally return in ~0.5s; this is the
    /// rare-slow-case safety valve.
    static let remotePositionResolveTimeout: TimeInterval = 2.5

    private let bookRegistry: TPPBookRegistryProvider

    /// Logger for `[AUDIOPOS]` diagnostic lines. Indirected through a protocol
    /// so unit tests can spy on emissions without scraping Crashlytics output.
    /// Production binds the default which routes through `Log.warn`.
    var positionLogger: AudiobookPositionLogging = DefaultAudiobookPositionLogger()

    init(bookRegistry: TPPBookRegistryProvider) {
        self.bookRegistry = bookRegistry
    }

    // MARK: - Open-time resolution (PP-4542)

    /// Resolves the position to OPEN at: awaits the remote bookmark (bounded) and
    /// prefers it over the local position only when meaningfully newer (the same
    /// >5s rule the prior post-play seek used), otherwise returns `fallback`
    /// (local-or-beginning). Running this BEFORE the first play is what removes
    /// the "jump" — the player opens directly at the resolved spot.
    func resolveInitialPosition(
        for book: TPPBook,
        audiobook: Audiobook,
        localPosition: TrackPosition?,
        fallback: TrackPosition
    ) async -> TrackPosition {
        let remote = await awaitRemotePosition(
            for: book,
            audiobook: audiobook,
            timeout: Self.remotePositionResolveTimeout
        )
        return chooseInitialPosition(
            remote: remote,
            localPosition: localPosition,
            fallback: fallback,
            in: audiobook.tableOfContents,
            bookId: book.identifier
        )
    }

    /// The pure half of `resolveInitialPosition`: given whatever the bounded
    /// remote await produced, decide what the player opens at.
    ///
    ///  - no remote (slow backend, no server bookmark, or a test registry) ⇒
    ///    `fallback`, which is the validated local position or chapter 1;
    ///  - a remote that is not meaningfully newer than the local save ⇒
    ///    `fallback`, so a stale server copy cannot drag the patron backwards;
    ///  - a remote that IS newer but whose track key is absent from the loaded
    ///    manifest ⇒ `fallback`, the 3.2.3 Cause 2 gate;
    ///  - a remote that is newer and validates ⇒ the remote position.
    func chooseInitialPosition(
        remote: TrackPosition?,
        localPosition: TrackPosition?,
        fallback: TrackPosition,
        in tableOfContents: AudiobookTableOfContents,
        bookId: String
    ) -> TrackPosition {
        guard let remote else {
            Log.debug(#file, "No remote position resolved before play — opening at local position")
            return fallback
        }
        guard Self.preferRemotePosition(local: localPosition, remote: remote) else {
            Log.debug(#file, "Local position is current — opening at local position")
            return fallback
        }
        // Validate the remote position against the manifest with the same gate
        // as the local path: seeking a stale track key opens at a phantom
        // position.
        return validatedRemotePosition(
            remote,
            fallback: fallback,
            in: tableOfContents,
            bookId: bookId
        )
    }

    /// Applies the manifest-validation gate to a resolved REMOTE position,
    /// mirroring the local path's `validationFailure(for:in:)` check. Returns
    /// `remote` when it validates against the loaded manifest, else `fallback`
    /// — a remote track key that isn't in the manifest must not be seeked
    /// verbatim. `internal` for unit tests.
    func validatedRemotePosition(
        _ remote: TrackPosition,
        fallback: TrackPosition,
        in tableOfContents: AudiobookTableOfContents,
        bookId: String
    ) -> TrackPosition {
        if let failure = validationFailure(for: remote, in: tableOfContents) {
            let manifestKeys = tableOfContents.tracks.tracks
                .prefix(5).map(\.key).joined(separator: ",")
            positionLogger.logFailure(
                reason: failureReasonString(failure),
                context: [
                    "bookId": bookId,
                    "savedKey": remote.track.key,
                    "manifestKeys": manifestKeys,
                    "source": "remote"
                ]
            )
            return fallback
        }
        Log.info(#file, "📡 Opening at remote position (newer than local): track=\(remote.track.key), timestamp=\(remote.timestamp)")
        return remote
    }

    /// Bounded await of the server-synced position. Resolves to the remote
    /// `TrackPosition` if the bookmark sync returns one within `timeout`, else
    /// `nil` (slow/again backend or no remote bookmark). Single-resume guarded so
    /// the timeout and the sync callback race safely. No-ops to `nil` for a
    /// mock-injected registry (tests), so the local position alone drives open.
    @MainActor
    private func awaitRemotePosition(
        for book: TPPBook,
        audiobook: Audiobook,
        timeout: TimeInterval
    ) async -> TrackPosition? {
        guard let concreteRegistry = bookRegistry as? TPPBookRegistry else { return nil }
        let toc = audiobook.tableOfContents
        // `TrackPosition` is not Sendable and the completion fires off this
        // actor, so the value crosses the continuation in a box.
        let box: SendableTrackPositionBox = await withCheckedContinuation { (cont: CheckedContinuation<SendableTrackPositionBox, Never>) in
            let once = PositionResolveOnce()
            concreteRegistry.syncLocation(for: book) { (remoteBookmark: AudioBookmark?) in
                // Build the position inline, not via `.flatMap { … }`: this
                // completion runs on a background queue, and a non-`@Sendable`
                // nested closure would inherit `@MainActor` isolation and trap
                // with `dispatch_assert_queue_fail` (Crashlytics 6e05efb).
                let position: TrackPosition?
                if let remoteBookmark {
                    position = TrackPosition(audioBookmark: remoteBookmark, toc: toc.toc, tracks: toc.tracks)
                } else {
                    position = nil
                }
                let boxed = SendableTrackPositionBox(position)
                once.fire { cont.resume(returning: boxed) }
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                once.fire { cont.resume(returning: SendableTrackPositionBox(nil)) }
            }
        }
        return box.value
    }

    /// True iff `remote` should be preferred over `local` — i.e. the remote save
    /// is >5s newer (no local ⇒ prefer remote). Pure/static so it's unit-pinnable.
    static func preferRemotePosition(local: TrackPosition?, remote: TrackPosition) -> Bool {
        let formatter = ISO8601DateFormatter()
        guard let remoteDate = formatter.date(from: remote.lastSavedTimeStamp) else { return false }
        guard let local = local,
              let localDate = formatter.date(from: local.lastSavedTimeStamp) else {
            return true
        }
        return remoteDate.timeIntervalSince(localDate) > 5.0
    }

    // MARK: - Local position restore

    func shouldRestoreBookmarkPosition(for book: TPPBook) -> Bool {
        let hasLocation = bookRegistry.location(forIdentifier: book.identifier) != nil
        guard hasLocation else { return false }
        return true
    }

    /// Returns a `TrackPosition` reconstructed from the registry's saved
    /// location for `book`, validated against the loaded audiobook's manifest.
    ///
    /// Failure modes are individually logged with `[AUDIOPOS]` markers. When
    /// the primary saved location can't be used but the registry has other
    /// generic bookmarks for this book, the most-recent valid one is returned
    /// as a fallback (better than dropping the patron to chapter-1 start).
    /// Returns `nil` only when there's nothing usable at all.
    // `internal` for AudiobookPositionRestoreTests.
    func getValidLocalPosition(book: TPPBook, audiobook: Audiobook) -> TrackPosition? {
        let primary = tryLoadPrimaryLocalPosition(book: book, audiobook: audiobook)
        switch primary {
        case .success(let position):
            return position
        case .failure:
            // Fall back to most-recent valid generic bookmark.
            if let fallback = fallbackToMostRecentValidBookmark(book: book, audiobook: audiobook) {
                positionLogger.logFallback(
                    reason: "primary_position_invalid_using_recent_bookmark",
                    context: ["bookId": book.identifier]
                )
                return fallback
            }
            return nil
        }
    }

    /// Tries to reconstruct the position from `bookRegistry.location(...)`.
    /// Each early-out logs a `[AUDIOPOS] FAIL` line so support can grep the
    /// crashlog and see exactly which step dropped the saved position.
    private func tryLoadPrimaryLocalPosition(
        book: TPPBook,
        audiobook: Audiobook
    ) -> Result<TrackPosition, AudiobookPositionValidationFailure> {
        guard let location = bookRegistry.location(forIdentifier: book.identifier) else {
            positionLogger.logFailure(reason: "no_location", context: ["bookId": book.identifier])
            return .failure(.trackKeyNotInManifest(savedKey: ""))
        }
        guard let dict = location.locationStringDictionary() else {
            positionLogger.logFailure(reason: "locator_decode", context: ["bookId": book.identifier])
            return .failure(.trackKeyNotInManifest(savedKey: ""))
        }
        guard let localBookmark = AudioBookmark.create(locatorData: dict) else {
            positionLogger.logFailure(reason: "bookmark_create", context: ["bookId": book.identifier])
            return .failure(.trackKeyNotInManifest(savedKey: ""))
        }
        guard let localPosition = TrackPosition(
            audioBookmark: localBookmark,
            toc: audiobook.tableOfContents.toc,
            tracks: audiobook.tableOfContents.tracks
        ) else {
            positionLogger.logFailure(
                reason: "trackposition_construct",
                context: ["bookId": book.identifier]
            )
            return .failure(.trackKeyNotInManifest(savedKey: ""))
        }
        if let failure = validationFailure(for: localPosition, in: audiobook.tableOfContents) {
            // Manifest keys for diagnostic context (first few only — avoid bloat).
            let manifestKeys = audiobook.tableOfContents.tracks.tracks
                .prefix(5).map(\.key).joined(separator: ",")
            positionLogger.logFailure(
                reason: failureReasonString(failure),
                context: [
                    "bookId": book.identifier,
                    "savedKey": localPosition.track.key,
                    "manifestKeys": manifestKeys
                ]
            )
            return .failure(failure)
        }
        return .success(localPosition)
    }

    /// Returns the most-recent valid `TrackPosition` from
    /// `bookRegistry.genericBookmarksForIdentifier(...)`, where "valid" means
    /// the validator accepts it AND it parses against the current manifest.
    /// Recency is by `lastSavedTimeStamp` (ISO8601), falling back to array
    /// order when timestamps are missing.
    func fallbackToMostRecentValidBookmark(
        book: TPPBook,
        audiobook: Audiobook
    ) -> TrackPosition? {
        let bookmarks = bookRegistry.genericBookmarksForIdentifier(book.identifier)
        guard !bookmarks.isEmpty else { return nil }
        return selectMostRecentValidBookmark(
            from: bookmarks,
            in: audiobook.tableOfContents
        )
    }

    /// Pure candidate-selection seam: from a set of saved generic bookmarks,
    /// reconstruct each against the manifest, drop any that fail validation,
    /// and return the most-recent valid one (descending `lastSavedTimeStamp`,
    /// which is ISO8601 and therefore lexicographically sortable).
    ///
    /// Takes `AudiobookTableOfContents` rather than `Audiobook` so it is
    /// testable without a player graph.
    func selectMostRecentValidBookmark(
        from bookmarks: [TPPBookLocation],
        in tableOfContents: AudiobookTableOfContents
    ) -> TrackPosition? {
        let candidates: [(TrackPosition, String)] = bookmarks.compactMap { location in
            guard let dict = location.locationStringDictionary(),
                  let bookmark = AudioBookmark.create(locatorData: dict),
                  let position = TrackPosition(
                    audioBookmark: bookmark,
                    toc: tableOfContents.toc,
                    tracks: tableOfContents.tracks
                  ),
                  validationFailure(for: position, in: tableOfContents) == nil else {
                return nil
            }
            return (position, bookmark.lastSavedTimeStamp ?? "")
        }

        guard !candidates.isEmpty else { return nil }
        // Descending by timestamp string (ISO8601 is lexicographically sortable).
        let sorted = candidates.sorted { $0.1 > $1.1 }
        return sorted.first?.0
    }

    /// Re-uses `AudiobookPositionPolicy.validate`. The thin shim adapts the
    /// instance-level call site (which already has the toolkit's position
    /// object) to the pure-function policy (which doesn't need the toolkit).
    func validationFailure(
        for position: TrackPosition,
        in tableOfContents: AudiobookTableOfContents
    ) -> AudiobookPositionValidationFailure? {
        let trackKeyMatches = tableOfContents.tracks.track(forKey: position.track.key) != nil
        let totalDuration = tableOfContents.tracks.totalDuration
        let positionDuration = position.durationToSelf()
        let result = AudiobookPositionPolicy.validate(
            timestamp: position.timestamp,
            positionDuration: positionDuration,
            totalDuration: totalDuration,
            trackKeyMatchesManifest: trackKeyMatches,
            savedTrackKey: position.track.key
        )
        switch result {
        case .success: return nil
        case .failure(let f): return f
        }
    }

    /// Maps a validation failure to a short greppable reason string for the
    /// `[AUDIOPOS] FAIL: <reason>` log line. Keep these stable — they're
    /// matched by support staff in crashlog triage.
    private func failureReasonString(_ failure: AudiobookPositionValidationFailure) -> String {
        switch failure {
        case .negativeTimestamp: return "negative_timestamp"
        case .nonFiniteTimestamp: return "non_finite_timestamp"
        case .trackKeyNotInManifest: return "track_key_mismatch"
        case .positionExceedsCap: return "position_exceeds_cap"
        }
    }

    /// Kept as a thin wrapper for any in-file callers that just want a bool.
    /// New code should use `validationFailure(for:in:)` directly so the
    /// failure mode can be logged.
    func isValidPosition(_ position: TrackPosition, in tableOfContents: AudiobookTableOfContents) -> Bool {
        return validationFailure(for: position, in: tableOfContents) == nil
    }
}

/// One-shot resume guard (PP-4542): ensures a `CheckedContinuation` is resumed
/// exactly once when a bounded await races a timeout against a completion
/// callback. NSLock-guarded so the (possibly background-thread) sync callback and
/// the MainActor timeout can race safely without a double-resume trap.
///
/// - Sendable invariant: `fired` is only read and written under `lock`, so the
///   two racing `fire(_:)` calls serialize and exactly one runs `block`.
private final class PositionResolveOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func fire(_ block: @Sendable () -> Void) {
        lock.lock()
        if fired {
            lock.unlock()
            return
        }
        fired = true
        lock.unlock()
        block()
    }
}

/// `Sendable` carrier for a resolved `TrackPosition?` crossing the
/// `awaitRemotePosition` continuation boundary.
///
/// - Sendable invariant: `value` is set once at init and only read thereafter.
///   The `@unchecked` waiver covers the toolkit type the compiler cannot prove
///   `Sendable`.
private struct SendableTrackPositionBox: @unchecked Sendable {
    let value: TrackPosition?
    init(_ value: TrackPosition?) {
        self.value = value
    }
}
