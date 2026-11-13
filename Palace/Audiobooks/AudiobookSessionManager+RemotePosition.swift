//
//  AudiobookSessionManager+RemotePosition.swift
//  Palace
//
//  What stopping playback and returning a loan do to the queued remote
//  listening position. Split out of AudiobookSessionManager.swift to keep that
//  file under its size cap.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import PalaceAudiobookToolkit

extension AudiobookSessionManager {

    /// Cancels any pending throttled remote
    /// listening-position write for `bookId` by routing to the live bookmark
    /// delegate (`AudiobookBookmarkBusinessLogic`) that owns the
    /// `RemotePositionWriter`. Only cancels when `bookId` is the active
    /// session's book (a queued write can only exist for the book whose
    /// delegate is currently bound); a no-op otherwise. Used by the
    /// `BookReturnService` return path (via the `AudiobookSessionManaging`
    /// protocol on `AppContainer.audiobookSession`); `stopPlayback` goes
    /// through `settleRemotePosition`.
    @MainActor
    func cancelPendingRemotePositionWrite(forBookId bookId: String) async {
        await Self.positionLogic(manager?.bookmarkDelegate, bookId: bookId)?.cancelPendingRemotePositionWrite()
    }

    /// The bookmark logic that owns the remote position writer, when it is
    /// bound to `bookId`. A queued write can exist only for that book.
    static func positionLogic(_ delegate: AudiobookBookmarkDelegate?, bookId: String?) -> AudiobookBookmarkBusinessLogic? {
        guard let logic = delegate as? AudiobookBookmarkBusinessLogic,
              let bookId, logic.book.identifier == bookId else {
            return nil
        }
        return logic
    }

    /// What stopping playback does to the remote listening position.
    ///
    /// - Keeping the final position (a close): run `saveFinalPosition`, then
    ///   post the queued position now instead of when the writer's throttle
    ///   window ends (PP-5595). The returned Task keeps the logic and its
    ///   writer alive past teardown; the post runs in a background task.
    /// - Not keeping it (a return): cancel the queued write first, so a stale
    ///   snapshot cannot flush after teardown and resurrect an old server
    ///   position (3.2.3 Cause 2). `saveFinalPosition` does not run.
    @discardableResult
    static func settleRemotePosition(
        logic: AudiobookBookmarkBusinessLogic?,
        persistFinalPosition: Bool,
        saveFinalPosition: () -> Void
    ) async -> Task<Void, Never>? {
        guard persistFinalPosition else {
            await logic?.cancelPendingRemotePositionWrite()
            return nil
        }
        saveFinalPosition()
        guard let logic else { return nil }
        return Task { await logic.flushPendingRemotePositionWrite() }
    }
}
