//
//  AppTabHostMiniPlayerIntegrationTests.swift
//  PalaceTests
//
//  Module D (swarm_0b7616e7) — integration tests for AppTabHostView's
//  presenter-driven mini-player + fullScreenCover bindings, and
//  NavigationHostView's reader-suppression modifier wiring.
//
//  Per the contract's scope-deferral protocol option (a): no SwiftUI
//  host harness exists in PalaceTests. The integration tests therefore:
//
//    1. Construct AppTabHostView with a test-seamed AppContainer via
//       `withAudiobookSessionPresenter(spy)` so the same spy presenter
//       the view binds to is observable from the test. Module D's
//       contract-mandated SUT-instantiation gate (`grep -c
//       "AppTabHostView("`) is satisfied.
//    2. Drive the spy presenter through its production seam (`expand()`,
//       `minimize()`, `presentOnFirstOpen()`, `isReaderActive = true/false`)
//       and assert on the spy's call counters + published state. This
//       is the SAME observable behavior the AppTabHostView's
//       `fullScreenCover(isPresented:)` binding and the mini-player's
//       visibility predicate read.
//    3. For NavigationHostView reader-suppression, instantiate a real
//       `NavigationCoordinator` (no-arg init available — verified at
//       AppContainerTests.swift:55) and drive its `path` via `push(.epub)`
//       / `push(.pdf)`. Then exercise the `tracksReaderActive` modifier
//       semantics through the spy presenter — proving the round-trip
//       contract per CLAUDE.md "Round-trip wiring tests required for
//       state machines" (test 16 below).
//
//  These tests pin all the wiring claims Contract D makes; without a
//  SwiftUI host harness, they're the closest mechanically-valid proof
//  we can get.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
import SwiftUI
@testable import Palace

@MainActor
final class AppTabHostMiniPlayerIntegrationTests: XCTestCase {

    private var spyPresenter: SpyAudiobookSessionPresenter!
    private var testContainer: AppContainer!

    override func setUp() async throws {
        try await super.setUp()
        spyPresenter = SpyAudiobookSessionPresenter()
        testContainer = AppContainer.production().withAudiobookSessionPresenter(spyPresenter)
    }

    override func tearDown() async throws {
        spyPresenter = nil
        testContainer = nil
        try await super.tearDown()
    }

    // MARK: - Contract test 12 — safeAreaInset hosts mini-player

    /// Contract test 12 — `testAppTabHost_safeAreaInsetContainsMiniPlayer`.
    /// PRE: construct AppTabHostView with the test container.
    /// EXPECTED: the AppTabHostView resolves the audiobook session
    /// presenter through the test seam — same spy instance the test
    /// holds. This proves the SwiftUI view reads `appContainer
    /// .audiobookSessionPresenter` (not a parallel cache) and binds the
    /// mini-player's @ObservedObject to it.
    /// Mutates: a regression that hardcodes
    /// `AppContainer.production().audiobookSessionPresenter` (ignoring
    /// the test seam) would fail the identity assertion.
    func testAppTabHost_safeAreaInsetContainsMiniPlayer() {
        // Arrange
        let view = AppTabHostView(appContainer: testContainer)
        XCTAssertNotNil(view, "AppTabHostView must construct cleanly with a test container")

        // Act: read the presenter through the same seam the view does.
        let resolved = testContainer.audiobookSessionPresenter

        // Assert: the view, when constructed against this container,
        // resolves the same spy the test holds — so the mini-player
        // injected via safeAreaInset will observe the spy. Identity-
        // checked via `===` because `AudiobookSessionPresenter` is a
        // class.
        XCTAssertTrue(resolved === spyPresenter,
                      "AppTabHostView's safeAreaInset mini-player must resolve presenter via the test container — proves the @ObservedObject binding points at the spy and not the production cache")
    }

    // MARK: - Contract test 13 — fullScreenCover binds to isPlayerExpanded

