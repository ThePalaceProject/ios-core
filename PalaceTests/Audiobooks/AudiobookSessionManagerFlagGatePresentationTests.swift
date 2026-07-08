//
//  AudiobookSessionManagerFlagGatePresentationTests.swift
//  PalaceTests
//
//  Pins the flag-gated presentation decision in
//  `AudiobookSessionManager.presentSession(book:playbackModel:)`:
//
//    - `in_app_playback_nav_enabled` ON  → drive the root-level presenter
//      (`presentOnFirstOpen`), do NOT push an `.audio` route.
//    - `in_app_playback_nav_enabled` OFF → push the legacy full-screen
//      `.audio` route on the coordinator, do NOT touch the presenter.
//
//  The flag is injected via the manager's `inAppPlaybackNavEnabledProvider`
//  closure seam so the decision is exercised without touching UserDefaults
//  / Firebase. Spy strategy mirrors
//  `AudiobookSessionManagerPresenterMigrationTests`: a spy presenter for the
//  ON-branch assertion and a real `NavigationCoordinator` + hub for the
//  OFF-branch observable-state assertion.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceAudiobookToolkit
@testable import Palace

@MainActor
final class AudiobookSessionManagerFlagGatePresentationTests: XCTestCase {

    private var spyPresenter: SpyAudiobookSessionPresenter!
    private var realCoordinator: NavigationCoordinator!
    private var realHub: NavigationCoordinatorHub!

    /// Mutable flag value the manager's injected provider reads each call,
    /// so a single manager instance can be driven through both flag states.
    private var flagEnabled = false

    private var sessionManager: AudiobookSessionManager!
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

        sessionManager = AudiobookSessionManager(
            appContainer: appContainer,
            navigationCoordinatorHubProvider: { [unowned self] in self.realHub },
            audiobookSessionPresenterProvider: { [unowned self] in self.spyPresenter },
            inAppPlaybackNavEnabledProvider: { [unowned self] in self.flagEnabled }
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

    /// Flag ON → the new presentation: presenter is driven, the legacy
    /// coordinator stack stays empty.
    ///
    /// Mutates: flipping the `if inAppPlaybackNavEnabledProvider()` branch
    /// (e.g. negating the guard) would route to the coordinator instead and
    /// fail both assertions.
    func testPresentSession_flagOn_drivesPresenter_andDoesNotPushAudioRoute() {
        flagEnabled = true
        let book = TPPBookMocker.mockBook(distributorType: .OpenAccessAudiobook)
        XCTAssertTrue(realCoordinator.path.isEmpty, "PRECONDITION: coordinator stack starts empty")

        sessionManager.presentSession(book: book, playbackModel: nil)

        XCTAssertEqual(spyPresenter.presentOnFirstOpenCallCount, 1,
                       "Flag ON must drive the root presenter (presentOnFirstOpen) exactly once")
        XCTAssertEqual(spyPresenter.currentBook?.identifier, book.identifier,
                       "Flag ON must adopt the opened book on the presenter")
        XCTAssertTrue(realCoordinator.path.isEmpty,
                      "Flag ON must NOT push an .audio route — the new presentation owns the chrome")
    }

    /// Flag OFF → the original presentation: the legacy `.audio` route is
    /// pushed and the presenter is left untouched.
    ///
    /// Mutates: removing the flag gate so `pushSessionToPresenter` always
    /// runs would leave `path` empty and `presentOnFirstOpenCallCount == 1`,
    /// failing this test — proving the OFF branch restores the original
    /// pushed-route presentation.
    func testPresentSession_flagOff_pushesAudioRoute_andDoesNotDrivePresenter() {
        flagEnabled = false
        let book = TPPBookMocker.mockBook(distributorType: .OpenAccessAudiobook)
        XCTAssertTrue(realCoordinator.path.isEmpty, "PRECONDITION: coordinator stack starts empty")

        sessionManager.presentSession(book: book, playbackModel: nil)

        // `NavigationPath` is opaque (no element inspection / pattern match),
        // so the OFF-branch signal is the push itself: from an empty stack,
        // the only thing `presentSession` pushes is `pushAudioRoute`, so a
        // 0→1 count change is unambiguously the legacy `.audio` route.
        // (`storeAudioModel` is skipped here because the test passes a nil
        // playbackModel — in production the loaded model is always present.)
        XCTAssertEqual(realCoordinator.path.count, 1,
                       "Flag OFF must push the original full-screen .audio route onto the coordinator")
        XCTAssertEqual(spyPresenter.presentOnFirstOpenCallCount, 0,
                       "Flag OFF must NOT drive the root presenter — the presentation must not change while the feature is disabled")
    }

    // MARK: - Dismiss (symmetric with present — must undo what present did)

    /// Flag ON → dismiss clears the presenter and leaves the coordinator
    /// stack untouched (the ON presentation never pushed a route).
    ///
    /// Mutates: if `dismissPlayerOnPhone` dropped the flag gate and always
    /// popped, `clearActiveSessionCallCount` would be 0 and this fails.
    func testDismissPlayerOnPhone_flagOn_clearsPresenter_andDoesNotPopCoordinator() {
        flagEnabled = true
        let book = TPPBookMocker.mockBook(distributorType: .OpenAccessAudiobook)
        // Pre-existing non-audio route — must survive the dismiss (PP-3783).
        realCoordinator.path.append(AppRoute.bookDetail(BookRoute(id: "preexisting")))

        sessionManager.dismissPlayerOnPhone(bookId: book.identifier)

        XCTAssertEqual(spyPresenter.clearActiveSessionCallCount, 1,
                       "Flag ON dismiss must clear the presenter — that IS the dismiss for the root-overlay presentation")
        XCTAssertEqual(realCoordinator.path.count, 1,
                       "Flag ON dismiss must NOT pop the coordinator — the pre-existing route must be preserved")
    }

    /// Flag OFF → dismiss pops the pushed `.audio` route and does NOT clear
    /// the presenter (which was never driven). The underlying non-audio
    /// route must survive — `pop()` removes only the top route (PP-3783).
    ///
    /// Mutates: if `dismissPlayerOnPhone` always cleared the presenter
    /// (dropping the flag gate), the stuck `.audio` route would never pop —
    /// `path.count` would stay 2 and this fails. This is the bug the
    /// architect review caught: a flag-off open with no programmatic dismiss.
    func testDismissPlayerOnPhone_flagOff_popsAudioRoute_preservesUnderlyingRoute() {
        flagEnabled = false
        let book = TPPBookMocker.mockBook(distributorType: .OpenAccessAudiobook)
        // User was in book detail, then opened the audiobook (flag-off push).
        realCoordinator.path.append(AppRoute.bookDetail(BookRoute(id: "preexisting")))
        sessionManager.presentSession(book: book, playbackModel: nil)
        XCTAssertEqual(realCoordinator.path.count, 2,
                       "PRECONDITION: book-detail route + pushed .audio route")

        sessionManager.dismissPlayerOnPhone(bookId: book.identifier)

        XCTAssertEqual(realCoordinator.path.count, 1,
                       "Flag OFF dismiss must pop the .audio route, leaving the underlying book-detail route (PP-3783) — without this the player route stays stuck on screen")
        XCTAssertEqual(spyPresenter.clearActiveSessionCallCount, 0,
                       "Flag OFF dismiss must NOT touch the presenter — it was never driven")
    }
}
