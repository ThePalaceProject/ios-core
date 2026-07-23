//
//  AudiobookSessionPresenter.swift
//  Palace
//
//  Root-level "what's playing right now" presenter. Bridges the manager's
//  published state to the SwiftUI mini-player + full-screen-cover surfaces
//  Module D wires into `AppTabHostView`.
//
//  Introduced in P3 of `docs/architecture/in-app-navigation-during-playback.md`
//  (swarm_0b7616e7 Module C). Replaces the per-tab `NavigationCoordinator
//  .pushAudioRoute(...)` push — the audio route is no longer pushed onto
//  any per-tab nav stack; instead, the presenter drives a root-level
//  fullScreenCover and a persistent mini-player above the tab bar.
//
//  Polish-phase additions (in-app-nav-polish-2026-06-01):
//    - `isPlaying`, `coverImage`, `currentLocation`, `playbackProgress`
//      published mirrors so the mini-player chrome (now full controls +
//      scrubber) reads its entire state off the presenter rather than
//      closure-injected providers.
//    - `isPlaying` is derived from the same `playbackStatePublisher` sink
//      that drives `hasActiveSession`.
//    - `currentLocation` mirrors `playbackModel.$currentLocation` (the only
//      `@Published public` field on `AudiobookPlaybackModel` — toolkit's
//      `coverImage` / `playbackProgress` are internal-default).
//    - `playbackProgress` is derived from `currentLocation` via a Combine
//      `.map` against `position.durationToSelf() / tracks.totalDuration`.
//    - `coverImage` snapshots from `sessionManager.coverImage` at
//      `adoptPlaybackModel` time, and is updated for async hi-res arrivals
//      via the new `adoptCoverImage(_:)` method (called from
//      `AudiobookSessionManager.updateCoverImage(_:)`).
//    - `adoptPlaybackModel(_:)` clears a separate `playbackModelCancellables`
//      set BEFORE installing new subscriptions so the audiobook-switch
//      path (PP-3783) doesn't leak the prior `$currentLocation` sink —
//      pinned by `testPresenter_adoptsNewPlaybackModel_clearsPriorCurrentLocationSubscription`.
//
//  Design intent:
//    - The presenter OBSERVES (does not call) the session manager. The
//      published mirror of session state lets SwiftUI views bind to a
//      single object without each one subscribing to manager publishers.
//    - `presentOnFirstOpen()` is the F-011-preserving auto-expand: when
//      `AudiobookSessionManager.openAudiobook(_, startPlaying: true)` is
//      called fresh (not resume-from-mini-player), the cover-art +
//      loading-state lockup must be visible during the readiness-gate
//      wait. The manager calls `presentOnFirstOpen()` SYNCHRONOUSLY inside
//      `presentCoverArtAndNavigation` BEFORE the readiness-gate Task runs.
//    - `expand()` / `minimize()` are the post-first-open entry points
//      (mini-player tap → expand; swipe-down or CarPlay disconnect →
//      minimize). They write directly without going through
//      `presentOnFirstOpen()` semantics.
//    - `isReaderActive` is publicly mutable so `NavigationHostView`'s
//      reader-route entry / exit can flip it (per §7.3 Option α — the
//      mini-player conditions visibility on `!isReaderActive`).
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import Combine
import Foundation
import PalaceAudiobookToolkit
import SwiftUI
import UIKit
import PalaceBookModel

/// Not `final` — see CLAUDE.md "Don't make new services `final` reflexively"
/// memory pin. Spy test doubles in
/// `AudiobookSessionManagerPresenterMigrationTests` subclass this to
/// record call counts without needing a separate protocol layer.
///
/// Class access is internal (default) — Palace and PalaceTests (via
/// `@testable import Palace`) are the only consumers. The test-target
/// spy (`PalaceTests/Mocks/SpyAudiobookSessionPresenter.swift`)
/// subclasses through the `@testable` window, which exposes internal
/// access — `open` is not required for that path.
///
/// CLAUDE.md "Don't make new services `final` reflexively" — default to
/// `class`.
@MainActor
class AudiobookSessionPresenter: ObservableObject {

    // MARK: - Published state

    /// True when there is an active audiobook session (loading, playing, or
    /// paused — anything where the mini-player should be visible). Derived
    /// from `AudiobookSessionState.isActive` via the manager's
    /// `playbackStatePublisher` subscription.
    @Published private(set) var hasActiveSession: Bool = false

