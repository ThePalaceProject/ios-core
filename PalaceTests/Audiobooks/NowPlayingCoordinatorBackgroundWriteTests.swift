//  NowPlayingCoordinatorBackgroundWriteTests.swift
//
//  PP-4970: in the background, playback ticks arrive four times a second. The
//  system extrapolates elapsed time from the playback rate, so a background
//  write is only needed when something it cannot extrapolate has changed.

import MediaPlayer
import UIKit
import XCTest
@testable import Palace
@testable import PalaceAudiobookToolkit

/// Records every write the coordinator makes instead of touching the shared
/// system Now Playing center. Only used from the main actor, like the
/// coordinator that writes to it.
final class SpyNowPlayingInfoCenter: NowPlayingInfoCenterWriting, @unchecked Sendable {
    private(set) var infoWrites: [[String: Any]?] = []
    private(set) var stateWrites: [MPNowPlayingPlaybackState] = []

    var nowPlayingInfo: [String: Any]? {
        get { infoWrites.last ?? nil }
        set { infoWrites.append(newValue) }
    }

    var playbackState: MPNowPlayingPlaybackState = .unknown {
        didSet { stateWrites.append(playbackState) }
    }
}

@MainActor
final class NowPlayingCoordinatorBackgroundWriteTests: XCTestCase {

    private var coordinator: NowPlayingCoordinator!
    private var infoCenter: SpyNowPlayingInfoCenter!
    private let appState = LockIsolated<UIApplication.State>(.background)
    private let clock = LockIsolated<Date>(Date(timeIntervalSinceReferenceDate: 1_000_000))

    override func setUp() {
        super.setUp()
        appState.value = .background
        clock.value = Date(timeIntervalSinceReferenceDate: 1_000_000)
        infoCenter = SpyNowPlayingInfoCenter()
        coordinator = NowPlayingCoordinator(
            applicationStateProvider: { [appState] in appState.value },
            dryStreamLogger: { _, _ in },
            now: { [clock] in clock.value },
            infoCenter: infoCenter
        )
    }