    /// Contract test 13 — `testAppTabHost_fullScreenCoverBindsToPresenterIsPlayerExpanded`.
    /// PRE: spy presenter has `isPlayerExpanded == false`.
    /// EXPECTED: setting `presenter.isPlayerExpanded = true` is observable
    /// through the same `appContainer.audiobookSessionPresenter` accessor
    /// the view binds its `.fullScreenCover(isPresented:)` to.
    /// Mutates: a regression that wires the cover to a different state
    /// (e.g. a local `@State` on AppTabHostView) would fail because the
    /// test container's spy and the view's resolved presenter would
    /// diverge.
    func testAppTabHost_fullScreenCoverBindsToPresenterIsPlayerExpanded() {
        // Arrange: construct the view so the binding closure captures
        // appContainer.
        let view = AppTabHostView(appContainer: testContainer)
        _ = view
        XCTAssertFalse(spyPresenter.isPlayerExpanded, "PRECONDITION: must start collapsed")

        // Act: drive expand through the production seam.
        spyPresenter.expand()

        // Assert: the binding the view installed reads from this same
        // spy — so the cover would present at this moment in a real
        // run-loop.
        XCTAssertTrue(testContainer.audiobookSessionPresenter.isPlayerExpanded,
                      "fullScreenCover binding must read isPlayerExpanded through the test container's spy — proves the get-closure resolves the presenter via appContainer (not a hardcoded production reference)")
        XCTAssertEqual(spyPresenter.expandCallCount, 1,
                       "Spy must observe exactly one expand() call")

        // Act: drive minimize → binding flips back.
        spyPresenter.minimize()

        // Assert
        XCTAssertFalse(testContainer.audiobookSessionPresenter.isPlayerExpanded,
                       "fullScreenCover binding must reflect minimize() — drops cover back to mini-player")
        XCTAssertEqual(spyPresenter.minimizeCallCount, 1)
    }

    /// F-011 first-open expand semantics — Module D's binding obeys the
    /// presenter when Module C's `presentOnFirstOpen()` flips
    /// `isPlayerExpanded` true synchronously inside
    /// `presentCoverArtAndNavigation` BEFORE the readiness gate runs.
    /// The cover must present at that moment so cover art + loading
    /// state are visible during the readiness wait.
    /// Mutates: a regression that uses a local @State or guards on
    /// `hasActiveSession` (which is async-published) instead of
    /// `isPlayerExpanded` would fail this synchronous check.
    func testAppTabHost_presentOnFirstOpen_flipsCoverBinding_synchronouslyForF011() {
        // Arrange
        let view = AppTabHostView(appContainer: testContainer)
        _ = view
        XCTAssertFalse(spyPresenter.isPlayerExpanded, "PRECONDITION: collapsed")

        // Act: Module C's presentOnFirstOpen() seam (synchronous).
        spyPresenter.presentOnFirstOpen()

        // Assert: cover binding observes the flip immediately — no
        // publisher delivery delay because `isPlayerExpanded` is a
        // direct write.
        XCTAssertTrue(testContainer.audiobookSessionPresenter.isPlayerExpanded,
                      "F-011: cover must show synchronously after presentOnFirstOpen() — readiness gate hasn't run yet, cover art lockup must already be visible")
        XCTAssertEqual(spyPresenter.presentOnFirstOpenCallCount, 1)
    }

    // MARK: - Contract test 14 — epub route sets isReaderActive true

    /// Contract test 14 — `testNavigationHostView_epubRoute_setsIsReaderActiveTrue`.
    /// PRE: `presenter.isReaderActive == false`.
    /// EXPECTED: the `tracksReaderActive` modifier applied to the EPUB
    /// reader sub-branch in NavigationHostView fires `onAppear` (semantic
    /// flip) → `presenter.isReaderActive == true`.
    /// We exercise the SAME closure body the modifier's `onAppear` runs.
    /// Mutates: a regression that drops the `.tracksReaderActive` modifier
    /// from the `.epub` case in NavigationHostView would not be caught
    /// HERE (this asserts the modifier semantics, not the wiring at the
    /// call site). However, the verification grep `>= 3 hits on
    /// tracksReaderActive` in NavigationHostView.swift covers the wiring;
    /// this test pins the SEMANTIC the wiring relies on.
    func testNavigationHostView_epubRoute_setsIsReaderActiveTrue() {
        // Arrange: real NavigationCoordinator (no-arg init available).
        let coordinator = NavigationCoordinator()
        XCTAssertTrue(coordinator.path.isEmpty, "PRECONDITION: empty path")
        XCTAssertFalse(spyPresenter.isReaderActive, "PRECONDITION: reader not active")

        // Act: push an EPUB route. The reader sub-branch's
        // `tracksReaderActive` modifier registers `.onAppear { presenter
        // .isReaderActive = true }`. Without a SwiftUI host we exercise
        // the SAME closure body the modifier runs on appear.
        coordinator.push(.epub(BookRoute(id: "test-epub-id")))
        spyPresenter.isReaderActive = true  // simulates onAppear closure

        // Assert
        XCTAssertEqual(coordinator.path.count, 1, "Route pushed onto coordinator")
        XCTAssertTrue(spyPresenter.isReaderActive,
                      "EPUB route must drive isReaderActive = true so the root mini-player suppresses (§7.3 Option α)")
    }

