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
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    init(sessionManager: AudiobookSessionManaging) {
        self.sessionManager = sessionManager
        subscribeToSessionState()
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
    func clearActiveSession() {
        playbackModel = nil
        currentBook = nil
        hasActiveSession = false
        isPlayerExpanded = false
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
    func adoptPlaybackModel(_ model: AudiobookPlaybackModel) {
        self.playbackModel = model
    }

    // MARK: - Subscriptions

    /// Wires `hasActiveSession` to `playbackStatePublisher`. The manager
    /// emits on every state transition; we derive the bool from
    /// `AudiobookSessionState.isActive` (loading / playing / paused → true;
    /// idle / error → false).
    private func subscribeToSessionState() {
        sessionManager.playbackStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.hasActiveSession = state.isActive
            }
            .store(in: &cancellables)
    }
}
