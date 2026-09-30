//
//  AudiobookSessionManager+MediaServicesReset.swift
//  Palace
//
//  PP-5241: the session manager's side of the media-services-reset recovery.
//  The recovery's decisions live in MediaServicesResetRecovery.swift.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import PalaceBookModel

// MARK: - MediaServicesResetRecoveryHost (PP-5241)

// Out of the hub so it does not count against AudiobookSessionManager's
// line-count ceiling. The two session-state writes go through
// `publishMediaServicesResetState(_:)`, because `state` and `isPlaying` are
// `private(set)` to the hub's file.
extension AudiobookSessionManager: MediaServicesResetRecoveryHost {

    func mediaServicesResetLoadedSession() -> MediaServicesResetSession? {
        Self.mediaServicesResetSession(
            book: currentBook,
            hasActiveManager: hasActiveManager,
            isPlaying: isPlaying,
            state: state
        )
    }

    /// `currentPosition` is the last position the live player published. The
    /// player is deliberately not asked: after a real reset it is dead.
    func mediaServicesResetPersistLastKnownPosition(bookId: String) {
        guard currentBook?.identifier == bookId, let position = currentPosition else { return }
        manager?.saveLocation(position)
    }

    /// Park the session in `.loading` so the presenter shows the loading shell
    /// while it recovers, the same anti-flash state the other recoveries use.
    func mediaServicesResetEnterRecovering(bookId: String) {
        publishMediaServicesResetState(.loading(bookId: bookId))
    }

    /// Re-establish the session after a media-services reset.
    ///
    /// - Playing: the recovery re-open. `openAudiobook` re-applies the audio
    ///   session category and activation (`ensureAudioSessionActiveForPlayback`),
    ///   builds a new player, and restores the position through the normal
    ///   restore path (persisted local position, or a newer remote bookmark).
    ///   Its teardown of the dead session does not persist a position, because
    ///   a same-book re-open sets `persistFinalPositionOnTeardown` to false
    ///   (`PlaybackOpenPolicy.decide`), so the dead player's position is not
    ///   written back.
    /// - Paused: tear the dead session down without persisting its position.
    ///   It is not re-opened paused: `bind` restores no position when
    ///   `startPlaying` is false, so the new model would sit at the first
    ///   track's 0:00, and a later lifecycle save would persist that. The
    ///   patron re-opens the book and resumes from the persisted position.
    func mediaServicesResetReestablish(book: TPPBook, resumePlaying: Bool) async -> Bool {
        guard currentBook?.identifier == book.identifier else { return false }
        if resumePlaying {
            let result = await openAudiobook(book, startPlaying: true, forceRefulfill: false, isRecoveryReopen: true)
            if case .success = result { return true }
            return false
        }
        await stopPlayback(dismissPhoneUI: true, persistFinalPosition: false)
        return true
    }

    /// The recovery did not re-establish the session. `openAudiobook`'s own
    /// failure paths already publish their terminal state; this only acts
    /// when the session is still parked in the recovery's `.loading`, so the
    /// patron is not left on a loading shell.
    func mediaServicesResetFailTerminally(bookId: String) {
        guard case .loading(let loadingId) = state, loadingId == bookId else { return }
        publishMediaServicesResetState(.error(bookId: bookId, message: "Playback failed"))
        errorPublisher.send(.unknown("Playback failed"))
    }
}