    override func tearDown() {
        coordinator = nil
        infoCenter = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func update(
        title: String = "Chapter 1",
        elapsed: TimeInterval,
        duration: TimeInterval = 1_800,
        isPlaying: Bool = true,
        rate: PlaybackRate = .normalTime
    ) {
        coordinator.updateNowPlaying(
            title: title, artist: "Book", album: "Author",
            elapsed: elapsed, duration: duration, isPlaying: isPlaying, playbackRate: rate
        )
    }

    /// Advances the injected clock and sends a tick whose elapsed time moved
    /// by the same amount, as steady 1x playback does.
    private func steadyTicks(from start: TimeInterval, count: Int, step: TimeInterval = 0.25) -> TimeInterval {
        var elapsed = start
        for _ in 0..<count {
            clock.withValue { $0 = $0.addingTimeInterval(step) }
            elapsed += step
            update(elapsed: elapsed)
        }
        return elapsed
    }

    private var lastWrittenElapsed: Double? {
        infoCenter.nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double
    }

    // MARK: - Steady playback

    func testBackground_steadyPlayback_writesOnceThenSkipsExtrapolatedTicks() {
        update(elapsed: 100)

        _ = steadyTicks(from: 100, count: 20)

        XCTAssertEqual(infoCenter.infoWrites.count, 1, "ticks the lock screen can extrapolate must not be written")
    }

    /// A keep-alive write still lands well inside the 30 s dry-stream alarm.
    func testBackground_steadyPlayback_writesKeepAliveAfterTenSeconds() {
        update(elapsed: 100)
        _ = steadyTicks(from: 100, count: 39)
        XCTAssertEqual(infoCenter.infoWrites.count, 1, "PRECONDITION: 9.75 s of steady ticks write nothing")

        let elapsed = steadyTicks(from: 109.75, count: 1)

        XCTAssertEqual(infoCenter.infoWrites.count, 2)
        XCTAssertEqual(lastWrittenElapsed ?? -1, elapsed, accuracy: 0.001)
    }

    func testBackground_pausedWithUnchangedElapsed_writesOnce() {
        update(elapsed: 100, isPlaying: false)
        for _ in 0..<8 {
            clock.withValue { $0 = $0.addingTimeInterval(0.25) }
            update(elapsed: 100, isPlaying: false)
        }

        XCTAssertEqual(infoCenter.infoWrites.count, 1)
    }

    // MARK: - Changes the lock screen cannot extrapolate

    func testBackground_seekForward_writesImmediately() {
        update(elapsed: 100)
        clock.withValue { $0 = $0.addingTimeInterval(0.25) }

        update(elapsed: 130.25)

        XCTAssertEqual(infoCenter.infoWrites.count, 2)
        XCTAssertEqual(lastWrittenElapsed ?? -1, 130.25, accuracy: 0.001)
    }

    func testBackground_seekBackward_writesImmediately() {
        update(elapsed: 100)
        clock.withValue { $0 = $0.addingTimeInterval(0.25) }

        update(elapsed: 70.25)

        XCTAssertEqual(infoCenter.infoWrites.count, 2)
    }

    /// Drift within one second is timer jitter, not a seek.
    func testBackground_driftWithinOneSecond_isNotWritten() {
        update(elapsed: 100)
        clock.withValue { $0 = $0.addingTimeInterval(0.25) }

        update(elapsed: 101.2)

        XCTAssertEqual(infoCenter.infoWrites.count, 1)
    }

    /// The tolerance is exclusive: a drift of exactly one second is still jitter.
    func testBackground_driftOfExactlyOneSecond_isNotWritten() {
        update(elapsed: 100)
        clock.withValue { $0 = $0.addingTimeInterval(0.25) }

        update(elapsed: 101.25)

        XCTAssertEqual(infoCenter.infoWrites.count, 1)
    }

    func testBackground_driftJustOverOneSecond_isWritten() {
        update(elapsed: 100)
        clock.withValue { $0 = $0.addingTimeInterval(0.25) }

        update(elapsed: 101.3)

        XCTAssertEqual(infoCenter.infoWrites.count, 2)
    }

    func testBackground_chapterChange_writesImmediately() {
        update(elapsed: 100)
        clock.withValue { $0 = $0.addingTimeInterval(0.25) }

        update(title: "Chapter 2", elapsed: 0)

        XCTAssertEqual(infoCenter.infoWrites.count, 2)
        XCTAssertEqual(infoCenter.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String, "Chapter 2")
    }

    func testBackground_durationChange_writesImmediately() {
        update(elapsed: 100)
        clock.withValue { $0 = $0.addingTimeInterval(0.25) }

        update(elapsed: 100.25, duration: 2_400)

        XCTAssertEqual(infoCenter.infoWrites.count, 2)
    }

    func testBackground_pause_writesImmediately() {
        update(elapsed: 100)
        clock.withValue { $0 = $0.addingTimeInterval(0.25) }

        update(elapsed: 100.25, isPlaying: false)

        XCTAssertEqual(infoCenter.infoWrites.count, 2)
        XCTAssertEqual(infoCenter.playbackState, .paused)
    }

    func testBackground_rateChange_writesImmediately() {
        update(elapsed: 100)
        clock.withValue { $0 = $0.addingTimeInterval(0.25) }

        update(elapsed: 100.25, rate: .doubleTime)

        XCTAssertEqual(infoCenter.infoWrites.count, 2)
    }

    /// At 2x the position advances twice as fast; extrapolation must use the rate.
    func testBackground_steadyPlaybackAtDoubleSpeed_isExtrapolatedWithRate() {
        update(elapsed: 100, rate: .doubleTime)
        var elapsed = 100.0
        for _ in 0..<8 {
            clock.withValue { $0 = $0.addingTimeInterval(0.25) }
            elapsed += 0.5
            update(elapsed: elapsed, rate: .doubleTime)
        }

        XCTAssertEqual(infoCenter.infoWrites.count, 1)
    }

    func testBackground_artistChange_writesImmediately() {
        update(elapsed: 100)
        clock.withValue { $0 = $0.addingTimeInterval(0.25) }

        coordinator.updateNowPlaying(
            title: "Chapter 1", artist: "Other Book", album: "Author",
            elapsed: 100.25, duration: 1_800, isPlaying: true, playbackRate: .normalTime
        )

        XCTAssertEqual(infoCenter.infoWrites.count, 2)
    }

    func testBackground_albumChange_writesImmediately() {
        update(elapsed: 100)
        clock.withValue { $0 = $0.addingTimeInterval(0.25) }

        coordinator.updateNowPlaying(
            title: "Chapter 1", artist: "Book", album: "Other Author",
            elapsed: 100.25, duration: 1_800, isPlaying: true, playbackRate: .normalTime
        )

        XCTAssertEqual(infoCenter.infoWrites.count, 2)
    }

    // MARK: - Direct writers carry the latest position

    /// A pause from the lock screen, CarPlay or headphones writes the stored
    /// info directly; it must carry the latest tick, not the last written one.
    func testBackground_pauseAfterSkippedTicks_writesLatestElapsed() {
        update(elapsed: 100)
        let latest = steadyTicks(from: 100, count: 8)
        XCTAssertEqual(infoCenter.infoWrites.count, 1, "PRECONDITION: steady ticks were skipped")

        coordinator.setPlaybackState(playing: false)

        XCTAssertEqual(lastWrittenElapsed ?? -1, latest, accuracy: 0.001)
        XCTAssertEqual(
            infoCenter.nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 0
        )
    }

    func testBackground_rateChangeAfterSkippedTicks_writesLatestElapsed() {
        update(elapsed: 100)
        infoCenter.playbackState = .playing
        let latest = steadyTicks(from: 100, count: 8)

        coordinator.updatePlaybackRate(.doubleTime)

        XCTAssertEqual(lastWrittenElapsed ?? -1, latest, accuracy: 0.001)
    }

    /// After a direct rate change, ticks at the new rate are extrapolated from it.
    func testBackground_ticksAfterDirectRateChange_areExtrapolatedAtNewRate() {
        update(elapsed: 100)
        infoCenter.playbackState = .playing
        coordinator.updatePlaybackRate(.doubleTime)
        let writesAfterRateChange = infoCenter.infoWrites.count
        var elapsed = 100.0
        for _ in 0..<8 {
            clock.withValue { $0 = $0.addingTimeInterval(0.25) }
            elapsed += 0.5
            update(elapsed: elapsed, rate: .doubleTime)
        }

        XCTAssertEqual(infoCenter.infoWrites.count, writesAfterRateChange)
    }

    /// After a direct pause, paused ticks match what was just written.
    func testBackground_pausedTicksAfterDirectPause_areNotWritten() {
        update(elapsed: 100)
        let latest = steadyTicks(from: 100, count: 4)
        coordinator.setPlaybackState(playing: false)
        let writesAfterPause = infoCenter.infoWrites.count

        for _ in 0..<8 {
            clock.withValue { $0 = $0.addingTimeInterval(0.25) }
            update(elapsed: latest, isPlaying: false)
        }

        XCTAssertEqual(infoCenter.infoWrites.count, writesAfterPause)
    }

    /// The keep-alive interval counts from the most recent write of any kind.
    func testBackground_keepAlive_countsFromArtworkWrite() {
        update(elapsed: 100)
        let atArtwork = steadyTicks(from: 100, count: 8)
        coordinator.updateArtwork(UIImage())
        let writesAfterArtwork = infoCenter.infoWrites.count

        _ = steadyTicks(from: atArtwork, count: 36)

        XCTAssertEqual(infoCenter.infoWrites.count, writesAfterArtwork,
                       "11 s after the first write but 9 s after the artwork write")
    }

    func testBackground_artworkUpdateAfterSkippedTicks_writesLatestElapsed() {
        update(elapsed: 100)
        let latest = steadyTicks(from: 100, count: 8)

        coordinator.updateArtwork(UIImage())

        XCTAssertEqual(lastWrittenElapsed ?? -1, latest, accuracy: 0.001)
    }

    // MARK: - Foreground

    func testActive_firstWrite_isApplied() {
        appState.value = .active

        update(elapsed: 100)

        XCTAssertEqual(infoCenter.infoWrites.count, 1)
    }

    /// Foreground ticks the system can extrapolate are not written either, so a
    /// patron with the app open does not cost a Now Playing write per tick.
    func testActive_steadyPlayback_writesOnceThenSkipsExtrapolatedTicks() {
        appState.value = .active
        update(elapsed: 100)

        _ = steadyTicks(from: 100, count: 20)

        XCTAssertEqual(infoCenter.infoWrites.count, 1)
    }

    func testActive_steadyPlayback_writesKeepAliveAfterTenSeconds() {
        appState.value = .active
        update(elapsed: 100)

        _ = steadyTicks(from: 100, count: 40)

        XCTAssertEqual(infoCenter.infoWrites.count, 2)
    }

    /// A chapter change is written on the tick that carries it, however soon
    /// after the last write, so CarPlay does not show the old chapter.
    func testActive_chapterChangeHalfASecondAfterAWrite_isWrittenAtOnce() {
        appState.value = .active
        update(elapsed: 100)
        clock.withValue { $0 = $0.addingTimeInterval(0.5) }

        update(title: "Chapter 2", elapsed: 0)

        XCTAssertEqual(infoCenter.infoWrites.count, 2)
        XCTAssertEqual(infoCenter.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String, "Chapter 2")
    }

    func testActive_seekHalfASecondAfterAWrite_isWrittenAtOnce() {
        appState.value = .active
        update(elapsed: 100)
        clock.withValue { $0 = $0.addingTimeInterval(0.5) }

        update(elapsed: 400)

        XCTAssertEqual(infoCenter.infoWrites.count, 2)
        XCTAssertEqual(lastWrittenElapsed ?? -1, 400, accuracy: 0.001)
    }

    /// A pause after skipped ticks writes the latest position, not the one
    /// from the last write, and shows the lock screen as paused.
    func testActive_pauseAfterSkippedTicks_writesTheLatestPositionAsPaused() {
        appState.value = .active
        update(elapsed: 100)
        let latest = steadyTicks(from: 100, count: 8)

        coordinator.setPlaybackState(playing: false)

        XCTAssertEqual(infoCenter.playbackState, .paused)
        XCTAssertEqual(infoCenter.nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 0.0)
        XCTAssertEqual(lastWrittenElapsed ?? -1, latest, accuracy: 0.001)
    }

    /// A paused tick, then a resumed one: each play-state change is written.
    func testActive_pauseThenResumeTicks_writeEachStateChange() {
        appState.value = .active
        update(elapsed: 100)
        clock.withValue { $0 = $0.addingTimeInterval(0.25) }

        update(elapsed: 100.25, isPlaying: false)
        clock.withValue { $0 = $0.addingTimeInterval(0.25) }
        update(elapsed: 100.25, isPlaying: true)

        XCTAssertEqual(infoCenter.infoWrites.count, 3)
        XCTAssertEqual(infoCenter.stateWrites.suffix(2), [.paused, .playing])
    }

    /// A chapter change on the first background tick after a foreground write
    /// is written, whatever the foreground last wrote.
    func testBackground_firstTickAfterForegroundWrite_withChangedTitle_isWritten() {
        appState.value = .active
        update(elapsed: 100)
        appState.value = .background
        clock.withValue { $0 = $0.addingTimeInterval(0.25) }

        update(title: "Chapter 2", elapsed: 0)

        XCTAssertEqual(infoCenter.infoWrites.count, 2)
    }
}
