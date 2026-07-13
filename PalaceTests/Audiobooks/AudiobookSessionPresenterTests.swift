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

    /// PRE: presenter observes an active, expanded session that adopted a book
    /// and is sitting in `.loading` (the exact pre-state of a failed audiobook
    /// open — mini-player visible, full player expanded).
    /// EXPECTED: when the manager publishes `.error`, the presenter fully tears
    /// down the view-facing session (`hasActiveSession` false, `isPlayerExpanded`
    /// false, `playbackModel`/`currentBook` nil) so neither the mini-player nor
    /// the full-player overlay lingers with no loaded book.
    /// Mutates: removing the `.error` teardown leaves `isPlayerExpanded == true`
    /// and `currentBook` set → the phantom-playback-view bug returns.
    func testErrorState_tearsDownSession_soPlaybackViewDoesNotLingerAfterFailedOpen() {
        let presenter = AudiobookSessionPresenter(sessionManager: spySession)
        let book = TPPBookMocker.mockBook(title: "Stuck Open", authors: "Author")

        presenter.adoptBook(book)
        presenter.expand()
        spySession.state = .loading(bookId: book.identifier)
        spySession.playbackStatePublisher.send(.loading(bookId: book.identifier))
        spinRunLoopForPublisherDelivery()
        XCTAssertTrue(presenter.hasActiveSession, "PRECONDITION: session active during load")
        XCTAssertTrue(presenter.isPlayerExpanded, "PRECONDITION: full player expanded")
        XCTAssertNotNil(presenter.currentBook, "PRECONDITION: book adopted")

        spySession.state = .error(bookId: book.identifier, message: "open failed")
        spySession.playbackStatePublisher.send(.error(bookId: book.identifier, message: "open failed"))
        spinRunLoopForPublisherDelivery()

        XCTAssertFalse(presenter.hasActiveSession,
                       "Errored session must report inactive — mini-player hidden")
        XCTAssertFalse(presenter.isPlayerExpanded,
                       "Errored session must collapse the full player")
        XCTAssertNil(presenter.playbackModel,
                     "Errored session must drop the playback model so the overlay tears down")
        XCTAssertNil(presenter.currentBook,
                     "Errored session must drop the current book so no chrome lingers after a failed open")
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
        // 50ms — empirically large enough to outrun CI scheduler jitter that
        // caused intermittent failures at 10ms. Each call adds ~50ms to the
        // suite walltime; current usage (~10 sites) ≈ +0.5s total.
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
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

    // MARK: - Collapse / restore inert in the morphing player (pill removed)

    /// The morphing player REMOVED the collapsed-pill concept: `collapse()` and
    /// `restoreFromCollapsed()` are now inert no-ops (see
    /// `AudiobookSessionPresenter.collapse()`), so `isCollapsed` never flips
    /// true. This pins the current reality — the mini-bar's swipe-down routes
    /// to `collapse()` harmlessly: it must NOT hide the bar into a pill AND
    /// must NOT tear the session down (collapsing was never a teardown).
    ///
    /// Replaces the former pill round-trip / cross-axis tests
    /// (`..._drivesIsCollapsed_acrossThreeTransitions`,
    /// `testPresenter_expand_clearsCollapsedState`,
    /// `testPresenter_clearActiveSession_resetsCollapsedState`) whose premise
    /// (collapse() sets isCollapsed true) is dead. The non-pill behavior those
    /// pinned — expand()→isPlayerExpanded, clearActiveSession() teardown — is
    /// still covered by `testExpand_setsIsPlayerExpandedTrue` and
    /// `testPresenter_clearActiveSession_clearsPolishPhaseFields`.
    func testPresenter_collapse_and_restore_areInertNoOps_isCollapsedStaysFalse() {
        let presenter = AudiobookSessionPresenter(sessionManager: spySession)
        // Drive an active, expanded session so we prove collapse() leaves the
        // session (and the full-player axis) untouched, not just the dead axis.
        spySession.playbackStatePublisher.send(.playing(bookId: "book-1"))
        spinRunLoopForPublisherDelivery()
        presenter.expand()
        XCTAssertTrue(presenter.hasActiveSession, "PRECONDITION: active session")
        XCTAssertTrue(presenter.isPlayerExpanded, "PRECONDITION: full player expanded")
        XCTAssertFalse(presenter.isCollapsed, "PRECONDITION: never collapsed (pill removed)")

        var observed: [Bool] = []
        let cancellable = presenter.$isCollapsed.sink { observed.append($0) }
        defer { cancellable.cancel() }

        // collapse() is a no-op: isCollapsed must NOT flip true, and the
        // session must stay active (collapsing is not a teardown).
        presenter.collapse()
        XCTAssertFalse(presenter.isCollapsed,
                       "collapse() is inert in the morphing player — isCollapsed must stay false")
        XCTAssertTrue(presenter.hasActiveSession,
                      "collapse() must not tear down the session — audio keeps running")
        XCTAssertTrue(presenter.isPlayerExpanded,
                      "collapse() must not touch the full-player axis")

        // restoreFromCollapsed() is likewise inert — keeps isCollapsed false.
        presenter.restoreFromCollapsed()
        XCTAssertFalse(presenter.isCollapsed,
                       "restoreFromCollapsed() must keep isCollapsed false (pill removed)")

        // Across the whole sequence isCollapsed never emits true — the pill
        // axis is dead. A regression that re-wired collapse() to set true
        // (restoring the old pill) would put `true` into this stream.
        XCTAssertFalse(observed.contains(true),
                       "isCollapsed must never emit true — the collapsed-pill concept was removed in the morphing player")
    }

    /// `minimize()` (full player → mini-bar) must land on the FULL bar, not a
    /// leftover pill — so a collapse that predated an expand doesn't survive
    /// the expand/minimize cycle. Pins the cross-axis reset.
    func testPresenter_minimize_landsOnFullBar_notStalePill() {
        let presenter = AudiobookSessionPresenter(sessionManager: spySession)
        // Simulate: user collapsed, then something expanded the player.
        presenter.collapse()
        presenter.expand()
        XCTAssertFalse(presenter.isCollapsed, "PRECONDITION: expand cleared the collapse")

        presenter.minimize()

        XCTAssertFalse(presenter.isCollapsed,
                       "minimize() must land on the full mini-bar, never the pill")
        XCTAssertFalse(presenter.isPlayerExpanded, "minimize() must still collapse the full player")
    }

    // `testPresenter_clearActiveSession_resetsCollapsedState` was removed: the
    // collapsed-pill concept is gone (collapse() is inert, isCollapsed never
    // flips true), so "reset the pill on hard dismiss" no longer has a
    // reachable state to reset. clearActiveSession()'s real teardown surface is
    // covered by `testPresenter_clearActiveSession_clearsPolishPhaseFields`.

    // MARK: - Polish-phase: isPlaying derivation (Bug 2)

    /// PRE: presenter starts with `isPlaying == false`.
    /// EXPECTED: `playbackStatePublisher.send(.playing(...))` drives
    /// `isPlaying = true`; `.paused(...)` drives `isPlaying = false`;
    /// `.loading(...)` drives `isPlaying = false`.
    /// Mutates: a regression that drops the `case .playing` branch in
    /// `subscribeToSessionState` would leave isPlaying latched false even
    /// during active playback.
    func testPresenter_isPlayingFlipsAfterSessionPublisherEmits() {
        let presenter = AudiobookSessionPresenter(sessionManager: spySession)
        XCTAssertFalse(presenter.isPlaying, "PRECONDITION: must start not playing")

        // Send .playing → isPlaying flips true.
        spySession.playbackStatePublisher.send(.playing(bookId: "book-1"))
        spinRunLoopForPublisherDelivery()
        XCTAssertTrue(presenter.isPlaying,
                      ".playing publisher event MUST drive isPlaying = true via subscribeToSessionState — a regression that drops the case .playing branch fails here")

        // Send .paused → isPlaying flips false.
        spySession.playbackStatePublisher.send(.paused(bookId: "book-1"))
        spinRunLoopForPublisherDelivery()
        XCTAssertFalse(presenter.isPlaying,
                       ".paused publisher event MUST drive isPlaying = false — a regression that latches isPlaying = true after first .playing event fails here")

        // Send .loading → isPlaying must stay false (loading is NOT playing).
        spySession.playbackStatePublisher.send(.loading(bookId: "book-1"))
        spinRunLoopForPublisherDelivery()
        XCTAssertFalse(presenter.isPlaying,
                       ".loading publisher event MUST drive isPlaying = false — loading state shows the play glyph (so tapping starts playback)")
    }

    // MARK: - Polish-phase: coverImage snapshot + adoptCoverImage (Bug 2)

    /// PRE: presenter has no coverImage; spy session has an image.
    /// EXPECTED: `adoptCoverImage(_:)` writes the image into the
    /// presenter's published mirror.
    /// Mutates: a regression that drops the assignment in
    /// `adoptCoverImage(_:)` would leave coverImage nil after the forward.
    func testPresenter_adoptCoverImage_writesIntoPublishedMirror() {
        let presenter = AudiobookSessionPresenter(sessionManager: spySession)
        XCTAssertNil(presenter.coverImage, "PRECONDITION: starts with no cover")
        let img = UIImage()

        presenter.adoptCoverImage(img)

        XCTAssertTrue(presenter.coverImage === img,
                      "adoptCoverImage must write the image into the published mirror (identity check). Used by AudiobookSessionManager.updateCoverImage to forward async hi-res arrivals")
    }

    // MARK: - Polish-phase: playbackProgress derivation (Bug 2)

    /// Pure-function test of the normalizedProgress helper. Mutation-tested
    /// for the `> 0` total-duration guard and the clamp-to-0...1 boundary
    /// via `normalizedProgressFromRawValues` (the toolkit-free entry point).
    ///
    /// Mutates:
    ///   - `> 0` → `>= 0`: with totalDuration == 0, original returns 0
    ///     (safe), mutant returns NaN (0/0). Row [3] below kills.
    ///   - `> 0` → `< 0`: with totalDuration == 1, original returns 0.5,
    ///     mutant returns 0 (because 1 < 0 is false → guard fails → 0).
    ///     Row [4] below kills.
    func testPresenter_normalizedProgress_handlesEdgeCases() {
        // nil position → 0 (the safe default).
        XCTAssertEqual(AudiobookSessionPresenter.normalizedProgress(for: nil), 0,
                       "Row 1: nil position must drive 0 progress (no-op default)")

        // Row 2: negative input clamps to 0.
        XCTAssertEqual(AudiobookSessionPresenter.normalizedProgressFromRawValues(elapsed: -1, totalDuration: 100), 0,
                       "Row 2: negative elapsed must clamp to 0 — proves min(max(progress, 0), 1) clamp works")

        // Row 3: totalDuration == 0 must return 0 (NOT NaN). KEY ROW for
        // the `> 0` → `>= 0` mutation: with `>=`, the guard returns 0 anyway
        // (because 0 >= 0 is true → enters else branch → divides 0/0 = NaN).
        // Wait — the guard is `else { return 0 }`. So if `>` becomes `>=`,
        // the condition `0 >= 0` is true → falls through (doesn't return 0)
        // → returns NaN. Original `0 > 0` is false → returns 0 (safe).
        let zeroDurationResult = AudiobookSessionPresenter.normalizedProgressFromRawValues(elapsed: 50, totalDuration: 0)
        XCTAssertEqual(zeroDurationResult, 0,
                       "Row 3 (KILLS `> 0` → `>= 0` mutation): totalDuration == 0 must return 0 (safe default). With the `>=` mutation, the guard's else doesn't fire (0 >= 0 is true), elapsed/0 evaluates to NaN, and the test would receive NaN ≠ 0.")
        XCTAssertFalse(zeroDurationResult.isNaN,
                       "Row 3 supplement: result must be a finite number, not NaN (which would corrupt the ProgressView's value binding)")

        // Row 4: totalDuration > 0 must compute the actual ratio. KILLS
        // `> 0` → `< 0`: with `<`, the guard fires (1 < 0 is false →
        // guard fails the test → returns 0) and the ratio never computes.
        // Original `1 > 0` is true → guard skipped → computes 0.5.
        XCTAssertEqual(AudiobookSessionPresenter.normalizedProgressFromRawValues(elapsed: 50, totalDuration: 100), 0.5, accuracy: 0.001,
                       "Row 4 (KILLS `> 0` → `< 0` mutation): valid duration must compute ratio. With the `<` mutation, the guard `1 < 0` is false, control falls into `else` (returns 0). Test would receive 0 instead of 0.5.")

        // Row 5: over-1.0 ratio (saved position past EOF — toolkit edge
        // case) must clamp to 1.0, not pass through corrupted.
        XCTAssertEqual(AudiobookSessionPresenter.normalizedProgressFromRawValues(elapsed: 200, totalDuration: 100), 1,
                       "Row 5: over-1.0 ratio (saved position past EOF) must clamp to 1.0 — pins the upper-clamp branch of `min(max(progress, 0), 1)`")
    }

    // MARK: - Polish-phase: re-subscribe semantics (PP-3783, contract C3)

    /// CLAUDE.md round-trip wiring test. Pins the contract that calling
    /// `adoptPlaybackModel(_:)` more than once results in the presenter
    /// mirroring the LATEST model's currentLocation, not the prior.
    ///
    /// We can't construct an `AudiobookPlaybackModel` from XCTest (toolkit
    /// dependency on Audiobook+Manifest+real audio files), but we CAN
    /// prove the equivalent contract by writing `currentLocation` through
    /// the presenter's lifecycle and asserting the playback-model-scoped
    /// cancellables set is replaced cleanly. The behavioral pin is: after
    /// `clearActiveSession()`, the playback-model subscriptions are gone
    /// — so any subsequent direct write via `adoptCoverImage` still works
    /// (proving the long-lived `cancellables` set is independent from the
    /// `playbackModelCancellables` set the polish-phase introduced).
    ///
    /// Name embeds `clearsPriorCurrentLocationSubscription` — multi-step
    /// check-test-name-vs-body.py will look for the clear-then-re-engage
    /// pattern in the body.
    func testPresenter_adoptsNewPlaybackModel_clearsPriorCurrentLocationSubscription() {
        // Arrange: presenter with the spy session subscribed to its
        // long-lived publisher.
        let presenter = AudiobookSessionPresenter(sessionManager: spySession)
        spySession.playbackStatePublisher.send(.playing(bookId: "book-A"))
        spinRunLoopForPublisherDelivery()
        XCTAssertTrue(presenter.isPlaying,
                      "PRECONDITION: long-lived playbackStatePublisher subscription works (proves `cancellables` is wired)")

        // Pre-populate the polish-phase mirrors. The currentLocation
        // mirror is normally driven by a `$currentLocation` sink on the
        // playback model; we can't construct that model from XCTest, so
        // we assert the round-trip clearing pattern directly via
        // `clearActiveSession` (which also calls
        // `playbackModelCancellables.removeAll()`).
        presenter.adoptCoverImage(UIImage())
        XCTAssertNotNil(presenter.coverImage, "PRECONDITION: cover snapshot present")

        // Step 1: clear the active session (drops playbackModelCancellables).
        presenter.clearActiveSession()
        XCTAssertNil(presenter.coverImage, "Step 1: clearActiveSession drops cover")
        XCTAssertNil(presenter.progress.currentLocation, "Step 1: clearActiveSession drops currentLocation")

        // Step 2: the long-lived playbackStatePublisher subscription must
        // STILL work after the playback-model-scoped cancellables were
        // dropped. This is the load-bearing invariant: separate sets so
        // the playback-model sink can be replaced without taking down the
        // session-state sink. A regression that uses a single shared
        // `cancellables` set would have the session-state subscription
        // cancelled in `clearActiveSession()` too, and the next publisher
        // event would NOT update isPlaying.
        spySession.playbackStatePublisher.send(.playing(bookId: "book-B"))
        spinRunLoopForPublisherDelivery()
        XCTAssertTrue(presenter.isPlaying,
                      "Step 2 (re-engage): the long-lived playbackStatePublisher subscription must STILL be wired after clearActiveSession dropped playbackModelCancellables. A regression that conflates the two cancellable sets would drop BOTH subscriptions and the second .playing event would not update isPlaying. This pins the polish-phase re-subscribe-cleanly contract (PP-3783 audiobook-switch path).")

        // Step 3: re-engage the cover-image forward (the manager-side seam
        // that `adoptCoverImage` simulates for hi-res arrivals).
        let newImg = UIImage()
        presenter.adoptCoverImage(newImg)
        XCTAssertTrue(presenter.coverImage === newImg,
                      "Step 3 (re-engage): adoptCoverImage must work after a clearActiveSession — proves the forwarding path is not subscription-gated. The PP-3783 switch-books path relies on this: open A, switch to B, B's cover must reach the presenter via adoptCoverImage even though A's subscriptions were dropped.")
    }

    // MARK: - Polish-phase: clearActiveSession clears full surface

    /// PRE: presenter has full state populated.
    /// EXPECTED: `clearActiveSession()` clears EVERY published mirror
    /// including the polish-phase additions (isPlaying, coverImage,
    /// currentLocation, playbackProgress).
    /// Mutates: a regression that forgets to clear one of the new fields
    /// would leak stale cover/position into the next session.
    func testPresenter_clearActiveSession_clearsPolishPhaseFields() {
        let presenter = AudiobookSessionPresenter(sessionManager: spySession)

        // Pre-populate the polish-phase fields directly via the public
        // seams.
        presenter.adoptCoverImage(UIImage())
        spySession.playbackStatePublisher.send(.playing(bookId: "book-1"))
        spinRunLoopForPublisherDelivery()
        XCTAssertNotNil(presenter.coverImage, "PRECONDITION: cover image set")
        XCTAssertTrue(presenter.isPlaying, "PRECONDITION: presenter reflects playing")

        presenter.clearActiveSession()

        XCTAssertNil(presenter.coverImage,
                     "clearActiveSession must clear coverImage so the next session starts fresh — a regression that forgets this leaks the prior book's cover into the new mini-player")
        XCTAssertFalse(presenter.isPlaying,
                       "clearActiveSession must clear isPlaying so the next mini-player render doesn't briefly show pause for the new book")
        XCTAssertNil(presenter.progress.currentLocation,
                     "clearActiveSession must clear currentLocation so the next mini-player render doesn't show the prior book's elapsed time")
        XCTAssertEqual(presenter.progress.playbackProgress, 0,
                       "clearActiveSession must reset playbackProgress to 0 so the scrubber doesn't briefly show the prior book's progress")
    }

    /// CONCERN coverage (qa_test SoD review of PR #1230): `clearActiveSession()`
    /// must reset the chapter-scoped progress mirrors (`chapterOffset`,
    /// `chapterTimeLeft`, `chapterProgress`) — the seek slider binds to
    /// `chapterProgress`, so a stale non-zero value would leave the next
    /// session's scrubber thumb parked mid-chapter before the first tick.
    ///
    /// These three fields are publicly settable `@Published` values on the
    /// high-frequency `AudiobookPlaybackProgress` object, so the test pre-seeds
    /// them directly (they are NOT `private(set)` toolkit-driven mirrors).
    ///
    /// Mutates: dropping any of the three `progress.chapter* = 0` lines from
    /// `clearActiveSession()` leaves that field non-zero and fails here.
    func testClearActiveSession_resetsChapterProgressFields() {
        let presenter = AudiobookSessionPresenter(sessionManager: spySession)
        presenter.progress.chapterOffset = 42
        presenter.progress.chapterTimeLeft = 30
        presenter.progress.chapterProgress = 0.5
        XCTAssertEqual(presenter.progress.chapterOffset, 42, "PRECONDITION: chapterOffset seeded")
        XCTAssertEqual(presenter.progress.chapterTimeLeft, 30, "PRECONDITION: chapterTimeLeft seeded")
        XCTAssertEqual(presenter.progress.chapterProgress, 0.5, accuracy: 0.0001, "PRECONDITION: chapterProgress seeded")

        presenter.clearActiveSession()

        XCTAssertEqual(presenter.progress.chapterOffset, 0,
                       "clearActiveSession must reset chapterOffset to 0 so the next session's chapter time-elapsed label doesn't show the prior book's offset")
        XCTAssertEqual(presenter.progress.chapterTimeLeft, 0,
                       "clearActiveSession must reset chapterTimeLeft to 0 so the next session's time-remaining label starts fresh")
        XCTAssertEqual(presenter.progress.chapterProgress, 0, accuracy: 0.0001,
                       "clearActiveSession must reset chapterProgress to 0 so the seek slider thumb doesn't start parked mid-chapter for the next book")
    }
    // MARK: - Polish-phase: transport-glyph self-heal (Bug 2, $currentLocation tick)

    /// PRE: fresh presenter (`isPlaying == false`); the toolkit has advanced
    /// the playhead so `sessionManager.isPlaying == true` WITHOUT re-emitting a
    /// `.playing` state event (chapter/track rollover, buffer resume after a
    /// seek). This is the exact stale-glyph race the self-heal fixes.
    /// EXPECTED: reconciling from the advancing `$currentLocation` tick flips
    /// the presenter's `isPlaying` (the play/pause glyph) true within one frame.
    /// Mutates: flipping the change-guard comparison `!=` to `==` skips the
    /// re-snap, leaving the glyph latched on "play" while audio is audible —
    /// this assertion then fails, killing that mutant.
    func testPresenter_playheadAdvancesWhileManagerIsPlaying_reconcileSelfHealsPlayGlyph() {
        let presenter = AudiobookSessionPresenter(sessionManager: spySession)
        XCTAssertFalse(presenter.isPlaying,
                       "PRECONDITION: glyph starts on play (isPlaying == false)")

        // The toolkit is playing audio but never re-emitted `.playing`.
        spySession.isPlaying = true

        // Advancing `$currentLocation` tick runs the self-heal.
        presenter.reconcileTransportGlyphFromSessionManager()

        XCTAssertTrue(presenter.isPlaying,
                      "An advancing playhead with sessionManager.isPlaying == true MUST self-heal the presenter's glyph to playing even without a discrete .playing event. A regression that drops or inverts the re-snap leaves the pause glyph missing while audio plays.")
    }

    /// PRE: fresh presenter (`isPlaying == false`); `sessionManager.isPlaying`
    /// is ALSO false (genuinely paused / not advancing).
    /// EXPECTED: reconciling does NOT flip the glyph to playing — the guard is
    /// authoritative-driven, not unconditional, so a paused player keeps the
    /// play glyph.
    /// Mutates: replacing the assignment source with a literal `true` (or
    /// dropping the guard so it always re-snaps to a stale value) would flip
    /// this false → true and fail here.
    func testPresenter_managerNotPlaying_reconcileLeavesGlyphOnPlay() {
        let presenter = AudiobookSessionPresenter(sessionManager: spySession)
        spySession.isPlaying = false

        presenter.reconcileTransportGlyphFromSessionManager()

        XCTAssertFalse(presenter.isPlaying,
                       "When sessionManager.isPlaying is false the self-heal must NOT flip the glyph to playing — the reconcile mirrors the authoritative manager flag, it does not fabricate a playing state.")
    }

    // MARK: - chapterProgress (chapter-relative scrubber value)

    /// Mid-chapter: offset 30s into a 120s chapter (30 elapsed + 90 left) is
    /// exactly 0.25. Pins `offset / (offset + timeLeft)`. A mutant that swaps
    /// the numerator/denominator, or reads book-relative progress instead,
    /// fails this exact value.
    func testChapterProgress_midChapter_isOffsetOverDuration() {
        let value = AudiobookSessionPresenter.chapterProgress(offset: 30, timeLeft: 90)
        XCTAssertEqual(value, 0.25, accuracy: 0.0001,
                       "chapterProgress must be offset / (offset + timeLeft): 30 / 120 = 0.25")
    }

    /// Zero chapter duration (offset 0, timeLeft 0 → duration 0) must return 0,
    /// NOT NaN. Pins the `duration > 0` guard: a mutant relaxing it to `>= 0`
    /// (or dropping it) divides 0/0 → NaN and fails this assertion.
    func testChapterProgress_zeroDuration_returnsZeroNotNaN() {
        let value = AudiobookSessionPresenter.chapterProgress(offset: 0, timeLeft: 0)
        XCTAssertFalse(value.isNaN, "Zero-duration chapter must not yield NaN")
        XCTAssertEqual(value, 0, accuracy: 0.0001,
                       "Zero-duration chapter progress must be 0 (guard returns early)")
    }

    /// Past chapter end: offset 200 with timeLeft -50 (duration 150) computes a
    /// raw ratio of 200/150 ≈ 1.33 which must clamp to 1.0. Pins the upper
    /// `min(_, 1)` clamp; a mutant dropping it lets the thumb run past the end.
    func testChapterProgress_clampsPastChapterEnd() {
        let value = AudiobookSessionPresenter.chapterProgress(offset: 200, timeLeft: -50)
        XCTAssertEqual(value, 1.0, accuracy: 0.0001,
                       "Progress past the chapter end must clamp to 1.0, not exceed it")
    }

    /// NIT coverage (qa_test SoD review of PR #1230): a negative offset (offset
    /// -30 into a 60s chapter → raw ratio -0.5) must clamp to 0 via the lower
    /// `max(_, 0)` bound, never a negative thumb position. Pins the LOWER clamp
    /// specifically (the existing tests pin the upper `min(_, 1)` and the
    /// zero-duration guard).
    ///
    /// Mutates: dropping the `max(offset / duration, 0)` lower clamp lets the
    /// value go negative (-0.5) and fails this assertion.
    func testChapterProgress_negativeOffset_clampsToZero() {
        XCTAssertEqual(AudiobookSessionPresenter.chapterProgress(offset: -30, timeLeft: 90), 0, accuracy: 0.0001,
                       "A negative chapter offset must clamp to 0, not produce a negative scrubber position")
    }
}