    /// True when the current session is actively playing (not loading or
    /// paused). Drives the mini-player + full player play/pause glyph and
    /// accessibility label. Derived from the same `playbackStatePublisher`
    /// sink that drives `hasActiveSession` so a single publisher event
    /// updates both fields atomically.
    ///
    /// Read directly by the audiobook player view — replaced the
    /// closure-injected `isPlayingProvider` an earlier player view took.
    @Published private(set) var isPlaying: Bool = false

    /// Cover image for the current session, mirrored from the session
    /// manager's `coverImage` accessor. Initial value is snapshotted in
    /// `adoptPlaybackModel(_:)`; async hi-res arrivals come via
    /// `adoptCoverImage(_:)` (called from
    /// `AudiobookSessionManager.updateCoverImage(_:)`).
    ///
    /// Read directly by the audiobook player view — replaced the
    /// closure-injected `coverImageProvider` an earlier player view took.
    @Published private(set) var coverImage: UIImage?

    /// High-frequency playback position/progress lives on a SEPARATE
    /// observable so per-tick updates re-render only the scrubber leaves
    /// (mini/full player) — not every `@ObservedObject` of the presenter.
    /// Observing these on the presenter re-rendered the root `AppTabHostView`
    /// (all tabs) on every tick and froze the UI.
    let progress = AudiobookPlaybackProgress()

    /// Overall download progress (0…1) for the current audiobook, mirrored from
    /// the toolkit playback model's `$overallDownloadProgress`. Drives the
    /// custom player's download bar. Reset to 0 on `clearActiveSession()`.
    @Published private(set) var overallDownloadProgress: Float = 0

    /// Whether the current audiobook is still downloading / decrypting tracks,
    /// mirrored from the toolkit playback model's `$isDownloading`. Gates the
    /// download-bar visibility. Reset to false on `clearActiveSession()`.
    @Published private(set) var isDownloading: Bool = false

    /// Latest transient toast (bookmark-added / playback error), mirrored from
    /// the toolkit playback model's `$toastMessage` (empty string normalized to
    /// `nil`). Reset to nil on `clearActiveSession()`.
    @Published private(set) var toastMessage: String?

    /// The playback model for the active session, mirrored from the session
    /// manager. The mini-player + full-player views observe this for chrome
    /// updates (title, cover, play/pause). Cleared on stopPlayback by the
    /// session manager calling `clearActiveSession()`.
    @Published private(set) var playbackModel: AudiobookPlaybackModel?

    /// The currently bound book; mirrors `AudiobookSessionManaging.currentBook`.
    /// Cleared on stopPlayback by the session manager calling
    /// `clearActiveSession()`.
    @Published private(set) var currentBook: TPPBook?

    /// Drives the root-level full-player fullScreenCover. View code binds
    /// to this and shows / hides the cover accordingly.
    /// Public-settable so the cover's `isPresented` binding can flip it
    /// back to false on swipe-down (SwiftUI two-way binding).
    @Published var isPlayerExpanded: Bool = false

    /// View-driven flag: NavigationHostView's `.epub` / `.pdf` /
    /// `presentedEPUBSample` route cases flip this on entry / off on exit.
    /// The mini-player view conditions its visibility on `!isReaderActive`
    /// (per §7.3 Option α). Public-settable so reader-route view modifiers
    /// can drive it directly.
    @Published var isReaderActive: Bool = false

    /// Legacy mini-bar ⇄ pill collapse axis. The floating pill view was
    /// removed once the morphing player became the sole audiobook surface,
    /// so `collapse()` is now a no-op and this stays false; the property is
    /// retained only for the presenter's existing reset paths (`expand()`,
    /// `minimize()`, `presentOnFirstOpen()`, `clearActiveSession()`).
    /// Distinct from `isPlayerExpanded` (the full-player axis).
    @Published var isCollapsed: Bool = false

    // MARK: - Private state

    private let sessionManager: AudiobookSessionManaging

    /// Long-lived subscriptions — bound to the manager's publishers at
    /// init time and never replaced.
    private var cancellables = Set<AnyCancellable>()

