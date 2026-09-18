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
    ///
    /// `isFetchingArchive` is the correction to the above. `isDownloading`
    /// cannot tell local decryption from the NETWORK FETCH of the `.lcpa`, and
    /// latching on `hasStartedPlayback` alone therefore hid the bar on the one
    /// transfer whose outcome the patron depends on: with streaming ON, audio
    /// starts within a second while a 0.7–1 GB archive is still coming down.
    /// Measured on Moes Max (build 507) — 'Dungeon Crawler Carl' sat at
    /// `download-successful` in the registry with NO archive on disk, and would
    /// not play in airplane mode. Nothing on screen had said so, because the bar
    /// disappeared the moment playback began.
    ///
    /// The rule, in the patron's terms: **if playback would fail in airplane
    /// mode because the archive is still transferring, show the bar.** An
    /// archive fetch therefore outranks `hasStartedPlayback`, while local
    /// decryption behind a playing book still does not — which keeps the
    /// 37%/62%-while-playing bar removed.
    static func shouldShowPlayerDownloadBar(
        isDownloading: Bool,
        hasStartedPlayback: Bool,
        isFetchingArchive: Bool
    ) -> Bool {
        if isFetchingArchive { return true }
        return isDownloading && !hasStartedPlayback
    }
}
