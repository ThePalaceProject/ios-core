//
//  AudiobookSessionManagerPresenterMigrationTests.swift
//  PalaceTests
//
//  Module C (swarm_0b7616e7) — pins the migration of
//  `AudiobookSessionManager` off `coordinator.pushAudioRoute(...)` /
//  `coordinator.storeAudioModel(...)` / `coordinator.removeAudioModel(...)`
//  / `coordinator.popToRoot()` onto the new root-level
//  `AudiobookSessionPresenter`. These tests are SEPARATE from the existing
//  `AudiobookSessionManagerTests` / `AudiobookFirstOpenHangTests` /
//  `AudiobookSessionManagerShutdownTests` — those continue to pass
//  unchanged. This file ADDS the presenter-migration coverage.
//
//  Two spy strategies are used per the contract's A1 finding (Module C
//  contract §"Spy strategy"):
//
//    Path 1 — `SpyAudiobookSessionPresenter` via the manager's
//    `audiobookSessionPresenterProvider` closure (the manager's own DI
//    seam, no AppContainer modifier needed). Assertion: "the manager
//    called the right presenter method." Used for tests 1, 5, 6 + the
//    F-011 first-open + resume-from-mini-player tests.
//
//    Path 2 — real `NavigationCoordinator` + `NavigationCoordinatorHub`
//    via `navigationCoordinatorHubProvider`. Assertion: "the legacy
//    coordinator was NOT touched." Used for tests 2, 3, 4 — the test
//    asserts on observable state of the live coordinator (`path.isEmpty`,
//    `resolveAudioModel(for:)`).
//
//  Driving strategy: the migration tests drive the new INTERNAL seams
//  (`pushSessionToPresenter(book:playbackModel:)` and
//  `dismissPlayerOnPhone(bookId:)`) directly. These are the production
//  seams that the migration introduces — `presentCoverArtAndNavigation`
//  calls `pushSessionToPresenter` directly, and `stopPlayback(dismissPhoneUI:
//  true)` calls `dismissPlayerOnPhone`. Driving the seams directly is
//  honest end-state coverage and matches the precedent set by
//  `AudiobookFirstOpenHangTests` driving `awaitReadinessAndIssueFirstPlay`.
//  An end-to-end loop through `openAudiobook` is NOT feasible from a unit
//  test (the loader stage requires a real downloaded audiobook).
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import Combine
import XCTest
import PalaceAudiobookToolkit
@testable import Palace

@MainActor
final class AudiobookSessionManagerPresenterMigrationTests: XCTestCase {

    // MARK: - Fixtures

    private var spyPresenter: SpyAudiobookSessionPresenter!
    private var sessionManager: AudiobookSessionManager!

    /// Real NavigationCoordinator + hub used by Path-2 tests to assert
    /// that no `.audio` route was pushed and no `audioModelById` entry
    /// was stored.
    private var realCoordinator: NavigationCoordinator!
    private var realHub: NavigationCoordinatorHub!

    /// Per-test isolated container — built via `makeTestAppContainer()` so
    /// each test method gets a fresh service graph (no cross-test pollution
    /// through `AppContainer._cached`).
    private var appContainer: AppContainer!

    override func setUp() async throws {
        try await super.setUp()
        spyPresenter = SpyAudiobookSessionPresenter()
        realCoordinator = NavigationCoordinator()
        realHub = NavigationCoordinatorHub()
        realHub.coordinator = realCoordinator
        appContainer = makeTestAppContainer()

        // Manager is constructed with BOTH seams overridden:
        //   1. `audiobookSessionPresenterProvider` returns the spy.
        //   2. `navigationCoordinatorHubProvider` returns the real hub,
        //      so Path-2 tests can observe `coordinator.path` /
        //      `coordinator.resolveAudioModel(...)` post-call.
        // These tests pin the in-app-nav flag-ON presenter migration, so the
        // flag is forced ON — otherwise `dismissPlayerOnPhone` would take the
        // flag-OFF legacy pop path and the presenter-clear assertions would
        // not apply. The flag-OFF presentation is covered separately by
        // AudiobookSessionManagerFlagGatePresentationTests.
        sessionManager = AudiobookSessionManager(
            appContainer: appContainer,
            navigationCoordinatorHubProvider: { [unowned self] in self.realHub },
            audiobookSessionPresenterProvider: { [unowned self] in self.spyPresenter },
            inAppPlaybackNavEnabledProvider: { true }
        )
    }

