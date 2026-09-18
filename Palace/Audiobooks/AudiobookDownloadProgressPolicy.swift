//
//  AudiobookDownloadProgressPolicy.swift
//  Palace
//
//  When the player may draw a determinate download bar. Pure statics over
//  explicit inputs — the shape `AudiobookPositionPolicy` and
//  `AudiobookSessionManager+ContentOpenPolicy` already established for audiobook
//  decisions that want enumerating rather than scenario-testing.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import Foundation

enum AudiobookDownloadProgressPolicy {

    /// Whether the player should draw its determinate download bar.
    ///
    /// A progress bar is a promise that something is being waited ON. For an LCP
    /// audiobook the toolkit's "download" is LOCAL DECRYPTION of tracks out of
    /// the already-present `.lcpa` into caches (`LCPDownloadTask`), and
    /// `LCPStreamingPlayer` does not wait for it — playback runs from the
    /// license. So once audio has started the bar sits beside working transport
    /// controls and describes background plumbing the patron is not blocked on.
    /// Device recording, build 505: the bar read 37% then 62% AFTER the archive
    /// had been stored, while the book was playing.
    ///
    /// Latched on `hasStartedPlayback` rather than the live `isPlaying`. Using
    /// `isPlaying` would re-summon the bar on every pause — the patron pauses,
    /// a download bar appears on a book they have been listening to for twenty
    /// minutes, and it reads as though pausing broke something.
    ///
    /// Before playback begins the bar is RIGHT and is kept: that is the window
    /// where the patron is genuinely waiting and a silent screen is what the
    /// original toolkit bar existed to prevent.
    static func shouldShowPlayerDownloadBar(
        isDownloading: Bool,
        hasStartedPlayback: Bool
    ) -> Bool {
        isDownloading && !hasStartedPlayback
    }
}