    /// Playback-model-scoped subscriptions. Cleared in
    /// `adoptPlaybackModel(_:)` BEFORE installing new ones so the audiobook-
    /// switch path (PP-3783) doesn't leak the prior `$currentLocation` sink.
    /// Separating this from `cancellables` is what makes the "re-subscribe
    /// cleanly" round-trip test work — re-using `cancellables` would either
    /// leak both subscriptions (silently mirroring the wrong model) or
    /// cancel the long-lived `playbackStatePublisher` sink alongside the
    /// short-lived `$currentLocation` sink.
    private var playbackModelCancellables = Set<AnyCancellable>()

    // MARK: - Init

    init(sessionManager: AudiobookSessionManaging) {
        self.sessionManager = sessionManager
        subscribeToSessionState()
        subscribeToAppLifecycle()
    }

    // MARK: - Public API (open for spying)

    /// Called by `AudiobookSessionManager.presentCoverArtAndNavigation` on
    /// a fresh open so the cover art + loading state are visible during
    /// the readiness-gate wait. Must run SYNCHRONOUSLY before the readiness
    /// Task — see F-011 preservation contract in
    /// `.forgeos/swarms/swarm_0b7616e7/contracts/C-AudiobookSessionPresenter-and-Migration.md`.
    func presentOnFirstOpen() {
        isPlayerExpanded = true
        // A fresh open always shows the full chrome — never the leftover
        // pill from a previously-collapsed session.
        isCollapsed = false
    }

    /// Presents the player shell IMMEDIATELY on a fresh open — BEFORE the loader
    /// chain (manifest fetch / DRM / factory) runs — so the morphing player
    /// slides up the instant the patron taps Continue / Listen, showing the
    /// book's cover + a loading skeleton, instead of dead time until load
    /// completes. Adopts the book identity (so the root mount gate and title/
    /// author chrome have a source) + a low-res cover, then expands.
    ///
    /// Idempotent with the bind-time `presentOnFirstOpen()` (both set
    /// `isPlayerExpanded = true`); the loader's later `adoptPlaybackModel(_:)`
    /// fills in playback state and the skeleton clears once `isLoaded`. A failed
    /// load publishes `.error`, which `clearActiveSession()` tears down (see
    /// `subscribeToSessionState`), so the shell never lingers without a book.
    ///
    /// `coverImage` is always written (even `nil`) so a coverless book shows the
    /// placeholder rather than a stale cover from a prior session — though the
    /// manager's pre-open `stopPlayback` has already cleared it.
    func presentLoadingShell(for book: TPPBook, coverImage: UIImage?) {
        adoptBook(book)
        adoptCoverImage(coverImage)
        presentOnFirstOpen()
    }

    /// Feeds *pre-bind* download progress into the loading shell during the
    /// PP-4542 content-local wait — the window after `presentLoadingShell` but
    /// before `adoptPlaybackModel`, when there is no toolkit playback model yet
    /// to mirror `$overallDownloadProgress` from. Without this the shell shows a
    /// static skeleton for the whole `.lcpa` download and reads as "hung" (see
    /// fix/audiobook-first-open-hang). `fraction` is the download-center's
    /// `downloadProgress(for:)` (0…1). Sets `isDownloading = true` so the bar is
    /// visible. Superseded the moment `adoptPlaybackModel` re-snapshots both
    /// mirrors at bind (`:333-334`), so this is strictly a pre-bind placeholder.
    func showDownloadProgress(_ fraction: Float) {
        overallDownloadProgress = max(0, min(1, fraction))
        isDownloading = true
    }

    /// Tap-on-mini-player entry point. Sets `isPlayerExpanded = true` so
    /// the root fullScreenCover shows the full player.
    func expand() {
        isPlayerExpanded = true
        // Expanding to the full player supersedes the collapsed pill state.
        isCollapsed = false
    }

    /// Swipe-down-on-full-player or CarPlay-disconnect entry point. Sets
    /// `isPlayerExpanded = false` so the root fullScreenCover collapses
    /// back to the mini-player. The session itself stays active — this is
    /// strictly a UI dismiss.
    func minimize() {
        isPlayerExpanded = false
        // Returning from the full player always lands on the full mini-bar,
        // not the pill — so a prior collapse doesn't survive an expand cycle.
        isCollapsed = false
    }