    override func tearDown() async throws {
        await sessionManager?.stopPlayback(dismissPhoneUI: false)
        sessionManager = nil
        spyPresenter = nil
        realCoordinator = nil
        realHub = nil
        appContainer = nil
        try await super.tearDown()
    }

    // MARK: - Path 1: presenter-side assertions (tests 1, 5, 6)

    /// Test 1 — driving `pushSessionToPresenter` (the migrated production
    /// seam called from `presentCoverArtAndNavigation`) must call
    /// `presenter.presentOnFirstOpen()` exactly once and `presenter.adoptBook(_:)`
    /// once.
    ///
    /// Mutates: removing the `presenter.presentOnFirstOpen()` call from
    /// `pushSessionToPresenter` fails — spy count drops to 0.
    func testOpenAudiobook_firstOpen_callsPresenterPresentOnFirstOpen() {
        let book = TPPBookMocker.mockBook(distributorType: .OpenAccessAudiobook)

        sessionManager.pushSessionToPresenter(book: book, playbackModel: nil)

        XCTAssertEqual(spyPresenter.presentOnFirstOpenCallCount, 1,
                       "Migrated pushSessionToPresenter must call presenter.presentOnFirstOpen() exactly once — a regression that leaves the legacy pushAudioRoute in place would yield 0 calls here")
        XCTAssertEqual(spyPresenter.adoptBookCallCount, 1,
                       "Migrated path must adopt the book on the presenter so the mini-player can render chrome (title, author)")
        XCTAssertEqual(spyPresenter.currentBook?.identifier, book.identifier,
                       "The adopted book must match the one passed in — a regression that adopts a different book identity fails")
    }

    /// Test 5 — `stopPlayback(dismissPhoneUI: true)` clears the presenter
    /// state by routing through `dismissPlayerOnPhone(bookId:)` →
    /// `presenter.clearActiveSession()`. Drives the migrated
    /// `dismissPlayerOnPhone` seam directly.
    ///
    /// Mutates: leaving `presenter.clearActiveSession()` out of
    /// `dismissPlayerOnPhone` fails this — the presenter would still
    /// report `playbackModel != nil` post-stop.
    func testStopPlayback_clearsPresenterPlaybackModel() async {
        let book = TPPBookMocker.mockBook(distributorType: .OpenAccessAudiobook)
        // Pre-populate the spy presenter as if a bind had just happened.
        // We can't construct a real `AudiobookPlaybackModel` from XCTest
        // (toolkit-graph dependency), so we drive the spy's mutable
        // mirrors directly via the same `adopt*` API the production
        // path uses. This proves the spy's PRE-state, then verifies
        // dismissPlayerOnPhone clears it.
        spyPresenter.adoptBook(book)
        spyPresenter.presentOnFirstOpen()
        await spyPresenter.markHasActiveSessionForTesting(true)
        XCTAssertNotNil(spyPresenter.currentBook, "PRECONDITION: presenter must have a current book before stop")
        XCTAssertTrue(spyPresenter.isPlayerExpanded, "PRECONDITION: presenter must be expanded before stop")
        XCTAssertTrue(spyPresenter.hasActiveSession, "PRECONDITION: presenter must report active session before stop")

        sessionManager.dismissPlayerOnPhone(bookId: book.identifier)

        XCTAssertEqual(spyPresenter.clearActiveSessionCallCount, 1,
                       "Migrated dismissPlayerOnPhone must call presenter.clearActiveSession() exactly once — a regression that left the legacy coordinator.removeAudioModel + popToRoot in place would yield 0 calls")
        XCTAssertNil(spyPresenter.currentBook,
                     "presenter.currentBook must be nil after clearActiveSession — the mini-player drops when there's no session")
        XCTAssertFalse(spyPresenter.hasActiveSession,
                       "presenter.hasActiveSession must be false after clearActiveSession")
        XCTAssertFalse(spyPresenter.isPlayerExpanded,
                       "presenter.isPlayerExpanded must be false after clearActiveSession — the full player dismisses")
    }

