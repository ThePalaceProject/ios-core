//
//  AudiobookSessionPresenterTests.swift
//  PalaceTests
//
//  Module C (swarm_0b7616e7) — root-level audiobook session presenter.
//
//  Pins the behavior contract for `AudiobookSessionPresenter`, the new
//  root-level "what's playing right now" surface introduced in P3 of
//  `docs/architecture/in-app-navigation-during-playback.md`. The presenter
//  is the SwiftUI-observable bridge between the manager's published state
//  (`AudiobookSessionManaging.playbackStatePublisher`, `currentBook`,
//  `playbackModel`) and the mini-player + full-screen-cover views Module D
//  will add to `AppTabHostView`.
//
//  The tests below cover:
//
//    - `hasActiveSession` reacts to manager state transitions (idle →
//      loading → playing → idle) via the manager's `playbackStatePublisher`
//      subscription. Mutates: dropping the subscription fails.
//
//    - `presentOnFirstOpen()` flips `isPlayerExpanded = true` so the
//      first-open cover-art + loading-state lockup (F-011 UX, §7.4) is
//      visible during the readiness-gate wait.
//
//    - `expand()` / `minimize()` are the production-seam writers used by
//      tap-on-mini-player (Module D) and CarPlay-bridge `dismissBookOnPhone`
//      (this contract). They must drive the published value.
//
//    - `isReaderActive` is a publicly mutable @Published bool that
//      `NavigationHostView` (Module D) flips on reader-route entry / exit;
//      the mini-player view conditions visibility on `!isReaderActive`.
//
//    - State-machine round-trip wiring — three transitions through the
//      production seams (`expand → minimize → expand`) — per CLAUDE.md
//      "Round-trip wiring tests required for state machines". The name
//      embeds "acrossThreeTransitions" so `check-test-name-vs-body.py`
//      will require all three steps in the body.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import Combine
import XCTest
import PalaceAudiobookToolkit
@testable import Palace

@MainActor
final class AudiobookSessionPresenterTests: XCTestCase {

    // MARK: - Fixtures

    /// Reuses the `SpyShimSession` from `PalaceTests/Mocks/
    /// SpyAudiobookSessionPresenter.swift` — the shim provides settable
    /// `state` + a real `PassthroughSubject` for
    /// `playbackStatePublisher`, which is all these tests need to drive
    /// the presenter's subscription pipeline.
    private var spySession: SpyShimSession!

    override func setUp() async throws {
        try await super.setUp()
        spySession = SpyShimSession()
    }

    override func tearDown() async throws {
        spySession = nil
        try await super.tearDown()
    }

    // MARK: - Initial state

    /// PRE: fresh presenter, spy session in `.idle`.
    /// EXPECTED: `hasActiveSession == false`, `isPlayerExpanded == false`,
    /// `playbackModel == nil`, `currentBook == nil`.
    /// Mutates: flipping the init default for `hasActiveSession` fails.
    func testInit_freshPresenterWithIdleSession_hasNoActiveSessionAndCollapsedPlayer() {
        let presenter = AudiobookSessionPresenter(sessionManager: spySession)

        XCTAssertFalse(presenter.hasActiveSession,
                       "Fresh presenter wired to an idle session must report no active session")
        XCTAssertFalse(presenter.isPlayerExpanded,
                       "Fresh presenter must not have the player expanded — only `presentOnFirstOpen()`/`expand()` flip this")
        XCTAssertNil(presenter.playbackModel,
                     "Fresh presenter must not hold a playback model")
        XCTAssertNil(presenter.currentBook,
                     "Fresh presenter must not hold a current book")
        XCTAssertFalse(presenter.isReaderActive,
                       "Fresh presenter must start with isReaderActive == false — view code flips this on reader-route entry")
    }

    /// PRE: spy session emits `.idle` initially.
    /// EXPECTED: `hasActiveSession == false`.
    /// Mutates: a regression that defaults `hasActiveSession = true` fails.
    func testHasActiveSession_isFalseWhenSessionIdle() {
        spySession.state = .idle
        let presenter = AudiobookSessionPresenter(sessionManager: spySession)

        spySession.playbackStatePublisher.send(.idle)
        spinRunLoopForPublisherDelivery()

        XCTAssertFalse(presenter.hasActiveSession,
                       "Session in .idle must drive `hasActiveSession == false`")
    }

