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

    override func setUp() async throws {
        try await super.setUp()
        spyPresenter = SpyAudiobookSessionPresenter()
        realCoordinator = NavigationCoordinator()
        realHub = NavigationCoordinatorHub()
        realHub.coordinator = realCoordinator

        sessionManager = AudiobookSessionManager(
            appContainer: AppContainer.production(),
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
}
