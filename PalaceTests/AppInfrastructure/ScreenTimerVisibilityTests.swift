//
//  ScreenTimerVisibilityTests.swift
//  PalaceTests
//
//  Screen-update timers ask ActivityPolicy (PP-5508): the player's audio-wait
//  ticker and the preview countdown stop while nothing shows them and resume
//  when the app is visible again.
//

import Combine
import XCTest
@testable import Palace

@MainActor
final class ScreenTimerVisibilityTests: XCTestCase {

    private var scheduler: FakeActivityTickScheduler!
    private var policy: ActivityPolicy!
    private var cancellables: Set<AnyCancellable> = []

    override func setUp() {
        super.setUp()
        scheduler = FakeActivityTickScheduler()
        policy = makeTestActivityPolicy(scheduler: scheduler)
    }

    override func tearDown() {
        cancellables.removeAll()
        scheduler = nil
        policy = nil
        super.tearDown()
    }

    // MARK: - Player audio-wait ticker

    private func makePresenterWithMountedPlayer() -> (AudiobookSessionPresenter, () -> Int) {
        let presenter = AudiobookSessionPresenter(
            sessionManager: SpyShimSession(),
            contentIsLocal: { _ in true },
            activityPolicy: policy
        )
        var received = 0
        presenter.audioWaitTicks.sink { _ in received += 1 }.store(in: &cancellables)
        presenter.presentLoadingShell(for: TPPBookMocker.mockBook(title: "Ticker", authors: "Author"), coverImage: nil)
        return (presenter, { received })
    }

    func testAudioWaitTicks_playerMountedAndAppVisible_deliverAtTheUITickInterval() {
        policy.setScene(.active)
        let (presenter, received) = makePresenterWithMountedPlayer()

        scheduler.fireAll()

        XCTAssertEqual(scheduler.armedIntervals, [ActivityRules.uiTickInterval])
        XCTAssertEqual(received(), 1)
        withExtendedLifetime(presenter) {}
    }

    func testAudioWaitTicks_appGoesToBackground_pauseAndResumeWhenVisible() {
        policy.setScene(.active)
        let (presenter, received) = makePresenterWithMountedPlayer()

        policy.setScene(.background)
        scheduler.fireAll()
        XCTAssertEqual(received(), 0, "no tick while the app is in the background")

        policy.setScene(.active)
        scheduler.fireAll()
        XCTAssertEqual(received(), 1, "ticks resume when the app is visible again")
        XCTAssertEqual(scheduler.armedIntervals.count, 2)
        withExtendedLifetime(presenter) {}
    }

    func testAudioWaitTicks_readerCoversPlayer_pauseUntilReaderCloses() {
        policy.setScene(.active)
        let (presenter, received) = makePresenterWithMountedPlayer()

        presenter.isReaderActive = true
        scheduler.fireAll()
        XCTAssertEqual(received(), 0)

        presenter.isReaderActive = false
        scheduler.fireAll()
        XCTAssertEqual(received(), 1)
    }

    func testAudioWaitTicks_playerClosed_stop() {
        policy.setScene(.active)
        let (presenter, received) = makePresenterWithMountedPlayer()

        presenter.clearActiveSession()
        scheduler.fireAll()

        XCTAssertEqual(received(), 0)
        XCTAssertEqual(scheduler.armedIntervals.count, 1, "closing the player arms nothing new")
    }

    func testAudioWaitTicks_onlyCarPlayVisible_armNoTimer() {
        policy.setCarPlayConnected(true)
        let (presenter, received) = makePresenterWithMountedPlayer()

        scheduler.fireAll()

        XCTAssertEqual(scheduler.armedIntervals, [], "CarPlay does not draw the phone player")
        XCTAssertEqual(received(), 0)
        withExtendedLifetime(presenter) {}
    }

    // MARK: - Preview countdown

    private final class FakeEngine: SampleAudioEngine {
        var currentTime: TimeInterval = 0
        let duration: TimeInterval = 120
        @discardableResult func play() -> Bool { true }
        func pause() {}
        func stop() {}
    }

    private struct StubSample: Sample {
        let url = URL(string: "https://example.org/preview.mp3")!
        let type = SampleType.overdriveAudiobookMpeg
        func fetchSample() async -> NYPLResult<Data> { .success(Data([0x1]), nil) }
    }

    private func makePlayingSamplePlayer(engine: FakeEngine) async -> AudiobookSamplePlayer {
        let player = AudiobookSamplePlayer(sample: StubSample(), activityPolicy: policy, makeEngine: { _, _ in engine })
        await awaitPublishedAsync(player.$state) { $0 == .playing }
        return player
    }

    func testPreviewCountdown_appGoesToBackground_pausesAndResumesWhenVisible() async {
        policy.setScene(.active)
        let engine = FakeEngine()
        let player = await makePlayingSamplePlayer(engine: engine)
        engine.currentTime = 30
        scheduler.fireAll()
        XCTAssertEqual(player.remainingTime, 90)

        policy.setScene(.background)
        engine.currentTime = 50
        scheduler.fireAll()
        XCTAssertEqual(player.remainingTime, 90, "the countdown does not update while hidden")

        policy.setScene(.active)
        scheduler.fireAll()
        XCTAssertEqual(player.remainingTime, 70)
        XCTAssertEqual(scheduler.armedIntervals, [1, 1])
    }

    func testPreviewCountdown_onlyCarPlayVisible_armsNoTimer() async {
        policy.setCarPlayConnected(true)
        let engine = FakeEngine()
        let player = await makePlayingSamplePlayer(engine: engine)
        engine.currentTime = 30

        scheduler.fireAll()

        XCTAssertEqual(scheduler.armedIntervals, [])
        XCTAssertEqual(player.remainingTime, 0)
    }
}
