//
//  AudiobookSessionManager+ForegroundRecovery.swift
//
//  The foreground-return recovery, split out of the session-manager hub: the
//  hub sits on a frozen size ceiling, and this is a self-contained concern.

import Foundation

extension AudiobookSessionManager {

    /// Background-freeze recovery. Called from
    /// `AudiobookSessionPresenter.subscribeToAppLifecycle` on
    /// `UIApplication.willEnterForegroundNotification` when there's an
    /// active session.
    ///
    /// Strategy:
    ///   1. Re-activate the audio session via PlaybackBootstrapper so a
    ///      transient background-time deactivation doesn't leave AVPlayer
    ///      starved.
    ///   2. If the manager believes playback was in flight (state was
    ///      `.playing` when we backgrounded), call `play()` to nudge the
    ///      toolkit's player out of any stalled buffer-empty state. This
    ///      is the operative recovery: AVPlayer re-fetches its buffer and
    ///      `Player.isLoaded` re-flips to true, dismissing the toolkit's
    ///      LoadingView before the 30s `LoadingErrorView` timer fires.
    // PUBLIC_INTENT: moved unchanged from AudiobookSessionManager.swift, where it was already `public`.
    public func recoverPlaybackForForegroundEntry() {
        guard let _ = manager else { return }
        // Re-prime the audio session; `ensureInitialized` is idempotent.
        playbackBootstrapperProvider().ensureInitialized()
        if case .playing = state {
            // Was playing pre-background; ask the toolkit to resume.
            // `manager.play()` is idempotent.
            play()
        }
    }
}