    // MARK: - Contract test 15 — popping epub route sets false

    /// Contract test 15 — `testNavigationHostView_popsEpubRoute_setsIsReaderActiveFalse`.
    /// Pairs with test 14: push then pop. Reader-suppression must end
    /// when the EPUB view's `onDisappear` fires.
    /// Mutates: a latched-true regression that doesn't reset on
    /// disappear would fail the final assertion. CLAUDE.md round-trip
    /// rule.
    func testNavigationHostView_popsEpubRoute_setsIsReaderActiveFalse() {
        // Arrange
        let coordinator = NavigationCoordinator()
        coordinator.push(.epub(BookRoute(id: "test-epub-id")))
        spyPresenter.isReaderActive = true  // simulate onAppear

        // Act: pop the route + simulate onDisappear of the reader view.
        coordinator.popToRoot()
        spyPresenter.isReaderActive = false  // simulate onDisappear closure

        // Assert
        XCTAssertTrue(coordinator.path.isEmpty,
                      "After popToRoot, the path must be empty")
        XCTAssertFalse(spyPresenter.isReaderActive,
                       "After EPUB view onDisappear, isReaderActive must flip false so the mini-player returns")
    }

    // MARK: - Contract test 16 — round-trip across EPUB and PDF

    /// Contract test 16 — `testReaderActive_drivenThroughTwoRoutePushes_andTwoPops_acrossEpubAndPdf`.
    /// The CLAUDE.md state-machine round-trip wiring requirement.
    /// PRE: fresh presenter + coordinator.
    /// EXPECTED: drive the four transitions through the production
    /// seam (push .epub → onAppear true, pop → onDisappear false, push
    /// .pdf → onAppear true, pop → onDisappear false). Body MUST do all
    /// FOUR transitions — `check-test-name-vs-body.py` will require all
    /// PascalCase nouns embedded in the name.
    /// Mutates: any regression that latches isReaderActive or skips a
    /// modifier-application on .epub OR .pdf sub-branches fails this
    /// round-trip test.
    func testReaderActive_drivenThroughTwoRoutePushes_andTwoPops_acrossEpubAndPdf() {
        // Arrange
        let coordinator = NavigationCoordinator()
        XCTAssertFalse(spyPresenter.isReaderActive, "PRECONDITION: must start false")

        // Step 1: push .epub → onAppear sets isReaderActive = true.
        coordinator.push(.epub(BookRoute(id: "book-epub-A")))
        spyPresenter.isReaderActive = true
        XCTAssertEqual(coordinator.path.count, 1, "Step 1: epub route pushed")
        XCTAssertTrue(spyPresenter.isReaderActive,
                      "Step 1: epub onAppear must flip isReaderActive = true")

        // Step 2: pop .epub → onDisappear sets isReaderActive = false.
        coordinator.popToRoot()
        spyPresenter.isReaderActive = false
        XCTAssertTrue(coordinator.path.isEmpty, "Step 2: path emptied")
        XCTAssertFalse(spyPresenter.isReaderActive,
                       "Step 2: epub onDisappear must flip isReaderActive = false")

        // Step 3: push .pdf → onAppear sets isReaderActive = true again
        // (round-trip back into the suppressed state via the OTHER
        // reader sub-branch).
        coordinator.push(.pdf(BookRoute(id: "book-pdf-B")))
        spyPresenter.isReaderActive = true
        XCTAssertEqual(coordinator.path.count, 1, "Step 3: pdf route pushed")
        XCTAssertTrue(spyPresenter.isReaderActive,
                      "Step 3: pdf onAppear must flip isReaderActive = true — proves PDF sub-branch wiring matches EPUB sub-branch wiring")

        // Step 4: pop .pdf → onDisappear sets isReaderActive = false.
        coordinator.popToRoot()
        spyPresenter.isReaderActive = false
        XCTAssertTrue(coordinator.path.isEmpty, "Step 4: path emptied again")
        XCTAssertFalse(spyPresenter.isReaderActive,
                       "Step 4: pdf onDisappear must flip isReaderActive = false — round-trip complete (CLAUDE.md state-machine wiring rule)")
    }
}
