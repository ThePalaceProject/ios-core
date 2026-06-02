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
    /// Polish-phase addition — replaces the closure-injected
    /// `isPlayingProvider` parameter on `AudiobookMiniPlayerView`.
    @Published private(set) var isPlaying: Bool = false

    /// Cover image for the current session, mirrored from the session
    /// manager's `coverImage` accessor. Initial value is snapshotted in
    /// `adoptPlaybackModel(_:)`; async hi-res arrivals come via
    /// `adoptCoverImage(_:)` (called from
    /// `AudiobookSessionManager.updateCoverImage(_:)`).
    ///
    /// Polish-phase addition — replaces the closure-injected
    /// `coverImageProvider` parameter on `AudiobookMiniPlayerView`.
    @Published private(set) var coverImage: UIImage?

    /// High-frequency playback position/progress lives on a SEPARATE
    /// observable so per-tick updates re-render only the scrubber leaves
    /// (mini/full player) — not every `@ObservedObject` of the presenter.
    /// Observing these on the presenter re-rendered the root `AppTabHostView`
    /// (all tabs) on every tick and froze the UI.
    let progress = AudiobookPlaybackProgress()

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
    }

    /// Tap-on-mini-player entry point. Sets `isPlayerExpanded = true` so
    /// the root fullScreenCover shows the full player.
    func expand() {
        isPlayerExpanded = true
    }

    /// Swipe-down-on-full-player or CarPlay-disconnect entry point. Sets
    /// `isPlayerExpanded = false` so the root fullScreenCover collapses
    /// back to the mini-player. The session itself stays active — this is
    /// strictly a UI dismiss.
    func minimize() {
        isPlayerExpanded = false
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
        isPlaying = false
        coverImage = nil
        progress.currentLocation = nil
        progress.playbackProgress = 0
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

        subscribeToPlaybackModelCurrentLocation(model)
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
        sessionManager.playbackStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self = self else { return }
                self.hasActiveSession = state.isActive
                if case .playing = state {
                    self.isPlaying = true
                } else {
                    self.isPlaying = false
                }
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
            .sink { [weak self] position in
                guard let self = self else { return }
                self.progress.currentLocation = position
                self.progress.playbackProgress = Self.normalizedProgress(for: position)
            }
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
}

/// High-frequency playback position/progress, deliberately split out of
/// `AudiobookSessionPresenter`. Only the scrubber leaves observe it, so
/// per-tick updates never re-render the presenter's root observer
/// (`AppTabHostView`). Do not fold these back onto the presenter.
final class AudiobookPlaybackProgress: ObservableObject {
    @Published var currentLocation: TrackPosition?
    @Published var playbackProgress: Double = 0
}