    /// Full close from the ✕ on the full player — ends the session and dismisses
    /// BOTH the full player and the mini-bar (unlike `minimize()`, which only
    /// hides the full player and keeps the mini-bar). Playback stops and the
    /// final position is persisted so the patron can resume later from My Books.
    func closePlayer() {
        Task { await sessionManager.stopPlayback(dismissPhoneUI: true, persistFinalPosition: true) }
    }

    /// No-op in the resize-overlay morph: the floating pill is GONE — the mini
    /// bar is already the smallest chrome state, so there is nothing further to
    /// collapse into. Left as a no-op (rather than deleted) so the mini bar's
    /// existing swipe-down gesture routes here harmlessly instead of hiding the
    /// bar into an empty card. Down-on-mini does nothing; expand is via up/tap,
    /// dismiss is via the ✕.
    func collapse() {
        // intentionally empty — no pill in the morph
    }

    /// Tap-on-pill entry point. Restores the full mini-bar from the compact
    /// pill. Playback is unaffected. Idempotent.
    func restoreFromCollapsed() {
        isCollapsed = false
    }

    /// Called by the session manager's `dismissPlayerOnPhone` path
    /// (post-migration replacement for `coordinator.removeAudioModel` +
    /// `coordinator.popToRoot`). Clears every mirrored field — the
    /// mini-player drops below the tab bar and the full player (if any)
    /// dismisses.
    ///
    /// Distinct from `minimize()`: `minimize()` only hides the full player;
    /// `clearActiveSession()` tears down everything (no mini-player either).
    /// Both run during stopPlayback (clear first, then collapse).
    ///
    /// Polish-phase: also clears the new `coverImage` / `currentLocation` /
    /// `playbackProgress` mirrors AND drops the `playbackModelCancellables`
    /// set so the next `adoptPlaybackModel(_:)` starts from a clean slate.
    func clearActiveSession() {
        playbackModel = nil
        currentBook = nil
        hasActiveSession = false
        isPlayerExpanded = false
        isCollapsed = false
        isPlaying = false
        coverImage = nil
        progress.currentLocation = nil
        progress.playbackProgress = 0
        progress.chapterOffset = 0
        progress.chapterTimeLeft = 0
        progress.chapterProgress = 0
        overallDownloadProgress = 0
        isDownloading = false
        toastMessage = nil
        playbackModelCancellables.removeAll()
    }

    /// Adopts the book identity for the current session. Called by the
    /// session manager during `bind(loaded:for:startPlaying:)` so SwiftUI
    /// consumers can read `currentBook` for chrome (title, author).
    ///
    /// Split from `adoptPlaybackModel(_:)` so the migration tests can
    /// drive the presenter-call branch without constructing a full
    /// `AudiobookPlaybackModel` — toolkit Audiobook/Manifest construction
    /// from XCTest requires real audio files. The split keeps the test
    /// surface minimal while preserving the production-side semantic
    /// (both are called in immediate succession from
    /// `pushSessionToPresenter`).
    func adoptBook(_ book: TPPBook) {
        self.currentBook = book
    }

    /// Adopts the toolkit playback model for the current session. Called
    /// by the session manager during `bind(loaded:for:startPlaying:)` so
    /// the mini-player + full player can read playback state (play/pause,
    /// position, chapter) and chrome (cover art) from a single source.
    ///
    /// Split from `adoptBook(_:)` — see `adoptBook` documentation.
    ///
    /// Polish-phase semantics: ALWAYS clears `playbackModelCancellables`
    /// before installing new subscriptions so the audiobook-switch path
    /// (PP-3783) re-subscribes cleanly. Without this, the second
    /// audiobook's positions never propagate because the prior model's
    /// `$currentLocation` sink stays alive and overwrites the new one.
    func adoptPlaybackModel(_ model: AudiobookPlaybackModel) {
        // Drop prior playback-model subscriptions BEFORE writing the new
        // model so a `$playbackModel` subscriber won't briefly see the old
        // model + new subscription set (race window during switch).
        playbackModelCancellables.removeAll()
        self.playbackModel = model

        // Snapshot initial cover from the manager so the mini-player gets
        // an image immediately on bind. Async hi-res replacements come via
        // `adoptCoverImage(_:)` (forwarded from
        // `AudiobookSessionManager.updateCoverImage(_:)`).
        self.coverImage = sessionManager.coverImage

        // Snapshot the download/toast mirrors at bind time so the custom
        // player's download bar reflects any progress already made before the
        // first publisher tick; the subscriptions below keep them live.
        self.overallDownloadProgress = model.overallDownloadProgress
        self.isDownloading = model.isDownloading
        self.toastMessage = model.toastMessage.isEmpty ? nil : model.toastMessage

        subscribeToPlaybackModelCurrentLocation(model)
        subscribeToPlaybackModelDownloadAndToast(model)
    }

