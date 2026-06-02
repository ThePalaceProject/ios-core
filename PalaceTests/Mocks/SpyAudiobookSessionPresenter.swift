//
//  SpyAudiobookSessionPresenter.swift
//  PalaceTests
//
//  Module C (swarm_0b7616e7) — spy override of `AudiobookSessionPresenter`
//  used by `AudiobookSessionManagerPresenterMigrationTests` and any other
//  test that needs to assert on the migrated presenter-side calls
//  (`presentOnFirstOpen()`, `expand()`, `minimize()`, `adoptBook(_:)`,
//  `adoptPlaybackModel(_:)`, `clearActiveSession()`).
//
//  The spy subclasses `AudiobookSessionPresenter` (not `final` — see the
//  CLAUDE.md "Don't make new services final reflexively" memory pin) and
//  overrides each action method to record call counts + a FIFO log of
//  adopted book identifiers. Each override invokes `super` so the
//  published mirror fields (`isPlayerExpanded`, `currentBook`) still get
//  written — tests can assert on both call counts AND final published
//  state.
//
//  Construction uses the production designated init with a `SpyAudiobook
//  Session` shim (defined locally because the presenter requires an
//  `AudiobookSessionManaging` to wire its publisher subscription). The
//  shim returns a no-op publisher; tests that need to drive state
//  transitions through the subscription path use the spy session from
//  `AudiobookSessionPresenterTests.swift` instead.
//
//  Module D's tests 12-13 reuse this spy via the
//  `AppContainer.withAudiobookSessionPresenter(spy)` test seam added to
//  AppContainer in this same contract.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import Combine
import Foundation
import UIKit
import PalaceAudiobookToolkit
@testable import Palace

/// Spy subclass of `AudiobookSessionPresenter` — records calls to each
/// action method, then forwards to `super` so published state mirrors
/// still flip.
@MainActor
final class SpyAudiobookSessionPresenter: AudiobookSessionPresenter {

    // MARK: - Call counters

    private(set) var presentOnFirstOpenCallCount: Int = 0
    private(set) var expandCallCount: Int = 0
    private(set) var minimizeCallCount: Int = 0
    private(set) var adoptBookCallCount: Int = 0
    private(set) var adoptPlaybackModelCallCount: Int = 0
    private(set) var clearActiveSessionCallCount: Int = 0
    /// Polish-phase: counts adoptCoverImage invocations (forwarded from
    /// `AudiobookSessionManager.updateCoverImage(_:)` for async hi-res
    /// arrivals). The most recently forwarded image is stored for assertion.
    private(set) var adoptCoverImageCallCount: Int = 0
    private(set) var lastAdoptedCoverImage: UIImage?

    /// FIFO log of adopted book identifiers — used by Test 6
    /// (`switchingAudiobooks_clearsPreviousPlaybackModel`) to prove the
    /// presenter saw A then B in order.
    private(set) var adoptedBookIdentifiersInOrder: [String] = []

    /// Strong reference to the spy session shim so test helpers can fire
    /// its publishers without going through Mirror reflection.
    private let shimSession: SpyShimSession

    // MARK: - Init

    /// Constructs with an internal shim that satisfies the manager-shape
    /// requirement without spinning up a real session.
    init() {
        let shim = SpyShimSession()
        self.shimSession = shim
        super.init(sessionManager: shim)
    }

    // MARK: - Overrides

    override func presentOnFirstOpen() {
        presentOnFirstOpenCallCount += 1
        super.presentOnFirstOpen()
    }

    override func expand() {
        expandCallCount += 1
        super.expand()
    }

    override func minimize() {
        minimizeCallCount += 1
        super.minimize()
    }

    override func adoptBook(_ book: TPPBook) {
        adoptBookCallCount += 1
        adoptedBookIdentifiersInOrder.append(book.identifier)
        super.adoptBook(book)
    }

    override func adoptPlaybackModel(_ model: AudiobookPlaybackModel) {
        adoptPlaybackModelCallCount += 1
        super.adoptPlaybackModel(model)
    }

    override func clearActiveSession() {
        clearActiveSessionCallCount += 1
        super.clearActiveSession()
    }

    override func adoptCoverImage(_ image: UIImage?) {
        adoptCoverImageCallCount += 1
        lastAdoptedCoverImage = image
        super.adoptCoverImage(image)
    }

    // MARK: - Test-only helpers

    /// Directly drives `hasActiveSession` for setup convenience — the
    /// production setter is a Combine subscription on the manager, so a
    /// test that wants `hasActiveSession == true` without firing a real
    /// publisher uses this helper. Internally pushes a publisher event
    /// through the shim, then awaits the next runloop tick so the
    /// `.receive(on: DispatchQueue.main)` delivery enqueued by `send()`
    /// has a chance to drain before the caller asserts.
    ///
    /// `async` (with `await Task.yield()`) drains the main queue cleanly
    /// without runloop spinning — the latter can deadlock when the test
    /// itself is running on the main actor.
    func markHasActiveSessionForTesting(_ value: Bool) async {
        let state: AudiobookSessionState = value ? .playing(bookId: "test-active") : .idle
        shimSession.playbackStatePublisher.send(state)
        // Drain the main queue: yield once so .receive(on: DispatchQueue.main)
        // delivery runs; loop a few times for CI headroom.
        for _ in 0..<10 {
            await Task.yield()
            if hasActiveSession == value { return }
            // Brief sleep so the dispatch source has a chance to fire.
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }
    }
}

// MARK: - SpyShimSession

/// Minimal `AudiobookSessionManaging` shim that satisfies the
/// presenter's `init(sessionManager:)` without spinning up the real
/// session-manager graph. Publishers are real (so tests that drive them
/// flow through), state is settable, and method stubs are no-ops.
@MainActor
final class SpyShimSession: AudiobookSessionManaging {

    var state: AudiobookSessionState = .idle
    var currentBook: TPPBook?
    var currentChapters: [Chapter] = []
    var currentChapter: Chapter?
    var currentPosition: TrackPosition?
    var isPlaying: Bool = false
    var coverImage: UIImage?
    var hasActiveManager: Bool = false

    let playbackStatePublisher = PassthroughSubject<AudiobookSessionState, Never>()
    let chapterUpdatePublisher = PassthroughSubject<(chapters: [Chapter], current: Chapter?), Never>()
    let errorPublisher = PassthroughSubject<AudiobookSessionError, Never>()

    /// Polish-phase counters — let polish-phase tests assert that the
    /// mini-player chrome's skip buttons routed through this shim once
    /// each (presenter wires the buttons to `audiobookSession.skipBack()`
    /// / `audiobookSession.skipForward()` via AppContainer).
    private(set) var skipBackCallCount: Int = 0
    private(set) var skipForwardCallCount: Int = 0

    @discardableResult
    func openAudiobook(_ book: TPPBook, startPlaying: Bool) async -> Result<Void, AudiobookSessionError> {
        .failure(.unknown("spy shim"))
    }
    func play() {}
    func pause() {}
    func togglePlayPause() {}
    func skipToChapter(at index: Int) {}
    func skipBack() { skipBackCallCount += 1 }
    func skipForward() { skipForwardCallCount += 1 }
    func cyclePlaybackRate() -> PlaybackRate { .normalTime }
    func stopPlayback(dismissPhoneUI: Bool, persistFinalPosition: Bool) async {}
    func updateCoverImage(_ image: UIImage?) {}
    func recoverPlaybackForForegroundEntry() {}
}