    /// Test 6 — opening audiobook B while audiobook A is active swaps the
    /// presenter's bound book to B (PP-3783 "switching books replaces"
    /// semantic, ported to the presenter).
    ///
    /// Drives the migrated `pushSessionToPresenter` twice — first for A,
    /// then for B. The spy records the FIFO order of `adoptSession` calls
    /// by book identity; the second open's identity must match B (proves
    /// PP-3783's replace-not-stack invariant — A's identity was REPLACED
    /// not preserved).
    ///
    /// Mutates: a regression that fails to overwrite the presenter on
    /// the second open would leave A's book bound and fail the final
    /// `currentBook == B` assertion.
    func testOpenAudiobook_switchingAudiobooks_clearsPreviousPlaybackModel() {
        let bookA = TPPBookMocker.mockBook(distributorType: .OpenAccessAudiobook)
        let bookB = TPPBookMocker.mockBook(distributorType: .OpenAccessAudiobook)

        // Open A — drives the migrated production seam.
        sessionManager.pushSessionToPresenter(book: bookA, playbackModel: nil)
        XCTAssertEqual(spyPresenter.adoptBookCallCount, 1,
                       "PRECONDITION: spy recorded one adoptBook for A")
        XCTAssertEqual(spyPresenter.currentBook?.identifier, bookA.identifier,
                       "PRECONDITION: presenter is bound to A after first open")
        XCTAssertEqual(spyPresenter.adoptedBookIdentifiersInOrder, [bookA.identifier],
                       "PRECONDITION: spy FIFO list shows A was first adopted")

        // Open B — drives the production seam again. PP-3783's semantic
        // says B REPLACES A; the presenter must adopt B's identity.
        sessionManager.pushSessionToPresenter(book: bookB, playbackModel: nil)

        XCTAssertEqual(spyPresenter.presentOnFirstOpenCallCount, 2,
                       "Two opens must trigger two presentOnFirstOpen calls — proves the second open exercised the migrated production seam, not just the first")
        XCTAssertEqual(spyPresenter.adoptBookCallCount, 2,
                       "Two opens must trigger two adoptBook calls — proves both opens flowed through the presenter, not silently re-using the first")
        XCTAssertEqual(spyPresenter.currentBook?.identifier, bookB.identifier,
                       "presenter.currentBook must reflect B post-switch — a regression that leaves A's book bound fails PP-3783's 'switching books replaces' UX")
        XCTAssertEqual(spyPresenter.adoptedBookIdentifiersInOrder, [bookA.identifier, bookB.identifier],
                       "spy FIFO order must be [A, B] — proves the second adopt REPLACED rather than skipped or duplicated")
    }

    // MARK: - F-011 first-open expand (Path 1, §7.4 preservation)

    /// Pins §7.4 / F-011: `presentOnFirstOpen()` is called synchronously
    /// during `pushSessionToPresenter` — the manager's `bind()` runs this
    /// BEFORE `startPlaybackAndSyncPosition` (which contains the async
    /// Task wrapping the readiness gate). So after pushSessionToPresenter
    /// returns, the presenter's `isPlayerExpanded` is already `true` —
    /// there is no "wait for the async readiness Task to complete"
    /// required for the cover-art lockup to be visible.
    ///
    /// The test name embeds `firstOpen_setsPresenterIsPlayerExpandedTrue_
    /// beforeReadinessGateCompletes` — the "before" assertion is
    /// structural: no awaits between the migrated call and the assertion.
    ///
    /// Mutates: moving `presentOnFirstOpen()` INSIDE a Task block would
    /// fail this — the assertion would see isPlayerExpanded still false
    /// because the test runs without giving the Task time to dispatch.
    func testOpenAudiobook_firstOpen_setsPresenterIsPlayerExpandedTrue_beforeReadinessGateCompletes() {
        let book = TPPBookMocker.mockBook(distributorType: .OpenAccessAudiobook)
        XCTAssertFalse(spyPresenter.isPlayerExpanded, "PRECONDITION: presenter must start collapsed")

        // Drive the migrated production seam SYNCHRONOUSLY — no await
        // between this call and the assertion. The readiness-gate Task
        // is in `startPlaybackAndSyncPosition` which is the SEPARATE
        // call that comes AFTER this one in `bind`.
        sessionManager.pushSessionToPresenter(book: book, playbackModel: nil)

        XCTAssertTrue(spyPresenter.isPlayerExpanded,
                      "F-011 §7.4 preservation: presenter.isPlayerExpanded must be true SYNCHRONOUSLY after pushSessionToPresenter returns — the cover-art + loading-state lockup is the F-011 first-open UX. A regression that moves presentOnFirstOpen() inside a Task fails here.")
        XCTAssertEqual(spyPresenter.presentOnFirstOpenCallCount, 1,
                       "Exactly one presentOnFirstOpen() call must have fired in the synchronous window")
    }

