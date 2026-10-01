//
//  AudiobookSessionPresenter.swift
//  Palace
//
//  Root-level "what's playing right now" presenter. Mirrors the session
//  manager's published state for the SwiftUI mini-player and full-screen
//  player in `AppTabHostView`; it observes the manager and does not call it.
//  See `docs/architecture/in-app-navigation-during-playback.md`.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import Combine
import Foundation
import PalaceAudiobookToolkit
import SwiftUI
import UIKit
import PalaceBookModel

/// Not `final`: `SpyAudiobookSessionPresenter` in the test target subclasses
/// it to record calls.
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
    @Published private(set) var isPlaying: Bool = false

    /// Cover image for the current session, mirrored from the session
    /// manager's `coverImage` accessor. Initial value is snapshotted in
    /// `adoptPlaybackModel(_:)`; async hi-res arrivals come via
    /// `adoptCoverImage(_:)` (called from
    /// `AudiobookSessionManager.updateCoverImage(_:)`).
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

    /// Whether audio has begun at least once for THIS session. Latched — it
    /// never returns to false while the session lives — and reset only by
    /// `clearActiveSession()`.
    ///
    /// The download bar gates on this rather than `isPlaying`, which drops on
    /// every pause. See `AudiobookDownloadProgressPolicy`.
    @Published private(set) var hasStartedPlayback: Bool = false

    /// Progress (0…1) of the `.lcpa` ARCHIVE fetch for the current book, or
    /// `nil` when no archive fetch is running.
    ///
    /// One optional rather than a flag plus a number, so a visible bar always
    /// has a value. `overallDownloadProgress` cannot serve: it comes from the
    /// toolkit, which knows nothing about this network fetch.
    ///
    /// Distinct from `isDownloading`, which the toolkit also raises for local
    /// track decryption out of an archive already on disk. Sourced from the
    /// download centre signals the half-sheet already consumes, so both
    /// surfaces agree on what "still downloading" means. Reset by
    /// `clearActiveSession()`.
    @Published private(set) var archiveProgress: Double?

    /// Whether the `.lcpa` archive is still coming down. Derived, never stored
    /// separately — see `archiveProgress`.
    var isFetchingArchive: Bool { archiveProgress != nil }

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

    /// Legacy mini-bar ⇄ pill collapse axis. The pill view no longer exists,
    /// so `collapse()` is a no-op and this stays false; it remains for the
    /// existing reset paths.
    @Published var isCollapsed: Bool = false

    // MARK: - Private state

    private let sessionManager: AudiobookSessionManaging

    /// Long-lived subscriptions — bound to the manager's publishers at
    /// init time and never replaced.
    private var cancellables = Set<AnyCancellable>()

    /// Playback-model-scoped subscriptions. Cleared in
    /// `adoptPlaybackModel(_:)` BEFORE installing new ones so the audiobook-
    /// switch path (PP-3783) doesn't leak the prior `$currentLocation` sink.
    /// Kept separate so clearing it does not cancel the long-lived
    /// `playbackStatePublisher` sink.
    private var playbackModelCancellables = Set<AnyCancellable>()

    // MARK: - Init

    /// - Parameters:
    ///   - archiveTransferPublisher: emits `(bookIdentifier, isActive)` as the
    ///     `.lcpa` network fetch starts and stops. When nil the player never
    ///     learns about archive fetches.
    ///   - isArchiveTransferActive: seed for a presenter created mid-transfer,
    ///     which is common (archive downloads run for minutes); without it the
    ///     bar stays hidden until the next publisher edge.
    init(
        sessionManager: AudiobookSessionManaging,
        archiveTransferPublisher: AnyPublisher<(String, Bool), Never>? = nil,
        archiveProgressPublisher: AnyPublisher<(String, Double), Never>? = nil,
        isArchiveTransferActive: @escaping (String) -> Bool = { _ in false }
    ) {
        self.sessionManager = sessionManager
        self.archiveTransferPublisher = archiveTransferPublisher
        self.archiveProgressPublisher = archiveProgressPublisher
        self.isArchiveTransferActive = isArchiveTransferActive
        subscribeToSessionState()
        subscribeToAppLifecycle()
        subscribeToArchiveTransfers()
    }

    private let archiveTransferPublisher: AnyPublisher<(String, Bool), Never>?
    private let archiveProgressPublisher: AnyPublisher<(String, Double), Never>?
    private let isArchiveTransferActive: (String) -> Bool

    /// Mirrors the archive fetch for whichever book is currently bound.
    /// Filtered on `currentBook` at DELIVERY time rather than captured at
    /// subscribe time: the presenter outlives individual sessions, so a
    /// subscription pinned to one identifier would report a stale book's
    /// transfer onto the next one.
    private func subscribeToArchiveTransfers() {
        archiveTransferPublisher?
            .receive(on: RunLoop.main)
            .sink { [weak self] update in
                guard let self, update.0 == self.currentBook?.identifier else { return }
                // Rising edge keeps any progress already seen; falling edge is
                // the ONLY thing that clears the bar.
                if update.1 {
                    self.archiveProgress = self.archiveProgress ?? 0
                } else {
                    // A falling edge can be stale — enqueued before a seed that
                    // found the transfer live. The synchronous query is
                    // authoritative, so let it veto the clear.
                    let stillActive = self.isArchiveTransferActive(update.0)
                    self.archiveProgress = stillActive ? (self.archiveProgress ?? 0) : nil
                }
            }
            .store(in: &cancellables)

        archiveProgressPublisher?
            .receive(on: RunLoop.main)
            .sink { [weak self] update in
                guard let self, update.0 == self.currentBook?.identifier else { return }
                // Progress alone must NOT summon the bar: the same publisher
                // carries ordinary (non-LCP) download progress, and raising the
                // archive bar on it would put the player bar back on transfers
                // this policy exists to keep quiet. Only an active transfer,
                // or the seed, opens that door.
                guard self.archiveProgress != nil else { return }
                self.archiveProgress = max(0, min(1, update.1))
            }
            .store(in: &cancellables)
    }

    /// Seeds `isFetchingArchive` for a book bound mid-transfer. Called when a
    /// session binds, because the publisher only speaks on edges.
    private func seedArchiveTransferState(for identifier: String) {
        // `?? 0` not `= 0`: `adoptBook` seeds TWICE per open, and a bar that
        // already climbed during the pre-bind wait must not snap back to 0%.
        // Mirrors the rising edge, which preserves for the same reason.
        archiveProgress = isArchiveTransferActive(identifier) ? (archiveProgress ?? 0) : nil
    }

    // MARK: - Public API (open for spying)

    /// Called by `AudiobookSessionManager.presentCoverArtAndNavigation` on
    /// a fresh open so the cover art + loading state are visible during
    /// the readiness-gate wait. Must run synchronously before the readiness
    /// Task (PP-4436).
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
        // Clear the playback latch unconditionally at the start of an open,
        // mirroring the manager's reset of `hasEverStartedPlayback`. A same-book
        // re-open skips `clearActiveSession()`, so resetting on identifier change
        // in `adoptBook` would miss it and hide the content-wait bar.
        hasStartedPlayback = false
        adoptBook(book)
        adoptCoverImage(coverImage)
        presentOnFirstOpen()
    }

    /// Feeds *pre-bind* download progress into the loading shell during the
    /// PP-4542 content-local wait — the window after `presentLoadingShell` but
    /// before `adoptPlaybackModel`, when there is no toolkit playback model yet
    /// to mirror `$overallDownloadProgress` from. Without this the shell shows a
    /// static skeleton for the whole `.lcpa` download and reads as hung.
    /// `fraction` is the download center's `downloadProgress(for:)` (0…1).
    /// Superseded once `adoptPlaybackModel` re-snapshots both mirrors at bind.
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

    /// No-op: the mini bar is already the smallest chrome state. Kept so the
    /// mini bar's swipe-down gesture routes here harmlessly.
    func collapse() {
        // intentionally empty — no pill in the morph
    }

    /// Tap-on-pill entry point. Restores the full mini-bar from the compact
    /// pill. Playback is unaffected. Idempotent.
    func restoreFromCollapsed() {
        isCollapsed = false
    }

    /// Called by the session manager's `dismissPlayerOnPhone` path. Clears
    /// every mirrored field — the mini-player drops below the tab bar and the
    /// full player (if any) dismisses.
    ///
    /// Distinct from `minimize()`: `minimize()` only hides the full player;
    /// `clearActiveSession()` tears down everything (no mini-player either).
    /// Both run during stopPlayback (clear first, then collapse). Also drops
    /// `playbackModelCancellables` so the next `adoptPlaybackModel(_:)` starts
    /// clean.
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
        // PP-5205: reset with the offsets so a new book never shows the
        // previous book's chapter name.
        progress.chapterTitle = ""
        overallDownloadProgress = 0
        isDownloading = false
        archiveProgress = nil
        hasStartedPlayback = false
        toastMessage = nil
        playbackModelCancellables.removeAll()
    }

    /// Adopts the book identity for the current session. Called by the
    /// session manager during `bind(loaded:for:startPlaying:)` so SwiftUI
    /// consumers can read `currentBook` for chrome (title, author).
    ///
    /// Split from `adoptPlaybackModel(_:)` so tests can drive it without an
    /// `AudiobookPlaybackModel`, which needs real audio files to build.
    func adoptBook(_ book: TPPBook) {
        self.currentBook = book
        seedArchiveTransferState(for: book.identifier)
    }

    /// Adopts the toolkit playback model for the current session. Called
    /// by the session manager during `bind(loaded:for:startPlaying:)` so
    /// the mini-player + full player can read playback state (play/pause,
    /// position, chapter) and chrome (cover art) from a single source.
    ///
    /// Always clears `playbackModelCancellables` first so an audiobook switch
    /// (PP-3783) does not leave the prior model's `$currentLocation` sink alive.
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
    /// after `loadCoverArt(for:into:)`'s Task completes. Needed because the
    /// toolkit's `AudiobookPlaybackModel.coverImage` is not observable here.
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
        // `hasActiveSession` and the `.error` teardown stay on the deferred
        // main hop; the teardown mutates many `@Published` fields.
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

        // `isPlaying` is updated synchronously so the play/pause glyph flips on
        // the same tick; safe because the `@MainActor` manager always sends on
        // main. Change-guarded to avoid re-rendering `AppTabHostView`.
        sessionManager.playbackStatePublisher
            .sink { [weak self] state in
                guard let self = self else { return }
                let playing: Bool
                if case .playing = state { playing = true } else { playing = false }
                if self.isPlaying != playing { self.isPlaying = playing }
                // Latch on the rising edge only; never cleared here, so a pause
                // or a track boundary cannot take it back down.
                if playing && !self.hasStartedPlayback { self.hasStartedPlayback = true }
            }
            .store(in: &cancellables)
    }

    /// Re-snaps `isPlaying` and `coverImage` from the session manager on
    /// `willEnterForegroundNotification`: an update fired at the foreground
    /// boundary can be missed by SwiftUI, leaving a stale glyph or blank cover
    /// while audio is playing.
    private func subscribeToAppLifecycle() {
        NotificationCenter.default
            .publisher(for: UIApplication.willEnterForegroundNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.isPlaying = self.sessionManager.isPlaying
                self.coverImage = self.sessionManager.coverImage

                // iOS can evict the AVPlayer buffer in the background, leaving
                // `Player.isLoaded` false and the player stuck loading. Ask the
                // manager to re-prime (idempotent if already playing).
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
                    // Same tick as the offsets, by construction — see `chapterTitle`.
                    self.progress.chapterTitle = model.currentChapterTitle
                    // Chapter-relative scrubber progress, matching the
                    // chapter-scoped `seekWithSlider`; `playbackProgress` is
                    // book-relative and only drives the "N min remaining" text.
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

    /// Computes 0.0...1.0 progress for a position against its track's total
    /// duration. Returns 0 for nil position or non-positive duration.
    static func normalizedProgress(for position: TrackPosition?) -> Double {
        guard let position = position else { return 0 }
        return normalizedProgressFromRawValues(
            elapsed: position.durationToSelf(),
            totalDuration: position.tracks.totalDuration
        )
    }

    /// The arithmetic behind `normalizedProgress(for:)` over primitive inputs,
    /// testable without a toolkit `TrackPosition`.
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

    /// The chapter name, mirrored on the same tick as the offsets above so the
    /// name and timecodes cannot disagree after a chapter selection (PP-5205).
    @Published var chapterTitle: String = ""

    /// CHAPTER-relative scrubber progress (0…1 within the current chapter),
    /// mirrors the toolkit's `AudiobookPlaybackModel.playbackProgress`
    /// (`chapterOffset / chapterDuration`). This — NOT book-relative
    /// `playbackProgress` — is what the seek slider binds to so its thumb
    /// matches `seekWithSlider`'s chapter-scoped seek.
    @Published var chapterProgress: Double = 0
}
