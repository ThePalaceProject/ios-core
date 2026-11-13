//
//  AudiobookSessionManager+PlaybackModelMirrors.swift
//  Palace
//
//  Values read straight from the bound session — the playback model, the
//  player, the sleep timer — each nil-safe, so a session with nothing bound
//  reports a quiet default rather than trapping.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import Foundation
import PalaceAudiobookToolkit

extension AudiobookSessionManager {

    /// Overall download progress (0…1) for the current audiobook's tracks.
    /// Drives the download bar in the in-app custom player.
    var overallDownloadProgress: Float {
        playbackModel?.overallDownloadProgress ?? 0
    }

    /// Whether tracks are still downloading / decrypting in the background
    /// (progress < 1).
    var isDownloading: Bool {
        playbackModel?.isDownloading ?? false
    }

    /// Chapter-relative playhead offset (seconds into the current chapter) —
    /// the raw value behind the toolkit player's elapsed timecode.
    var chapterOffset: TimeInterval {
        playbackModel?.chapterPlayheadOffset ?? 0
    }

    /// Seconds remaining in the current chapter — the raw value behind the
    /// toolkit player's chapter time-left timecode.
    var chapterTimeLeft: TimeInterval {
        playbackModel?.chapterTimeLeft ?? 0
    }

    /// Latest transient toast (bookmark-added / playback error), or `nil` when
    /// the toolkit's message is empty. The toolkit uses an empty string as its
    /// "no message" sentinel; this normalizes that to `nil`.
    var toastMessage: String? {
        let message = playbackModel?.toastMessage
        return (message?.isEmpty ?? true) ? nil : message
    }

    /// Whether a sleep timer is currently counting down (drives the active-chip
    /// display). Reads the toolkit's `SleepTimer` rather than the playback model.
    var sleepTimerIsActive: Bool {
        (manager as? DefaultAudiobookManager)?.sleepTimer.isActive ?? false
    }

    /// Seconds left on the active sleep timer (0 when inactive).
    var sleepTimerRemaining: TimeInterval {
        (manager as? DefaultAudiobookManager)?.sleepTimer.timeRemaining ?? 0
    }

    /// Whether the player is loaded. Not the same as audible: several writers
    /// set it to release the UI rather than because a byte played, which is
    /// what `transportIsWaitingForData` is for.
    var isLoaded: Bool {
        manager?.audiobook.player.isLoaded ?? false
    }

    /// Read off the same player as `isLoaded`, which on its own cannot tell a
    /// player that is playing from one that says it is playing in silence.
    var transportIsWaitingForData: Bool {
        manager?.audiobook.player.isWaitingForData ?? false
    }
}
