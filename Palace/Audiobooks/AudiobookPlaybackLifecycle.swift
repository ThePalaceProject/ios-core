//
//  AudiobookPlaybackLifecycle.swift
//  Palace
//
//  The playback lifecycle signals that decide whether the app's audiobook
//  player UI reports playing or paused.
//
//  Extracted from `AudiobookSessionManager` rather than added to it: the
//  session manager is a frozen god-class under the decomposition ratchet, and
//  this is a pure decision with no need of its state.
//

import Foundation
import PalaceAudiobookToolkit

/// A toolkit playback signal, as far as the app's play-state is concerned.
///
/// Modelled as a table rather than decided at each `handleManagerState` arm
/// because every defect in this area has been an unenumerated cell, and a
/// signal added later would otherwise silently inherit whatever its arm
/// happened to do.
enum AudiobookPlaybackLifecycleSignal: CaseIterable {
    /// Playback began — including every buffer→resume during a skip burst.
    case began
    /// Playback genuinely stopped: the patron paused, an interruption, or the
    /// explicit pause every player issues at the end of a book.
    case stopped
    /// A CHAPTER ended. Not the book. See `playStateChange`.
    case chapterCompleted

    /// Whether this signal means the player is now playing (`true`), paused
    /// (`false`), or says nothing about play state at all (`nil`).
    ///
    /// `.chapterCompleted` is the `nil`, and that is PP-4951. It used to pause.
    /// The signal does not mean the patron stopped listening — it means one
    /// chapter ended and the next is starting, and nothing on that path calls
    /// `player.pause()`; the audio runs straight through. On Findaway it fires
    /// at every chapter boundary and always has, so the app has been flipping
    /// itself to `.paused` once per chapter for the whole of every DRM title.
    ///
    /// That is usually invisible, because the next chapter's `.playbackBegan`
    /// lands immediately after and puts the state back. It is not always
    /// invisible: the Findaway `FAEPlaybackChapterComplete` notification is
    /// documented in the toolkit as sometimes arriving several seconds late,
    /// and one that lands AFTER the next chapter's `.playbackBegan` leaves the
    /// app showing paused over playing audio. The toolkit's own
    /// `AudiobookPlaybackModel` survives that because it re-syncs from a 0.5s
    /// `isPlaying` poll. `AudiobookSessionManager` has no poll, so the wrong
    /// state simply stays until the patron touches something.
    ///
    /// The end of a BOOK does not depend on this signal to park the UI, and the
    /// route differs by player — worth stating exactly, because "every player
    /// pauses at end of book" is nearly true and the exception is the DRM one:
    ///
    /// * `OpenAccessPlayer` and `LCPStreamingPlayer` send `.bookCompleted` and
    ///   then `.stopped(beginningPosition)` from `handlePlaybackEnd`, which
    ///   arrives as `.playbackStopped` and pauses directly.
    /// * `FindawayPlayer.audioEngineAudiobookCompleted` sends `.bookCompleted`
    ///   and then `.started(beginningPosition)` — so the app is briefly told
    ///   playback BEGAN at the start of the book. The stop follows indirectly,
    ///   via `shouldPauseWhenPlaybackResumes` → `performPause` → `.stopped`.
    ///   Its track-exhaustion path (`handlePlaybackEnd`) does call `pause()`
    ///   directly, but that is not the path a completed Findaway book takes.
    ///
    /// Either way a stop arrives on a signal that is not this one, so removing
    /// the pause from a chapter ending does not leave a finished book reporting
    /// that it is still playing. The Findaway ordering above is pre-existing and
    /// deliberately unchanged here.
    var playStateChange: Bool? {
        switch self {
        case .began: return true
        case .stopped: return false
        case .chapterCompleted: return nil
        }
    }

    /// Which lifecycle signal, if any, a toolkit manager state carries.
    ///
    /// `nil` means the state does not participate in this table — either it says
    /// nothing about playback (`.positionUpdated`, bookmark traffic) or it owns
    /// its own play-state handling. `.playbackFailed` is the second kind: it
    /// sets `isPlaying = false` itself, inside branching recovery logic that
    /// decides between `.loading`, `.error` and a silent re-open, and folding
    /// that into a two-value table would misrepresent it.
    ///
    /// Keyed on the manager state rather than left to each `switch` arm on
    /// purpose. With the arm choosing its own signal, the mapping that actually
    /// carries the PP-4951 defect — "a completed chapter means stopped" — sat
    /// outside anything a test could reach: swapping the arm's argument to
    /// `.stopped` reintroduced the bug with the whole suite green.
    static func signal(for managerState: AudiobookManagerState) -> Self? {
        switch managerState {
        case .playbackBegan: return .began
        case .playbackStopped: return .stopped
        case .playbackCompleted: return .chapterCompleted

        // Enumerated rather than defaulted. A `default` would hand a newly added
        // toolkit case a silent `nil` — the exact silent-inheritance this table
        // exists to prevent, reintroduced one level up. Listing them makes the
        // compiler name any new case at the point someone must decide about it.
        //
        // `.playbackFailed` is the one that opts out for a reason rather than
        // for irrelevance: it sets `isPlaying` itself, inside branching recovery
        // that chooses between `.loading`, `.error` and a silent re-open.
        case .playbackFailed: return nil
        case .positionUpdated, .refreshRequested, .locationPosted,
             .bookmarkSaved, .bookmarksFetched, .bookmarkDeleted,
             .playbackUnloaded, .overallDownloadProgress, .error:
            return nil

        // The toolkit ships with `BUILD_LIBRARY_FOR_DISTRIBUTION = YES`, so this
        // enum is non-frozen and a `@unknown default` is required. It warns at
        // compile time, which is the strongest guard available across that
        // module boundary.
        @unknown default: return nil
        }
    }

    /// The `isPlaying` / session-state pair a manager state implies, or `nil` to
    /// leave both untouched.
    ///
    /// Returns the pair together so the two can never disagree — `isPlaying`
    /// true beside `.paused` is unrepresentable here, where two separate
    /// assignments at a call site could drift apart unnoticed.
    static func playState(
        for managerState: AudiobookManagerState,
        bookId: String
    ) -> (isPlaying: Bool, state: AudiobookSessionState)? {
        guard let nowPlaying = signal(for: managerState)?.playStateChange else { return nil }
        return (nowPlaying, nowPlaying ? .playing(bookId: bookId) : .paused(bookId: bookId))
    }
}