    /// Updates the presenter's mirrored cover image. Called from
    /// `AudiobookSessionManager.updateCoverImage(_:)` for both the lo-res
    /// snapshot at bind time AND the async hi-res replacement that arrives
    /// after `loadCoverArt(for:into:)`'s Task completes. Polish-phase
    /// addition — the toolkit's `AudiobookPlaybackModel.coverImage` is
    /// internal-default and unreachable via Combine, so this forwarding
    /// path is the only way Palace consumers can see hi-res cover updates.
    func adoptCoverImage(_ image: UIImage?) {
        self.coverImage = image
    }

    // MARK: - Subscriptions

    /// Wires `hasActiveSession` AND `isPlaying` to `playbackStatePublisher`.
    /// The manager emits on every state transition; we derive both bools
    /// from the same sink so a single publisher event updates both fields
    /// atomically (no observer can see them out of sync).
    ///
    /// - `hasActiveSession` is true for loading / playing / paused
    ///   (`AudiobookSessionState.isActive`) — mini-player visibility.
    /// - `isPlaying` is true ONLY for the `.playing(_)` case — drives the
    ///   play/pause glyph. Loading / paused render the pause glyph (so
    ///   tapping resumes), playing renders pause, idle / error don't show
    ///   the mini-player at all.
    private func subscribeToSessionState() {
        // `hasActiveSession` + the terminal-`.error` teardown stay on the
        // deferred main hop (unchanged behavior — these can be driven by
        // manager sinks and the teardown mutates many `@Published` fields).
        sessionManager.playbackStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self = self else { return }
                self.hasActiveSession = state.isActive
                // A failed open leaves the session in a terminal `.error`
                // state. Tear down the view-facing session so neither the
                // mini-player nor the full-player overlay lingers with no
                // book actually loaded — otherwise the chrome sits in its
                // last-published `.loading` look (the phantom-playback bug).
                if case .error = state {
                    self.clearActiveSession()
                }
            }
            .store(in: &cancellables)