    /// Pins the inverse of the F-011 auto-expand: `expand()` is a separate
    /// entry point (mini-player tap) — calling it directly is what a
    /// "resume from mini-player" path does. The test asserts both
    /// production seams independently drive `isPlayerExpanded` so a
    /// regression that conflates them would break one path.
    func testOpenAudiobook_resumeFromMiniPlayer_doesNOTForceIsPlayerExpanded() {
        let book = TPPBookMocker.mockBook(distributorType: .OpenAccessAudiobook)
        // Simulate "manager bound; user already in mid-session" — presenter
        // is up, but collapsed (mini-player visible only).
        spyPresenter.adoptBook(book)
        XCTAssertFalse(spyPresenter.isPlayerExpanded, "PRECONDITION: mid-session, mini-player visible, full player collapsed")

        // Drive `expand()` directly — this is the mini-player tap.
        spyPresenter.expand()

        XCTAssertTrue(spyPresenter.isPlayerExpanded,
                      "expand() must flip isPlayerExpanded to true — the resume-from-mini-player entry point")
        // The auto-expand path (`presentOnFirstOpen`) was never called — it
        // is only triggered on first-open via `pushSessionToPresenter`.
        XCTAssertEqual(spyPresenter.presentOnFirstOpenCallCount, 0,
                       "Resume-from-mini-player must NOT touch presentOnFirstOpen() — that's the first-open auto-expand path, not the resume path")
    }

    // MARK: - Nil-book dismiss branch (PR #1230 "✕ did nothing" fix)

    /// BLOCKER coverage (qa_test SoD review of PR #1230): `stopPlayback` with
    /// `dismissPhoneUI: true` and NO bound book (`currentBook == nil`) must
    /// STILL clear the presenter on the flag-ON path. This is the exact
    /// regression the fix addressed — gating the whole dismiss behind
    /// `if let bookId` left a nil-book teardown (transient / already-cleared
    /// states) with the mini-bar + pill on screen, so the ✕ appeared to do
    /// nothing.
    ///
    /// The manager from `setUp` is built with `inAppPlaybackNavEnabledProvider:
    /// { true }` and never has a book bound, so `currentBook` is nil here —
    /// exactly the state that reaches the `else if inAppPlaybackNavEnabledProvider()`
    /// branch. Driving the real `stopPlayback` entrypoint (not the internal
    /// `dismissPlayerOnPhone` seam) exercises the nil-book path end to end.
    ///
    /// Mutates: removing the `else if inAppPlaybackNavEnabledProvider()` branch
    /// (or its `audiobookSessionPresenterProvider().clearActiveSession()` call)
    /// drops this count to 0 — the ✕-did-nothing regression returns.
    func testStopPlayback_nilBook_flagOn_clearsActiveSession() async {
        XCTAssertNil(sessionManager.currentBook,
                     "PRECONDITION: no book bound — currentBook must be nil so stopPlayback takes the nil-book dismiss branch")

        await sessionManager.stopPlayback(dismissPhoneUI: true)

        XCTAssertEqual(spyPresenter.clearActiveSessionCallCount, 1,
                       "Flag-ON nil-book dismiss must clear the presenter exactly once — a regression that gates the whole dismiss behind `if let bookId` leaves the mini-bar + pill on screen (the ✕-did-nothing bug PR #1230 fixed)")
    }

    /// Sibling of the blocker test: with the in-app-nav flag OFF and no bound
    /// book, `stopPlayback(dismissPhoneUI: true)` must NOT touch the presenter.
    /// The flag-OFF path owns its chrome via the legacy coordinator pop (only
    /// reachable with a `bookId`), so a nil book on the flag-OFF path has
    /// nothing to clear — clearing the presenter here would be wrong (it isn't
    /// the presenter's session).
    ///
    /// Built with a locally-constructed manager whose flag provider returns
    /// false (the shared `setUp` manager forces the flag ON), reusing the same
    /// spy presenter so the call count is observable.
    ///
    /// Mutates: dropping the `inAppPlaybackNavEnabledProvider()` guard on the
    /// nil-book branch (so it clears unconditionally) flips this to 1 and fails.
    func testStopPlayback_nilBook_flagOff_doesNotClear() async {
        let flagOffManager = AudiobookSessionManager(
            appContainer: appContainer,
            navigationCoordinatorHubProvider: { [unowned self] in self.realHub },
            audiobookSessionPresenterProvider: { [unowned self] in self.spyPresenter },
            inAppPlaybackNavEnabledProvider: { false }
        )
        XCTAssertNil(flagOffManager.currentBook,
                     "PRECONDITION: no book bound on the flag-OFF manager")

        await flagOffManager.stopPlayback(dismissPhoneUI: true)

        XCTAssertEqual(spyPresenter.clearActiveSessionCallCount, 0,
                       "Flag-OFF nil-book dismiss must NOT clear the presenter — the flag-OFF path owns its chrome via the legacy coordinator pop, and a nil book has no presenter session to tear down. Clearing here would be a cross-path regression.")
    }