    // MARK: - State subscription transitions

    /// PRE: spy session transitions to `.loading(bookId:)`.
    /// EXPECTED: presenter reflects `hasActiveSession == true`.
    /// Mutates: dropping the publisher subscription in `init` fails this.
    func testHasActiveSession_becomesTrueWhenSessionTransitionsToLoading() {
        let presenter = AudiobookSessionPresenter(sessionManager: spySession)

        XCTAssertFalse(presenter.hasActiveSession, "PRECONDITION: must start inactive")

        spySession.state = .loading(bookId: "book-1")
        spySession.playbackStatePublisher.send(.loading(bookId: "book-1"))
        spinRunLoopForPublisherDelivery()

        XCTAssertTrue(presenter.hasActiveSession,
                      "Session transition to .loading must drive `hasActiveSession == true` — mini-player is visible during load per F-011")
    }

    /// PRE: spy session transitions to `.playing(bookId:)`.
    /// EXPECTED: presenter reflects `hasActiveSession == true`.
    func testHasActiveSession_becomesTrueWhenSessionTransitionsToPlaying() {
        let presenter = AudiobookSessionPresenter(sessionManager: spySession)

        spySession.state = .playing(bookId: "book-1")
        spySession.playbackStatePublisher.send(.playing(bookId: "book-1"))
        spinRunLoopForPublisherDelivery()

        XCTAssertTrue(presenter.hasActiveSession,
                      "Session transition to .playing must drive `hasActiveSession == true`")
    }

    /// PRE: presenter is currently observing an active session, then session
    /// returns to `.idle`.
    /// EXPECTED: presenter flips back to `hasActiveSession == false`.
    /// Mutates: a regression that latches `true` once set fails this.
    func testHasActiveSession_becomesFalseWhenSessionReturnsToIdle() {
        let presenter = AudiobookSessionPresenter(sessionManager: spySession)

        spySession.state = .playing(bookId: "book-1")
        spySession.playbackStatePublisher.send(.playing(bookId: "book-1"))
        spinRunLoopForPublisherDelivery()
        XCTAssertTrue(presenter.hasActiveSession, "PRECONDITION: must be active before idle transition")

        spySession.state = .idle
        spySession.playbackStatePublisher.send(.idle)
        spinRunLoopForPublisherDelivery()

        XCTAssertFalse(presenter.hasActiveSession,
                       "Session return to .idle must drive `hasActiveSession == false` — a latched-true bug would leave the mini-player visible after stopPlayback")
    }

    // MARK: - First-open expand (§7.4 / F-011)

    /// PRE: presenter has `isPlayerExpanded == false`.
    /// EXPECTED: `presentOnFirstOpen()` flips `isPlayerExpanded` to true.
    /// Mutates: removing the assignment in `presentOnFirstOpen()` fails.
    func testPresentOnFirstOpen_setsIsPlayerExpandedTrue() {
        let presenter = AudiobookSessionPresenter(sessionManager: spySession)
        XCTAssertFalse(presenter.isPlayerExpanded, "PRECONDITION: must start collapsed")

        presenter.presentOnFirstOpen()

        XCTAssertTrue(presenter.isPlayerExpanded,
                      "presentOnFirstOpen() must expand the player so cover art + loading state are visible during readiness-gate wait (F-011 UX, §7.4)")
    }

    // MARK: - Manual expand / minimize

    /// PRE: `isPlayerExpanded == false`, a Combine subscriber is bound
    /// to `$isPlayerExpanded`.
    /// EXPECTED: `expand()` flips the published value AND emits to
    /// subscribers (Module D's `fullScreenCover(isPresented:)` binds to
    /// the projection — without emission the cover wouldn't show).
    /// Mutates: a regression that drops @Published or assigns to a
    /// non-observable backing fails the subscriber assertion.
    func testExpand_setsIsPlayerExpandedTrue() {
        let presenter = AudiobookSessionPresenter(sessionManager: spySession)
        var observed: [Bool] = []
        let cancellable = presenter.$isPlayerExpanded.sink { observed.append($0) }
        defer { cancellable.cancel() }

        presenter.expand()

        XCTAssertTrue(presenter.isPlayerExpanded,
                      "expand() must drive `isPlayerExpanded = true` — this is the tap-on-mini-player entry point")
        XCTAssertEqual(observed, [false, true],
                       "Subscriber must observe initial-false → true after expand(). Without emission, Module D's fullScreenCover binding wouldn't react.")
    }