        // `isPlaying` is driven SYNCHRONOUSLY (no `receive(on:)` async hop) so
        // the transport play/pause glyph flips on the SAME main-runloop tick the
        // manager publishes the state — eliminating the one-frame lag a user
        // saw between tapping play/pause and the glyph updating.
        //
        // Safe without the hop because `AudiobookSessionManager` is `@MainActor`:
        // every `playbackStatePublisher.send(...)` already runs on the main
        // thread (whether from a user-initiated `play()`/`pause()` or from a
        // toolkit-driven `.playbackBegan`/`.playbackStopped` in
        // `handleManagerState`), so this mirror stays main-isolated. A change-
        // guard means we only republish when the bool actually flips, so we
        // don't re-render the root `AppTabHostView` on same-value events.
        sessionManager.playbackStatePublisher
            .sink { [weak self] state in
                guard let self = self else { return }
                let playing: Bool
                if case .playing = state { playing = true } else { playing = false }
                if self.isPlaying != playing { self.isPlaying = playing }
            }
            .store(in: &cancellables)
    }

    /// Subscribes to `model.$currentLocation` and mirrors into
    /// `progress.currentLocation`; derives `progress.playbackProgress`
    /// against the track's total duration.
    ///
    /// Stored in `playbackModelCancellables` (NOT `cancellables`) so
    /// `adoptPlaybackModel(_:)` can cancel them cleanly before
    /// re-subscribing for the next model — the PP-3783 audiobook-switch
    /// case. See `playbackModelCancellables` doc-comment for why two
    /// separate cancellable sets exist.
    /// Re-snap UI mirrors from the session manager on app foreground.
    ///
    /// Why: while the app is backgrounded, the toolkit's
    /// `playbackStatePublisher` may have emitted (e.g. lock-screen
    /// play/pause from `MPNowPlayingInfoCenter`) and our sink updated the
    /// `@Published` mirrors. But if a publisher fired AT the foreground
    /// boundary it can be missed by SwiftUI's diffing — especially the
    /// `coverImage` update from an async cover-art Task that completed
    /// during background. Re-snapping `isPlaying` + `coverImage` from the
    /// session manager on `willEnterForegroundNotification` guarantees
    /// the chrome reflects truth the moment the user sees it.
    ///
    /// User-reported symptom this fixes: "playback stops for audiobooks
    /// when backgrounded" — actually the audio kept playing, but the play
    /// glyph stayed stuck on play and the cover stayed blank, making the
    /// user believe playback had stopped.
    private func subscribeToAppLifecycle() {
        NotificationCenter.default
            .publisher(for: UIApplication.willEnterForegroundNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.isPlaying = self.sessionManager.isPlaying
                self.coverImage = self.sessionManager.coverImage

                // Polish-phase background-freeze fix: when the app backgrounds
                // mid-playback, iOS can evict the AVPlayer buffer and the
                // toolkit's `Player.isLoaded` flips to false. On re-entry,
                // `AudiobookPlayerView` shows its `LoadingView`; if the player
                // doesn't reload within 30s it transitions to `LoadingErrorView`
                // — which the user perceives as "re-opening gets stuck in a
                // loading state and then errors."
                //
                // Recovery: if we still have an active session AND the
                // manager believes playback is in flight, ask the manager
                // to re-prime — re-activates the audio session and re-issues
                // play, restarting buffering. Idempotent if already playing.
                if self.hasActiveSession {
                    self.sessionManager.recoverPlaybackForForegroundEntry()
                }
            }
            .store(in: &cancellables)
    }

    private func subscribeToPlaybackModelCurrentLocation(_ model: AudiobookPlaybackModel) {
        model.$currentLocation
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak model] position in
                guard let self = self else { return }
                self.progress.currentLocation = position
                self.progress.playbackProgress = Self.normalizedProgress(for: position)
                // Self-heal the transport play/pause glyph on each advancing tick.
                self.reconcileTransportGlyphFromSessionManager()
                // The chapter-relative offsets are computed off `currentLocation`
                // in the toolkit, so recompute the mirrors on the same tick.
                if let model = model {
                    self.progress.chapterOffset = model.chapterPlayheadOffset
                    self.progress.chapterTimeLeft = model.chapterTimeLeft
                    // CHAPTER-relative scrubber progress. The toolkit slider is
                    // chapter-scoped: seekWithSlider seeks chapterStart + value *
                    // chapterDuration. `playbackProgress` above is BOOK-relative
                    // (for the "N min remaining" text), so the scrubber reads this
                    // separate chapter value or thumb-position and seek-scale
                    // disagree (the "seek won't settle" bug).
                    self.progress.chapterProgress = Self.chapterProgress(
                        offset: model.chapterPlayheadOffset,
                        timeLeft: model.chapterTimeLeft
                    )
                }
            }
            .store(in: &playbackModelCancellables)
    }

    /// Self-heal the transport play/pause glyph from the authoritative
    /// `sessionManager.isPlaying`. The discrete `playbackStatePublisher` sink
    /// (`subscribeToSessionState`) is the primary `isPlaying` driver, but the
    /// toolkit can advance the playhead without re-emitting `.playing`
    /// (chapter/track rollover, buffer resume after a seek), leaving the glyph
    /// stuck on "play" while audio is audible. Called from the advancing
    /// `$currentLocation` tick — which only fires while the player is genuinely
    /// advancing — so re-snapping here corrects a stale glyph within one frame.
    /// Change-guarded → no extra root renders, and no flapping when paused (the
    /// location simply stops ticking, so this stops being called).
    func reconcileTransportGlyphFromSessionManager() {
        if isPlaying != sessionManager.isPlaying {
            isPlaying = sessionManager.isPlaying
        }
    }

    /// Mirrors the toolkit playback model's `$overallDownloadProgress`,
    /// `$isDownloading`, and `$toastMessage` into the presenter's published
    /// fields so the custom player's download bar + toast read off a single
    /// object. Stored in `playbackModelCancellables` (NOT `cancellables`) so
    /// `adoptPlaybackModel(_:)` re-subscribes cleanly on an audiobook switch —
    /// same lifetime rules as the `$currentLocation` sink above.
    private func subscribeToPlaybackModelDownloadAndToast(_ model: AudiobookPlaybackModel) {
        model.$overallDownloadProgress
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.overallDownloadProgress = value }
            .store(in: &playbackModelCancellables)

        model.$isDownloading
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.isDownloading = value }
            .store(in: &playbackModelCancellables)

        model.$toastMessage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.toastMessage = value.isEmpty ? nil : value }
            .store(in: &playbackModelCancellables)
    }

    /// Pure helper — computes 0.0...1.0 progress for a position against
    /// its track's total duration. Returns 0 for nil position or
    /// non-positive duration (avoids /0). Extracted `static` so the
    /// arithmetic is unit-testable without spinning up a real
    /// `AudiobookPlaybackModel`.
    ///
    /// Mutates: a regression that drops the `> 0` duration guard would
    /// return NaN/Inf for empty audiobooks; the polish-phase tests pin
    /// the boundary explicitly via `normalizedProgressFromRawValues`.
    static func normalizedProgress(for position: TrackPosition?) -> Double {
        guard let position = position else { return 0 }
        return normalizedProgressFromRawValues(
            elapsed: position.durationToSelf(),
            totalDuration: position.tracks.totalDuration
        )
    }

    /// Pure-arithmetic mirror of `normalizedProgress(for:)` that takes
    /// primitive `TimeInterval` inputs — exists so unit tests can pin
    /// the `> 0` guard + clamp boundary mutations without spinning up
    /// a real `TrackPosition` (which requires toolkit Audiobook/Manifest
    /// fixtures). The two functions share the same arithmetic; the
    /// optional-handling shell is `normalizedProgress(for:)` above.
    ///
    /// Mutates:
    ///   - `> 0` → `>= 0`: with totalDuration == 0, original returns 0
    ///     (safe), mutant returns NaN (0/0). Test pins this.
    ///   - `> 0` → `< 0`: with totalDuration == 1, original returns
    ///     elapsed/1, mutant returns 0 (because 1 < 0 is false → enters
    ///     guard → returns 0). Test pins this.
    static func normalizedProgressFromRawValues(elapsed: TimeInterval, totalDuration: TimeInterval) -> Double {
        guard totalDuration > 0 else { return 0 }
        let progress = elapsed / totalDuration
        // Clamp to [0, 1] so toolkit edge cases (saved position past EOF,
        // pre-load 0.0) don't drive the scrubber out of bounds.
        return min(max(progress, 0), 1)
    }

    /// CHAPTER-relative scrubber progress (0…1 within the current chapter),
    /// mirroring the toolkit's `AudiobookPlaybackModel.playbackProgress`
    /// (`chapterOffset / chapterDuration`, `chapterDuration = offset + timeLeft`).
    /// Pure + static so the `> 0` guard and [0,1] clamp are unit-testable
    /// without a live `AudiobookPlaybackModel`.
    static func chapterProgress(offset: TimeInterval, timeLeft: TimeInterval) -> Double {
        let duration = offset + timeLeft
        guard duration > 0 else { return 0 }
        return min(max(offset / duration, 0), 1)
    }
}

