//
//  AudiobookSessionManaging.swift
//  Palace
//
//  Created for dependency injection support.
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Combine
import Foundation
import PalaceAudiobookToolkit
import UIKit

/// Protocol for managing audiobook playback sessions, enabling dependency injection for testing.
///
/// This protocol extracts the consumer-facing interface from `AudiobookSessionManager`,
/// allowing tests to inject mock implementations instead of relying on the singleton.
@MainActor
protocol AudiobookSessionManaging: AnyObject {

    // MARK: - Published State

    /// The current state of the audiobook session.
    var state: AudiobookSessionState { get }

    /// The book currently loaded for playback, if any.
    var currentBook: TPPBook? { get }

    /// The list of chapters for the current audiobook.
    var currentChapters: [Chapter] { get }

    /// The currently playing chapter.
    var currentChapter: Chapter? { get }

    /// The current playback position.
    var currentPosition: TrackPosition? { get }

    /// Whether playback is currently active.
    var isPlaying: Bool { get }

    /// The cover image for the current audiobook.
    var coverImage: UIImage? { get }

    /// True when an `AudiobookManager` has been bound to the session — i.e.
    /// post-load, post-bind. Distinguishes from the broader `state.isActive`
    /// which is also true while loading. Used by the remote-command bridge
    /// (PlaybackBootstrapper) to decide whether the toolkit's
    /// MediaControlPublisher will handle a transport command.
    var hasActiveManager: Bool { get }

    // MARK: - Publishers

    /// Emits when playback state changes (for CarPlay UI updates, etc.).
    var playbackStatePublisher: PassthroughSubject<AudiobookSessionState, Never> { get }

    /// Emits when the chapter list or current chapter changes.
    var chapterUpdatePublisher: PassthroughSubject<(chapters: [Chapter], current: Chapter?), Never> { get }

    /// Emits errors for UI display.
    var errorPublisher: PassthroughSubject<AudiobookSessionError, Never> { get }

    // MARK: - Playback Control

    /// Opens and starts playing an audiobook.
    @discardableResult
    func openAudiobook(_ book: TPPBook, startPlaying: Bool) async -> Result<Void, AudiobookSessionError>

    /// Plays the current audiobook.
    func play()

    /// Pauses the current audiobook.
    func pause()

    /// Toggles play/pause.
    func togglePlayPause()

    /// Skips to a specific chapter by index.
    func skipToChapter(at index: Int)

    /// Skips the playhead backward by the toolkit's default skip interval
    /// (30s). Wraps `Player.skipPlayhead(_:)` (async) on the underlying
    /// `AudiobookManager.audiobook.player` via a `Task { @MainActor in ... }`
    /// boundary — same async→sync pattern used by `skipToChapter(at:)` at
    /// `AudiobookSessionManager.swift:524-528`. Routed through this protocol
    /// (not via `playbackModel.audiobookManager` directly) because
    /// `AudiobookPlaybackModel.audiobookManager` is internal-default access
    /// in the toolkit and unreachable from Palace consumers.
    ///
    /// swarm polish phase (in-app-nav-polish-2026-06-01) — added so the
    /// mini-player chrome can drive 30s rewind from the root-level
    /// presenter surface without leaking the toolkit type.
    func skipBack()

    /// Skips the playhead forward by the toolkit's default skip interval
    /// (30s). See `skipBack()` for the toolkit-routing rationale.
    func skipForward()

    /// Cycles through available playback rates and returns the new rate.
    func cyclePlaybackRate() -> PlaybackRate

    /// Stops playback and clears the current session.
    func stopPlayback(dismissPhoneUI: Bool, persistFinalPosition: Bool) async

    /// Updates the cover image for Now Playing display.
    func updateCoverImage(_ image: UIImage?)

    /// Re-primes playback after the app returns to foreground from a
    /// long background pause. iOS can evict the AVPlayer buffer while
    /// suspended, leaving the toolkit's `Player.isLoaded == false` on
    /// re-entry — `AudiobookPlayerView` then shows `LoadingView` and
    /// (after 30s) `LoadingErrorView`.
    ///
    /// This method re-activates the audio session and re-issues the play
    /// call if `isPlaying` was true at background time, restarting the
    /// buffer fetch. Idempotent: safe to call when already playing or
    /// paused. No-op when there's no active session.
    ///
    /// Polish-phase addition (in-app-nav-polish-2026-06-01) for the
    /// "playback freezes when backgrounded" user-reported regression.
    func recoverPlaybackForForegroundEntry()
}

// MARK: - AudiobookSessionManager Conformance

extension AudiobookSessionManager: AudiobookSessionManaging {}