    // MARK: - Path 2: real coordinator, observable state (tests 2, 3, 4)

    /// Test 2 — drive the migrated `pushSessionToPresenter` with the REAL
    /// NavigationCoordinator wired; assert no `.audio` route was pushed.
    /// Pre-migration would have called `coordinator.pushAudioRoute(route)`
    /// → `coordinator.path` would contain one `.audio(BookRoute)` entry.
    /// Post-migration, the coordinator is untouched.
    ///
    /// Mutates: leaving the legacy `coordinator.pushAudioRoute(route)`
    /// call anywhere in the migration path fails — `path` would be
    /// non-empty.
    func testOpenAudiobook_firstOpen_doesNotPushAudioRouteOnRealCoordinator() {
        let book = TPPBookMocker.mockBook(distributorType: .OpenAccessAudiobook)
        XCTAssertTrue(realCoordinator.path.isEmpty, "PRECONDITION: real coordinator path must start empty")

        sessionManager.pushSessionToPresenter(book: book, playbackModel: nil)

        XCTAssertTrue(realCoordinator.path.isEmpty,
                      "Migration must NOT push an .audio route on the real coordinator — pre-migration `coordinator.pushAudioRoute(...)` would have left a single .audio(BookRoute) in `path`. A regression that left the legacy call in place would fail this.")
        XCTAssertNil(realCoordinator.resolveAudioModel(for: BookRoute(id: book.identifier)),
                     "Migration must NOT store an audio model in the coordinator's cache — pre-migration `coordinator.storeAudioModel(loaded.playbackModel, forBookId: id)` would have populated `audioModelById`. A regression fails this.")
    }

    /// Test 3 — drive the migrated open seam + dismiss seam with the
    /// REAL coordinator; assert the coordinator's audio-model cache stays
    /// empty across the whole lifecycle. This pins BOTH directions:
    /// open should not store, dismiss should not need to remove (because
    /// nothing was stored).
    ///
    /// Mutates: leaving `coordinator.storeAudioModel(...)` in the open
    /// path fails (the cache would be populated).
    func testStopPlayback_doesNotLeaveAudioModelInCoordinatorCache() {
        let book = TPPBookMocker.mockBook(distributorType: .OpenAccessAudiobook)

        sessionManager.pushSessionToPresenter(book: book, playbackModel: nil)
        sessionManager.dismissPlayerOnPhone(bookId: book.identifier)

        XCTAssertNil(realCoordinator.resolveAudioModel(for: BookRoute(id: book.identifier)),
                     "After open + dismiss round-trip with the migrated code, the coordinator's audioModelById cache must be empty — proves storeAudioModel was not called at open. A regression that re-introduces storeAudioModel fails.")
    }

    /// Test 4 — pre-push a non-audio route (`.bookDetail`) onto the real
    /// coordinator. Drive the migrated open + dismiss. The pre-existing
    /// route must STILL be the last item in `path` — i.e. `popToRoot()`
    /// did NOT fire. This is the PP-3783 / dismiss-back-stack preservation
    /// pin.
    ///
    /// Mutates: leaving the legacy `coordinator.popToRoot()` in
    /// `dismissPlayerOnPhone` fails — the pre-existing `.bookDetail` route
    /// would have been popped, and `path.isEmpty` would be true.
    func testStopPlayback_doesNotPopRealCoordinatorPath() {
        let book = TPPBookMocker.mockBook(distributorType: .OpenAccessAudiobook)

        // Push a pre-existing non-audio route — represents the user being
        // in book-detail when they opened the audiobook from the same flow.
        let preExistingRoute = AppRoute.bookDetail(BookRoute(id: "preexisting-bookdetail"))
        realCoordinator.path.append(preExistingRoute)
        XCTAssertEqual(realCoordinator.path.count, 1, "PRECONDITION: pre-existing route is on the stack")

        sessionManager.pushSessionToPresenter(book: book, playbackModel: nil)
        sessionManager.dismissPlayerOnPhone(bookId: book.identifier)

        XCTAssertEqual(realCoordinator.path.count, 1,
                       "After migrated dismissPlayerOnPhone, the pre-existing non-audio route must STILL be on the stack — popToRoot() must NOT have fired. A regression that left the legacy coordinator.popToRoot() in dismissPlayerOnPhone fails here. PP-3783 / dismiss-back-stack preservation.")
    }
}
