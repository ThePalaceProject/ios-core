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

    // MARK: - Instant-present loading shell (present before the loader runs)

    /// The manager calls `presentLoadingShell(for:coverImage:)` the instant a
    /// fresh open begins — BEFORE the loader chain runs — so the player slides
    /// up immediately with a cover + skeleton. This pins that the shell adopts
    /// the book identity + cover and expands, WITHOUT any playback model yet
    /// (the loader binds that later). Mutates: dropping any of the three writes
    /// in `presentLoadingShell` fails a corresponding assertion.
    func testPresentLoadingShell_adoptsBookAndCoverAndExpands_withNoPlaybackModelYet() {
        let presenter = AudiobookSessionPresenter(sessionManager: spySession)
        let book = TPPBookMocker.mockBook(title: "Instant Open", authors: "Author")
        let cover = UIImage()
        XCTAssertFalse(presenter.isPlayerExpanded, "PRECONDITION: collapsed")
        XCTAssertNil(presenter.currentBook, "PRECONDITION: no book")
        XCTAssertNil(presenter.playbackModel, "PRECONDITION: no model")

        presenter.presentLoadingShell(for: book, coverImage: cover)

        XCTAssertEqual(presenter.currentBook?.identifier, book.identifier,
                       "shell must adopt the book so the root mount gate + title/author chrome have a source")
        XCTAssertTrue(presenter.coverImage === cover,
                      "shell must adopt the low-res cover so it shows the instant the skeleton clears")
        XCTAssertTrue(presenter.isPlayerExpanded,
                      "shell must expand so the morphing player slides up on tap, not after load")
        XCTAssertNil(presenter.playbackModel,
                     "shell must present BEFORE the loader binds a playback model — this is the whole point of instant-present")
    }

    /// A coverless book must clear the mirror (placeholder), not inherit a stale
    /// cover. Mutates: `adoptCoverImage(coverImage)` → skipping the write leaves
    /// a prior cover in place; this test would then see the stale image.
    func testPresentLoadingShell_withNilCover_clearsCoverForPlaceholder() {
        let presenter = AudiobookSessionPresenter(sessionManager: spySession)
        presenter.adoptCoverImage(UIImage())  // stale cover from a prior session
        let book = TPPBookMocker.mockBook(title: "No Cover", authors: "Author")

        presenter.presentLoadingShell(for: book, coverImage: nil)

        XCTAssertNil(presenter.coverImage,
                     "a coverless open must show the placeholder, not a stale cover from a previous session")
    }

    /// Round-trip through the production seam: present the shell via
    /// `presentLoadingShell`, then a failed load publishes `.error` — the shell
    /// must tear down completely so it never lingers with no book actually
    /// loaded. Mutates: removing the `.error` teardown leaves the shell up.
    func testPresentLoadingShell_thenErrorState_tearsDownShell() {
        let presenter = AudiobookSessionPresenter(sessionManager: spySession)
        let book = TPPBookMocker.mockBook(title: "Fails To Load", authors: "Author")

        presenter.presentLoadingShell(for: book, coverImage: UIImage())
        XCTAssertTrue(presenter.isPlayerExpanded, "PRECONDITION: shell up")
        XCTAssertNotNil(presenter.currentBook, "PRECONDITION: book adopted")

        spySession.state = .error(bookId: book.identifier, message: "boom")
        spySession.playbackStatePublisher.send(.error(bookId: book.identifier, message: "boom"))
        spinRunLoopForPublisherDelivery()  // the .error teardown sink hops via receive(on: .main)

        XCTAssertFalse(presenter.isPlayerExpanded,
                       "a failed open must collapse the shell — no phantom loading player")
        XCTAssertNil(presenter.currentBook,
                     "a failed open must drop the book so the root overlay unmounts")
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

    /// Flushes the main queue so a publisher event sent synchronously via
    /// `playbackStatePublisher.send(...)` is delivered through
    /// `.receive(on: DispatchQueue.main)` BEFORE the test asserts on the
    /// presenter's published mirrored state. Without this, the assertion races
    /// the sink and intermittently fails.
    private func spinRunLoopForPublisherDelivery() {
        // Deterministic FIFO drain instead of a fixed wall-clock
        // `RunLoop.main.run(until:)` spin. The presenter mirrors state through
        // `.receive(on: DispatchQueue.main)`; enqueueing a no-op behind the
        // already-queued delivery block and awaiting it guarantees delivery has
        // landed — no fixed 50ms guess that under CI sim-clone oversubscription
        // could expire before the hop delivers (races the sink → flaky assert).
        drainMainQueue()
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

    // MARK: - fix/audiobook-first-open-hang: pre-bind download progress
    //
    // During the PP-4542 content-download wait the toolkit playback model that
    // normally mirrors `$overallDownloadProgress` doesn't exist yet, so the
    // loading shell showed a static skeleton that read as "hung." `showDownloadProgress`
    // feeds download-center progress into the shell during that window so it shows
    // a determinate "Downloading…" bar. Superseded by `adoptPlaybackModel` at bind.

    /// EXPECTED: sets the download fraction and flips `isDownloading` true so the
    /// shell's download bar becomes visible during the pre-bind wait.
    /// Mutates: dropping the `isDownloading = true` assignment hides the bar and
    /// fails this; changing the assigned fraction fails the value assertion.
    func testShowDownloadProgress_setsProgressAndDownloadingFlag() {
        let presenter = AudiobookSessionPresenter(sessionManager: spySession)
        presenter.showDownloadProgress(0.42)
        XCTAssertEqual(presenter.overallDownloadProgress, 0.42, accuracy: 0.0001,
                       "showDownloadProgress must publish the download fraction so the shell bar is determinate")
        XCTAssertTrue(presenter.isDownloading,
                      "showDownloadProgress must flip isDownloading true so the shell's download bar is visible during the wait")
    }

    /// EXPECTED: fractions outside 0…1 clamp. Pins BOTH bounds of the
    /// `max(0, min(1, fraction))` guard — a garbage download-center reading must
    /// never drive the bar past full or negative.
    /// Mutates: dropping the upper `min(1,_)` lets 1.7 through; dropping the lower
    /// `max(0,_)` lets -0.3 through — each fails the respective assertion.
    func testShowDownloadProgress_clampsOutOfRangeFractions() {
        let presenter = AudiobookSessionPresenter(sessionManager: spySession)
        presenter.showDownloadProgress(1.7)
        XCTAssertEqual(presenter.overallDownloadProgress, 1.0, accuracy: 0.0001,
                       "A fraction > 1 must clamp to 1.0 — the download bar can't exceed full")
        presenter.showDownloadProgress(-0.3)
        XCTAssertEqual(presenter.overallDownloadProgress, 0.0, accuracy: 0.0001,
                       "A negative fraction must clamp to 0 — the download bar can't go negative")
    }

    /// EXPECTED: the pre-bind placeholder is torn down by `clearActiveSession`
    /// (the stopPlayback/dismiss path), so a superseded/failed open doesn't leave
    /// a stale "Downloading…" bar behind.
    /// Mutates: if clearActiveSession stops resetting these mirrors, the bar
    /// persists and this fails.
    func testShowDownloadProgress_clearedByClearActiveSession() {
        let presenter = AudiobookSessionPresenter(sessionManager: spySession)
        presenter.showDownloadProgress(0.6)
        presenter.clearActiveSession()
        XCTAssertEqual(presenter.overallDownloadProgress, 0, accuracy: 0.0001,
                       "clearActiveSession must reset the pre-bind download fraction so no stale bar survives teardown")
        XCTAssertFalse(presenter.isDownloading,
                       "clearActiveSession must clear the pre-bind isDownloading flag")
    }

    // MARK: - hasStartedPlayback (latched; gates the player download bar)
    //
    // The player's download bar is gated on this rather than the live
    // `isPlaying`, because for LCP the toolkit reports "downloading" through
    // track decryption that streaming playback never waits for. See
    // `AudiobookDownloadProgressPolicy`.

    // NOTE: a `testHasStartedPlayback_isFalseOnAFreshPresenter` case was removed
    // here. It asserted a default with no action taken, which CLAUDE.md bans
    // outright — it could only fail if the property's initialiser changed. The
    // states that matter are driven below: a non-playing event must NOT latch,
    // `.playing` must, a pause must not clear it, and teardown must.
    /// PRE: session emits `.playing`.
    /// EXPECTED: the latch rises.
    /// Mutates: deleting the latch assignment fails this.
    func testHasStartedPlayback_latchesTrueOnFirstPlayingState() {
        let presenter = AudiobookSessionPresenter(sessionManager: spySession)

        spySession.playbackStatePublisher.send(.playing(bookId: "book-1"))
        spinRunLoopForPublisherDelivery()

        XCTAssertTrue(presenter.hasStartedPlayback,
                      "the first .playing must latch — this is what retires the download bar for the session")
    }

    /// The cell none of the others reach: a NON-playing state arriving FIRST.
    ///
    /// Added because mutation found it. Flipping the latch's `&&` to `||`
    /// survived the whole suite — and that mutant is a real defect, not a
    /// curiosity: with `||`, `playing == false` plus a not-yet-set latch raises
    /// the latch, so the very first `.loading` would retire the download bar
    /// BEFORE playback started. That is precisely the window the bar still
    /// exists for, so the player would go silent-and-blank exactly when the
    /// patron is waiting.
    ///
    /// The four tests around this one all send `.playing` first, so every one
    /// of them passes under the mutant. Enumerating the event that comes before
    /// playback is what distinguishes a latch from an unconditional set.
    func testHasStartedPlayback_doesNotLatchOnALoadingStateBeforePlaybackBegins() {
        let presenter = AudiobookSessionPresenter(sessionManager: spySession)

        spySession.playbackStatePublisher.send(.loading(bookId: "book-1"))
        spinRunLoopForPublisherDelivery()

        XCTAssertFalse(presenter.hasStartedPlayback,
                       "loading is not playing — latching here retires the download bar during the very wait it exists to explain")
    }

    /// Same cell, the other non-playing event, so the rule is pinned as "only
    /// `.playing` latches" rather than "`.loading` happens not to".
    func testHasStartedPlayback_doesNotLatchOnIdleBeforePlaybackBegins() {
        let presenter = AudiobookSessionPresenter(sessionManager: spySession)

        spySession.playbackStatePublisher.send(.idle)
        spinRunLoopForPublisherDelivery()

        XCTAssertFalse(presenter.hasStartedPlayback,
                       "only a real .playing may raise the latch")
    }

    /// The reason the flag is latched rather than mirrored. A pause drops
    /// `isPlaying`; if the bar were gated on that, pausing a book the patron had
    /// been listening to for twenty minutes would pop a download bar onto it.
    /// Mutates: clearing the latch on a non-playing state fails this and not the
    /// test above, which is what distinguishes "latched" from "mirrored".
    func testHasStartedPlayback_survivesAPauseAfterPlaying() {
        let presenter = AudiobookSessionPresenter(sessionManager: spySession)

        spySession.playbackStatePublisher.send(.playing(bookId: "book-1"))
        spinRunLoopForPublisherDelivery()
        spySession.playbackStatePublisher.send(.idle)
        spinRunLoopForPublisherDelivery()

        XCTAssertFalse(presenter.isPlaying,
                       "precondition: the pause must actually have dropped isPlaying, or this asserts nothing")
        XCTAssertTrue(presenter.hasStartedPlayback,
                      "a pause must not take the latch back down — otherwise pausing re-summons the download bar")
    }

    /// SAME-BOOK RE-OPEN — the case that was actually broken.
    ///
    /// `stopPlayback(dismissPhoneUI: !isSameBook)` skips `clearActiveSession()`
    /// when the book is unchanged, so `currentBook` survives into the next open.
    /// An earlier fix reset the latch in `adoptBook` on IDENTIFIER CHANGE, which
    /// therefore never fired here — and the test written to prove it asserted
    /// the different-book case under a "same-book" heading, so it passed while
    /// the bug stood. Both reviewers caught that independently.
    ///
    /// `presentLoadingShell` is the session boundary and resets unconditionally.
    func testHasStartedPlayback_resetsOnAReOpenOfTheSAMEBook() {
        let presenter = AudiobookSessionPresenter(sessionManager: spySession)
        let book = TPPBookMocker.mockBook(title: "Same Book", authors: "Author")
        presenter.presentLoadingShell(for: book, coverImage: nil)

        spySession.playbackStatePublisher.send(.playing(bookId: book.identifier))
        spinRunLoopForPublisherDelivery()
        XCTAssertTrue(presenter.hasStartedPlayback, "precondition: the latch must be up")

        // Re-open the SAME book. No teardown runs on this path.
        presenter.presentLoadingShell(for: book, coverImage: nil)

        XCTAssertFalse(presenter.hasStartedPlayback,
                       "a re-open of the same book is a new session — a surviving latch silences its loading wait")
    }

    /// SEAM INVARIANT, not a currently-reachable path. Review traced every
    /// production caller and found none passes `startPlaying: false`, so today
    /// `adoptBook` is never reached without `presentLoadingShell`. That is a
    /// property of the callers, not of the code — a future CarPlay or prefetch
    /// caller passing `false` would silently resurrect the stale latch.
    ///
    /// Pinned here so the resurrection fails a test rather than shipping: any
    /// path that adopts a book for a NEW session must leave the latch down.
    func testHasStartedPlayback_isDownAfterAdoptingAFreshBookWithoutTheShell() {
        let presenter = AudiobookSessionPresenter(sessionManager: spySession)
        let first = TPPBookMocker.mockBook(title: "Seam First", authors: "Author")
        presenter.presentLoadingShell(for: first, coverImage: nil)

        spySession.playbackStatePublisher.send(.playing(bookId: first.identifier))
        spinRunLoopForPublisherDelivery()
        XCTAssertTrue(presenter.hasStartedPlayback, "precondition: the latch must be up")

        // Tear the session down the way a close does, then adopt a new book
        // WITHOUT the shell — the shape a `startPlaying: false` open would take.
        presenter.clearActiveSession()
        let second = TPPBookMocker.mockBook(title: "Seam Second", authors: "Author")
        presenter.adoptBook(second)

        XCTAssertFalse(presenter.hasStartedPlayback,
                       "a new session must start with the bar permitted, whichever seam opened it")
    }

    /// A different book re-opened through the same seam must reset too.
    func testHasStartedPlayback_resetsOnAReOpenOfADifferentBook() {
        let presenter = AudiobookSessionPresenter(sessionManager: spySession)
        let first = TPPBookMocker.mockBook(title: "First Book", authors: "Author")
        presenter.presentLoadingShell(for: first, coverImage: nil)

        spySession.playbackStatePublisher.send(.playing(bookId: first.identifier))
        spinRunLoopForPublisherDelivery()

        let second = TPPBookMocker.mockBook(title: "Second Book", authors: "Author")
        XCTAssertNotEqual(first.identifier, second.identifier, "precondition: distinct identifiers")
        presenter.presentLoadingShell(for: second, coverImage: nil)

        XCTAssertFalse(presenter.hasStartedPlayback)
    }

    /// The property the identifier guard was reaching for, kept: a bare
    /// `adoptBook` mid-session (cover refresh) must NOT drop a live latch, or
    /// the download bar returns underneath playing audio.
    func testHasStartedPlayback_survivesABareAdoptBookMidSession() {
        let presenter = AudiobookSessionPresenter(sessionManager: spySession)
        let book = TPPBookMocker.mockBook(title: "Mid Session", authors: "Author")
        presenter.presentLoadingShell(for: book, coverImage: nil)

        spySession.playbackStatePublisher.send(.playing(bookId: book.identifier))
        spinRunLoopForPublisherDelivery()

        presenter.adoptBook(book)

        XCTAssertTrue(presenter.hasStartedPlayback,
                      "a bare re-adopt is not a new session — dropping the latch here puts the bar back under playing audio")
    }

    /// The latch is session-scoped: the NEXT book opens with the bar permitted
    /// again. Without this reset a second audiobook would never show progress
    /// while it genuinely was loading.
    func testHasStartedPlayback_resetsOnClearActiveSession() {
        let presenter = AudiobookSessionPresenter(sessionManager: spySession)

        spySession.playbackStatePublisher.send(.playing(bookId: "book-1"))
        spinRunLoopForPublisherDelivery()
        XCTAssertTrue(presenter.hasStartedPlayback, "precondition: the latch must be up before teardown")

        presenter.clearActiveSession()

        XCTAssertFalse(presenter.hasStartedPlayback,
                       "the latch is per-session — the next book must be able to show its loading progress")
    }


    // MARK: - Archive fetch (`archiveProgress`) — the producer of the bar's third input
    //
    // The policy table in AudiobookDownloadProgressPolicyTests covers the pure
    // rule. These cover the code that decides whether its input is ever true
    // for the RIGHT book — the half three reviewers blocked on, and the same
    // "a pure rule was covered while the code computing its input was not"
    // shape 264676c7d names in its own retro.

    /// Helper mirroring the production wiring: edges + progress + seed.
    @MainActor
    private func makeArchivePresenter(
        activeIdentifiers: Set<String> = []
    ) -> (AudiobookSessionPresenter,
          PassthroughSubject<(String, Bool), Never>,
          PassthroughSubject<(String, Double), Never>) {
        let edges = PassthroughSubject<(String, Bool), Never>()
        let progress = PassthroughSubject<(String, Double), Never>()
        let presenter = AudiobookSessionPresenter(
            sessionManager: SpyShimSession(),
            archiveTransferPublisher: edges.eraseToAnyPublisher(),
            archiveProgressPublisher: progress.eraseToAnyPublisher(),
            isArchiveTransferActive: { activeIdentifiers.contains($0) }
        )
        return (presenter, edges, progress)
    }

    @MainActor
    func testArchiveTransferForCurrentBook_raisesTheBar() async {
        let book = TPPBookMocker.mockBook(distributorType: .AudiobookLCP)
        let (presenter, edges, _) = makeArchivePresenter()
        presenter.adoptBook(book)
        XCTAssertFalse(presenter.isFetchingArchive, "precondition: no transfer")

        edges.send((book.identifier, true))
        await awaitConditionAsync { presenter.isFetchingArchive }

        XCTAssertTrue(presenter.isFetchingArchive,
                      "an archive fetch for the bound book must raise the bar — this is the signal the player had no access to")
    }

    @MainActor
    func testArchiveTransferForADifferentBook_isIgnored() async {
        let book = TPPBookMocker.mockBook(distributorType: .AudiobookLCP)
        let other = TPPBookMocker.mockBook(distributorType: .AudiobookLCP)
        let (presenter, edges, _) = makeArchivePresenter()
        presenter.adoptBook(book)

        edges.send((other.identifier, true))
        await drainMainQueueAsync()

        XCTAssertFalse(presenter.isFetchingArchive,
                       "another book's transfer must not raise this book's bar — the filter is at DELIVERY time because the presenter outlives sessions")
    }

    @MainActor
    func testFallingEdge_clearsTheBar() async {
        let book = TPPBookMocker.mockBook(distributorType: .AudiobookLCP)
        let (presenter, edges, _) = makeArchivePresenter()
        presenter.adoptBook(book)

        edges.send((book.identifier, true))
        await awaitConditionAsync { presenter.isFetchingArchive }
        XCTAssertTrue(presenter.isFetchingArchive, "precondition")

        edges.send((book.identifier, false))
        await awaitConditionAsync { !presenter.isFetchingArchive }

        XCTAssertFalse(presenter.isFetchingArchive,
                       "the falling edge is the ONLY thing that lowers the bar — without it the bar never clears and reads as a permanent hang")
    }

    @MainActor
    func testBoundMidTransfer_seedsTheBarImmediately() async {
        let book = TPPBookMocker.mockBook(distributorType: .AudiobookLCP)
        let (presenter, _, _) = makeArchivePresenter(activeIdentifiers: [book.identifier])

        presenter.adoptBook(book)

        XCTAssertTrue(presenter.isFetchingArchive,
                      "opening a book mid-transfer is the COMMON path — the measured archives all run past three minutes and the publisher only speaks on edges, so without the seed the bar never appears")
    }

    @MainActor
    func testBoundWithNoTransfer_doesNotSeedTheBarOn() async {
        let book = TPPBookMocker.mockBook(distributorType: .AudiobookLCP)
        let (presenter, _, _) = makeArchivePresenter(activeIdentifiers: [])

        presenter.adoptBook(book)

        XCTAssertFalse(presenter.isFetchingArchive,
                       "the seed must report the query's answer, not assume one — a seed stuck ON would put the bar on every book")
    }

    @MainActor
    func testClearActiveSession_resetsTheArchiveBar() async {
        let book = TPPBookMocker.mockBook(distributorType: .AudiobookLCP)
        let (presenter, edges, _) = makeArchivePresenter()
        presenter.adoptBook(book)
        edges.send((book.identifier, true))
        await awaitConditionAsync { presenter.isFetchingArchive }
        XCTAssertTrue(presenter.isFetchingArchive, "precondition")

        presenter.clearActiveSession()

        XCTAssertFalse(presenter.isFetchingArchive,
                       "a stale bar must not leak into the next session")
        XCTAssertNil(presenter.archiveProgress,
                     "and its number must go with it")
    }

    /// The bar must carry the ARCHIVE's number, not the toolkit's per-track
    /// figure. Review caught the first cut summoning the bar off a flag while
    /// the view still rendered `overallDownloadProgress`, which during an
    /// archive fetch reads ~0 — a bar frozen at 0% for minutes.
    @MainActor
    func testArchiveProgress_tracksTheArchiveTransfer() async {
        let book = TPPBookMocker.mockBook(distributorType: .AudiobookLCP)
        let (presenter, edges, progress) = makeArchivePresenter()
        presenter.adoptBook(book)
        edges.send((book.identifier, true))
        await drainMainQueueAsync()

        progress.send((book.identifier, 0.42))
        await awaitConditionAsync { (presenter.archiveProgress ?? 0) > 0 }

        XCTAssertEqual(presenter.archiveProgress ?? -1, 0.42, accuracy: 0.001,
                       "the bar's number must be the archive fetch's own progress")
    }

    /// Progress alone must not summon the bar: the same publisher carries
    /// ordinary (non-LCP) download progress, and raising the archive bar on it
    /// would put the player bar back on transfers this policy keeps quiet.
    @MainActor
    func testProgressWithoutAnActiveTransfer_doesNotRaiseTheBar() async {
        let book = TPPBookMocker.mockBook(distributorType: .AudiobookLCP)
        let (presenter, _, progress) = makeArchivePresenter()
        presenter.adoptBook(book)

        progress.send((book.identifier, 0.5))
        await drainMainQueueAsync()

        XCTAssertFalse(presenter.isFetchingArchive,
                       "a progress tick is not evidence that an ARCHIVE fetch is running")
    }

    /// THE TWIN GUARD. `testArchiveTransferForADifferentBook_isIgnored` covers
    /// the EDGES sink; this covers the PROGRESS sink, written in the same
    /// function from the same template and previously untested. Deleting its
    /// `update.0 == currentBook?.identifier` check survived all eight tests.
    ///
    /// `downloadProgressPublisher` is app-wide and Palace downloads
    /// concurrently, so without the guard an unrelated book's progress writes
    /// into the bound book's archive bar — the exact defect family this whole
    /// change exists to fix.
    @MainActor
    func testArchiveProgressForADifferentBook_isIgnored() async {
        let book = TPPBookMocker.mockBook(distributorType: .AudiobookLCP)
        let other = TPPBookMocker.mockBook(distributorType: .AudiobookLCP)
        let (presenter, edges, progress) = makeArchivePresenter()
        presenter.adoptBook(book)
        edges.send((book.identifier, true))
        await awaitConditionAsync { presenter.isFetchingArchive }

        progress.send((other.identifier, 0.9))
        await drainMainQueueAsync()

        XCTAssertEqual(presenter.archiveProgress ?? -1, 0, accuracy: 0.001,
                       "another book's progress must not drive this book's bar")
    }

    /// The clamp is the only thing keeping the capsule inside its track — the
    /// view multiplies this by the available width.
    @MainActor
    func testArchiveProgress_isClampedToUnitRange() async {
        let book = TPPBookMocker.mockBook(distributorType: .AudiobookLCP)
        let (presenter, edges, progress) = makeArchivePresenter()
        presenter.adoptBook(book)
        edges.send((book.identifier, true))
        await awaitConditionAsync { presenter.isFetchingArchive }

        progress.send((book.identifier, 4.2))
        await awaitConditionAsync { (presenter.archiveProgress ?? 0) > 0 }
        XCTAssertEqual(presenter.archiveProgress ?? -1, 1.0, accuracy: 0.001,
                       "over-unit progress must clamp to 1 or the bar overruns its track")

        progress.send((book.identifier, -1))
        await awaitConditionAsync { (presenter.archiveProgress ?? 1) < 1 }
        XCTAssertEqual(presenter.archiveProgress ?? -1, 0, accuracy: 0.001,
                       "negative progress must clamp to 0")
    }

    /// Pins the rising edge's documented promise to keep any progress already
    /// seen. `adoptBook` seeds twice per open, so a repeated rising edge must
    /// not snap a climbing bar back to 0%.
    @MainActor
    func testRepeatedRisingEdge_keepsProgressAlreadySeen() async {
        let book = TPPBookMocker.mockBook(distributorType: .AudiobookLCP)
        let (presenter, edges, progress) = makeArchivePresenter()
        presenter.adoptBook(book)
        edges.send((book.identifier, true))
        await awaitConditionAsync { presenter.isFetchingArchive }
        progress.send((book.identifier, 0.6))
        await awaitConditionAsync { (presenter.archiveProgress ?? 0) > 0.5 }

        edges.send((book.identifier, true))
        await drainMainQueueAsync()

        XCTAssertEqual(presenter.archiveProgress ?? -1, 0.6, accuracy: 0.001,
                       "a second rising edge must not reset a bar that already climbed")
    }

    /// THE VETO'S PROTECTIVE BRANCH. `testFallingEdge_clearsTheBar` runs with
    /// an EMPTY active set, so the query answers false and only the CLEARING
    /// half of the falling edge executes. Reverting the veto to an
    /// unconditional `archiveProgress = nil` left the whole suite green —
    /// the hardening was indistinguishable from its own absence, which is the
    /// same shape review blocked this branch for twice.
    ///
    /// A falling edge can be stale: enqueued on the main hop before a seed or
    /// a restart found the transfer live again. The synchronous query is
    /// authoritative, so it vetoes the clear and the bar stays up.
    @MainActor
    func testStaleFallingEdge_isVetoedByTheAuthoritativeQuery() async {
        let book = TPPBookMocker.mockBook(distributorType: .AudiobookLCP)
        let (presenter, edges, progress) = makeArchivePresenter(
            activeIdentifiers: [book.identifier]
        )
        presenter.adoptBook(book)
        edges.send((book.identifier, true))
        await awaitConditionAsync { presenter.isFetchingArchive }
        progress.send((book.identifier, 0.4))
        await awaitConditionAsync { (presenter.archiveProgress ?? 0) > 0.3 }

        // The transfer is STILL registered, so this edge is stale.
        edges.send((book.identifier, false))
        // FIFO barrier: a second edge on the SAME publisher reaches the SAME
        // sink after the first, so awaiting its effect PROVES the falling edge
        // was delivered. A single drain against a `.receive(on: RunLoop.main)`
        // sink could pass vacuously by simply not delivering it.
        edges.send((book.identifier, true))
        await awaitConditionAsync { presenter.isFetchingArchive }

        XCTAssertTrue(presenter.isFetchingArchive,
                      "a stale falling edge must not clear a bar the authoritative query still reports as live")
        XCTAssertEqual(presenter.archiveProgress ?? -1, 0.4, accuracy: 0.001,
                       "and the vetoed clear must not discard the progress already shown")
    }

    /// THE SEED'S PRESERVE ARM. `testRepeatedRisingEdge_keepsProgressAlreadySeen`
    /// pins the SINK's `?? 0`; this pins the SEED's, and the seed is the one
    /// whose failure mode is on the common path: `presentLoadingShell` and
    /// `AudiobookSessionManager` both reach `adoptBook`, so a book seeds TWICE
    /// per open with the progress sink climbing in between. A seed of `= 0`
    /// snaps a 60% bar back to 0% every time.
    ///
    /// Review found `? 0 : nil` surviving the whole suite — the twin was
    /// pinned, the one that matters was not.
    @MainActor
    func testSecondSeed_keepsProgressAlreadyClimbed() async {
        let book = TPPBookMocker.mockBook(distributorType: .AudiobookLCP)
        let (presenter, edges, progress) = makeArchivePresenter(
            activeIdentifiers: [book.identifier]
        )
        presenter.adoptBook(book)
        edges.send((book.identifier, true))
        await awaitConditionAsync { presenter.isFetchingArchive }
        progress.send((book.identifier, 0.6))
        await awaitConditionAsync { (presenter.archiveProgress ?? 0) > 0.5 }

        // The second seed of the same open.
        presenter.adoptBook(book)

        XCTAssertEqual(presenter.archiveProgress ?? -1, 0.6, accuracy: 0.001,
                       "the second seed of an open must not snap a climbing bar back to 0%")
    }

    /// THE SEED'S CLEAR ARM. Matters on a same-book re-open, which by the
    /// presenter's own contract skips `clearActiveSession()` — so the seed is
    /// the only thing that can retire a bar left over from the previous open.
    @MainActor
    func testSeedWithNoActiveTransfer_clearsAStaleBar() async {
        let book = TPPBookMocker.mockBook(distributorType: .AudiobookLCP)
        let (presenter, edges, _) = makeArchivePresenter(activeIdentifiers: [])
        presenter.adoptBook(book)
        edges.send((book.identifier, true))
        await awaitConditionAsync { presenter.isFetchingArchive }

        // Re-open with nothing transferring: the seed must retire the bar.
        presenter.adoptBook(book)

        XCTAssertFalse(presenter.isFetchingArchive,
                       "a seed that only ever sets and never clears leaves a finished transfer's bar up forever")
    }
}