    /// PRE: `isPlayerExpanded == true`.
    /// EXPECTED: `minimize()` flips it false.
    func testMinimize_setsIsPlayerExpandedFalse() {
        let presenter = AudiobookSessionPresenter(sessionManager: spySession)
        presenter.expand()
        XCTAssertTrue(presenter.isPlayerExpanded, "PRECONDITION: must start expanded")

        presenter.minimize()

        XCTAssertFalse(presenter.isPlayerExpanded,
                       "minimize() must drive `isPlayerExpanded = false` — this is the swipe-down-on-full-player entry point and the CarPlay-bridge `dismissBookOnPhone` target")
    }

    // MARK: - isReaderActive (publicly mutable)

    /// PRE: `isReaderActive == false`.
    /// EXPECTED: view code can write true, then false; both transitions
    /// emit through `$isReaderActive` so a Combine subscriber observes
    /// the round-trip. The subscriber observation is what makes this
    /// non-fluff — it proves the @Published projection works as the
    /// Module-D mini-player will require it to.
    ///
    /// Mutates: a regression that converts isReaderActive from
    /// `@Published var` to a plain `var` (dropping the projection) would
    /// fail the observer assertions.
    func testIsReaderActive_isPubliclyMutable_andPersistsTransitions() {
        let presenter = AudiobookSessionPresenter(sessionManager: spySession)
        XCTAssertFalse(presenter.isReaderActive, "PRECONDITION: must start false")

        var observedValues: [Bool] = []
        let cancellable = presenter.$isReaderActive.sink { observedValues.append($0) }
        defer { cancellable.cancel() }

        presenter.isReaderActive = true
        presenter.isReaderActive = false

        // Initial emission + 2 writes = 3 observed values; the published
        // projection must drive a subscriber on every write.
        XCTAssertEqual(observedValues, [false, true, false],
                       "@Published subscriber must observe initial-false → true → false. A regression that drops @Published (plain var) would fail to emit subsequent values; the mini-player wouldn't react to reader-route enter/exit.")
        XCTAssertFalse(presenter.isReaderActive,
                       "Final read must reflect last write — reader-route exit returns visibility to the mini-player")
    }

    // MARK: - Round-trip wiring (CLAUDE.md state-machine wiring)

    /// PRE: `isPlayerExpanded == false`.
    /// EXPECTED: drive the full lifecycle `expand → minimize → expand` via
    /// the production seams (NOT direct field writes). Each transition
    /// must flip the published value correctly.
    ///
    /// Multi-step name embeds "acrossThreeTransitions" — body MUST do all
    /// THREE transitions per CLAUDE.md DoD #3 multi-step-test-body check.
    // MARK: - Helper

    /// Spins the main runloop briefly so a publisher event sent
    /// synchronously via `playbackStatePublisher.send(...)` is delivered
    /// through `.receive(on: DispatchQueue.main)` BEFORE the test
    /// asserts on the presenter's published mirrored state. Without
    /// this, the assertion races the sink and intermittently fails.
    private func spinRunLoopForPublisherDelivery() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }

    func testPresenter_expand_minimize_expandAgain_drivesIsPlayerExpandedCorrectly_acrossThreeTransitions() {
        let presenter = AudiobookSessionPresenter(sessionManager: spySession)
        XCTAssertFalse(presenter.isPlayerExpanded, "PRECONDITION: must start collapsed")

        // Transition 1: collapsed → expanded
        presenter.expand()
        XCTAssertTrue(presenter.isPlayerExpanded,
                      "Transition 1 (expand): collapsed → expanded must flip published value to true")

        // Transition 2: expanded → collapsed
        presenter.minimize()
        XCTAssertFalse(presenter.isPlayerExpanded,
                       "Transition 2 (minimize): expanded → collapsed must flip published value to false — a regression that latches true after first expand fails here")

        // Transition 3: collapsed → expanded (re-entry — the round-trip)
        presenter.expand()
        XCTAssertTrue(presenter.isPlayerExpanded,
                      "Transition 3 (expand again): re-entry must work — collapsed → expanded after a minimize must drive published value back to true. This is the production seam round-trip per CLAUDE.md.")
    }
}