/// High-frequency playback position/progress, deliberately split out of
/// `AudiobookSessionPresenter`. Only the scrubber leaves observe it, so
/// per-tick updates never re-render the presenter's root observer
/// (`AppTabHostView`). Do not fold these back onto the presenter.
final class AudiobookPlaybackProgress: ObservableObject {
    @Published var currentLocation: TrackPosition?
    @Published var playbackProgress: Double = 0

    /// Chapter-relative playhead offset (seconds into the current chapter) and
    /// chapter time-left. Live on the high-frequency progress object (not the
    /// presenter) so per-tick updates re-render only the scrubber/time leaves,
    /// never the root `AppTabHostView`. Mirrored from the toolkit playback
    /// model's `chapterPlayheadOffset` / `chapterTimeLeft` on each position tick.
    @Published var chapterOffset: TimeInterval = 0
    @Published var chapterTimeLeft: TimeInterval = 0

    /// CHAPTER-relative scrubber progress (0…1 within the current chapter),
    /// mirrors the toolkit's `AudiobookPlaybackModel.playbackProgress`
    /// (`chapterOffset / chapterDuration`). This — NOT book-relative
    /// `playbackProgress` — is what the seek slider binds to so its thumb
    /// matches `seekWithSlider`'s chapter-scoped seek.
    @Published var chapterProgress: Double = 0
}
