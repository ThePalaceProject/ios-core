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

    /// Opens an audiobook, invoking `onLoadingShellPresented` on the main actor
    /// the moment the loading-player shell is presented — i.e. BEFORE the
    /// PP-4542 content-download wait, not after full playback readiness. Lets a
    /// presenting caller (BookDetail half-sheet) dismiss its transient UI as soon
    /// as the morphing player is on screen, instead of leaving it stacked over
    /// the loading shell for the whole `.lcpa` download (fix/audiobook-first-open-hang).
    /// Fired at most once. A protocol-extension default forwards to the 2-arg
    /// witness above, so existing test doubles keep conforming unchanged; the
    /// production manager overrides it with the real hook.
    @discardableResult
    func openAudiobook(_ book: TPPBook, startPlaying: Bool, onLoadingShellPresented: (@MainActor () -> Void)?) async -> Result<Void, AudiobookSessionError>

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

    /// Seeks to a fractional position (0…1) of the whole audiobook. Drives the
    /// full player's scrubber. Default no-op so lightweight test doubles need not
    /// implement it; the production manager routes to the toolkit's
    /// `DefaultAudiobookManager.seekWithSlider`.
    func seek(to fraction: Double)

    /// Sets (or clears) the sleep timer. Drives the full player's sleep-timer
    /// menu. Default no-op so lightweight test doubles need not implement it; the
    /// production manager routes to the toolkit's `DefaultAudiobookManager.sleepTimer`.
    func setSleepTimer(_ trigger: SleepTimerTriggerAt)

    /// Current playback rate (read). Fixes the morphing player's hard-coded
    /// "1.0×" label for sessions restored at a persisted rate. Default
    /// `.normalTime` for lightweight test doubles.
    var currentPlaybackRate: PlaybackRate { get }

    /// Sets an explicit playback rate (drives the speed slider). Default no-op;
    /// the production manager routes to the toolkit `player.playbackRate`.
    func setPlaybackRate(_ rate: PlaybackRate)

    /// True once the toolkit player has buffered — gates the loading overlay.
    /// Default `true` so test doubles read as loaded (no spurious spinner).
    var isLoaded: Bool { get }

    /// Whether a sleep timer is currently counting down. Default `false`.
    var sleepTimerIsActive: Bool { get }

    /// Seconds left on the active sleep timer (0 when inactive). Default `0`.
    var sleepTimerRemaining: TimeInterval { get }

    /// Overall download progress (0…1) for the current audiobook's tracks.
    /// Drives the player's download bar. Default `0` for lightweight test doubles.
    var overallDownloadProgress: Float { get }

    /// Whether the current audiobook is still downloading / decrypting tracks in
    /// the background (progress < 1). Drives the download-bar visibility.
    /// Default `false`.
    var isDownloading: Bool { get }

    /// Chapter-relative playhead offset (seconds from the start of the current
    /// chapter) — the raw value behind the player's elapsed timecode. Default `0`.
    var chapterOffset: TimeInterval { get }

    /// Seconds remaining in the current chapter — the raw value behind the
    /// player's chapter time-left timecode. Default `0`.
    var chapterTimeLeft: TimeInterval { get }

    /// Latest transient toast message from the toolkit (bookmark-added or a
    /// playback error), or `nil` when there is none. Default `nil`.
    var toastMessage: String? { get }

    /// Adds a bookmark at the current playback position. `completion` receives a
    /// non-nil `Error` on failure, `nil` on success. Default reports success so
    /// lightweight test doubles need not implement it; the production manager
    /// routes to the toolkit `AudiobookPlaybackModel.addBookmark(completion:)`.
    func addBookmark(completion: @escaping (Error?) -> Void)

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

// MARK: - Default implementations

extension AudiobookSessionManaging {
    /// Default no-op so lightweight test doubles need not implement seeking.
    /// The production `AudiobookSessionManager` overrides this.
    func seek(to fraction: Double) {}

    /// Default no-op so lightweight test doubles need not implement the sleep
    /// timer. The production `AudiobookSessionManager` overrides this.
    func setSleepTimer(_ trigger: SleepTimerTriggerAt) {}

    // Defaults for the parity accessors so existing test doubles/mocks keep
    // compiling; the production `AudiobookSessionManager` overrides each.
    var currentPlaybackRate: PlaybackRate { .normalTime }
    func setPlaybackRate(_ rate: PlaybackRate) {}
    var isLoaded: Bool { true }
    var sleepTimerIsActive: Bool { false }
    var sleepTimerRemaining: TimeInterval { 0 }
    var overallDownloadProgress: Float { 0 }
    var isDownloading: Bool { false }
    var chapterOffset: TimeInterval { 0 }
    var chapterTimeLeft: TimeInterval { 0 }
    var toastMessage: String? { nil }
    func addBookmark(completion: @escaping (Error?) -> Void) { completion(nil) }

    /// Default: forwards to the 2-arg witness, ignoring the shell-presented hook.
    /// Lightweight test doubles that implement only `openAudiobook(_:startPlaying:)`
    /// keep conforming; the production `AudiobookSessionManager` overrides this
    /// with the real early-present hook. A mock that wants to exercise the hook
    /// overrides this method directly.
    @discardableResult
    func openAudiobook(_ book: TPPBook, startPlaying: Bool, onLoadingShellPresented: (@MainActor () -> Void)?) async -> Result<Void, AudiobookSessionError> {
        await openAudiobook(book, startPlaying: startPlaying)
    }
}

// MARK: - AudiobookSessionManager Conformance

extension AudiobookSessionManager: AudiobookSessionManaging {}
