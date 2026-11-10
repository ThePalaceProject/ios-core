//
//  NowPlayingCoordinatorTests.swift
//  PalaceTests
//
//  Tests for NowPlayingCoordinator metadata update logic.
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import MediaPlayer
import XCTest
@testable import Palace
@testable import PalaceAudiobookToolkit

/// SRS: AUDIO-005 -- Now Playing info updates correctly
@MainActor
final class NowPlayingCoordinatorTests: XCTestCase {

    private var coordinator: NowPlayingCoordinator!
    private var infoCenter: SpyNowPlayingInfoCenter!

    override func setUp() {
        super.setUp()
        // The shared system center round-trips through the media service, and
        // on iOS 26.5 an artwork write there can block the test (PP-5523).
        infoCenter = SpyNowPlayingInfoCenter()
        coordinator = NowPlayingCoordinator(
            applicationStateProvider: { .active },
            dryStreamLogger: { _, _ in },
            infoCenter: infoCenter
        )
    }

    override func tearDown() {
        coordinator.clearNowPlaying()
        coordinator = nil
        infoCenter = nil
        super.tearDown()
    }

    // MARK: - updateNowPlaying Tests

    /// SRS: AUDIO-005 -- Now Playing info updates correctly
    func testUpdateNowPlaying_setsInfoCenter() {
        coordinator.updateNowPlaying(
            title: "Chapter 1",
            artist: "Test Book",
            album: "Test Author",
            elapsed: 30.0,
            duration: 300.0,
            isPlaying: true,
            playbackRate: .normalTime
        )

        let info = infoCenter.nowPlayingInfo
        XCTAssertEqual(info?[MPMediaItemPropertyTitle] as? String, "Chapter 1")
        XCTAssertEqual(info?[MPMediaItemPropertyArtist] as? String, "Test Book")
        XCTAssertEqual(info?[MPMediaItemPropertyAlbumTitle] as? String, "Test Author")
    }

    /// SRS: AUDIO-005 -- Now Playing info updates correctly
    func testUpdateNowPlaying_setsElapsedAndDuration() {
        coordinator.updateNowPlaying(
            title: "Chapter 2",
            artist: nil,
            album: nil,
            elapsed: 120.0,
            duration: 600.0,
            isPlaying: true,
            playbackRate: .normalTime
        )

        let info = infoCenter.nowPlayingInfo
        let elapsed = info?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double ?? -1
        let duration = info?[MPMediaItemPropertyPlaybackDuration] as? Double ?? -1

        XCTAssertEqual(elapsed, 120.0, accuracy: 0.01)
        XCTAssertEqual(duration, 600.0, accuracy: 0.01)
    }

    /// SRS: AUDIO-005 -- Now Playing info updates correctly
    func testUpdateNowPlaying_clampsElapsedToNotExceedDuration() {
        coordinator.updateNowPlaying(
            title: "Test",
            artist: nil,
            album: nil,
            elapsed: 500.0,
            duration: 300.0,
            isPlaying: true,
            playbackRate: .normalTime
        )

        let info = infoCenter.nowPlayingInfo
        let elapsed = info?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double ?? -1

        XCTAssertLessThanOrEqual(elapsed, 300.0,
                                  "Elapsed should be clamped to not exceed duration")
    }

    /// SRS: AUDIO-005 -- Now Playing info updates correctly
    func testUpdateNowPlaying_clampsNegativeElapsedToZero() {
        coordinator.updateNowPlaying(
            title: "Test",
            artist: nil,
            album: nil,
            elapsed: -10.0,
            duration: 300.0,
            isPlaying: true,
            playbackRate: .normalTime
        )

        let info = infoCenter.nowPlayingInfo
        let elapsed = info?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double ?? -1

        XCTAssertGreaterThanOrEqual(elapsed, 0.0,
                                     "Elapsed should not be negative")
    }

    /// SRS: AUDIO-005 -- Now Playing info updates correctly
    func testUpdateNowPlaying_ensuresDurationIsAtLeastOne() {
        coordinator.updateNowPlaying(
            title: "Test",
            artist: nil,
            album: nil,
            elapsed: 0.0,
            duration: 0.0,
            isPlaying: false,
            playbackRate: .normalTime
        )

        let info = infoCenter.nowPlayingInfo
        let duration = info?[MPMediaItemPropertyPlaybackDuration] as? Double ?? -1

        XCTAssertGreaterThanOrEqual(duration, 1.0,
                                     "Duration should be at least 1.0 to avoid division by zero")
    }

    /// SRS: AUDIO-005 -- Now Playing info updates correctly
    func testUpdateNowPlaying_setsPlaybackRate_whenPlaying() {
        coordinator.updateNowPlaying(
            title: "Test",
            artist: nil,
            album: nil,
            elapsed: 0.0,
            duration: 100.0,
            isPlaying: true,
            playbackRate: .oneAndAHalfTime
        )

        let info = infoCenter.nowPlayingInfo
        let rate = info?[MPNowPlayingInfoPropertyPlaybackRate] as? Double ?? -1

        XCTAssertGreaterThan(rate, 0.0,
                              "Playback rate should be positive when playing")
    }

    /// SRS: AUDIO-005 -- Now Playing info updates correctly
    func testUpdateNowPlaying_setsZeroPlaybackRate_whenPaused() {
        coordinator.updateNowPlaying(
            title: "Test",
            artist: nil,
            album: nil,
            elapsed: 0.0,
            duration: 100.0,
            isPlaying: false,
            playbackRate: .normalTime
        )

        let info = infoCenter.nowPlayingInfo
        let rate = info?[MPNowPlayingInfoPropertyPlaybackRate] as? Double ?? -1

        XCTAssertEqual(rate, 0.0, accuracy: 0.01,
                        "Playback rate should be 0 when paused")
    }

    /// SRS: AUDIO-005 -- Now Playing info updates correctly
    func testUpdateNowPlaying_setsMediaType_toAudioBook() {
        coordinator.updateNowPlaying(
            title: "Test",
            artist: nil,
            album: nil,
            elapsed: 0.0,
            duration: 100.0,
            isPlaying: false,
            playbackRate: .normalTime
        )

        let info = infoCenter.nowPlayingInfo
        let mediaType = info?[MPMediaItemPropertyMediaType] as? UInt

        XCTAssertEqual(mediaType, MPMediaType.audioBook.rawValue,
                        "Media type should be audioBook for CarPlay")
    }

    // MARK: - setPlaybackState Tests

    /// SRS: AUDIO-005 -- Now Playing info updates correctly
    func testSetPlaybackState_playing_setsCorrectPlaybackState() {
        // Seed initial info
        coordinator.updateNowPlaying(
            title: "Test", artist: nil, album: nil,
            elapsed: 10, duration: 100, isPlaying: false, playbackRate: .normalTime
        )

        coordinator.setPlaybackState(playing: true)

        let playbackState = infoCenter.playbackState
        XCTAssertEqual(playbackState, .playing)
    }

    /// SRS: AUDIO-005 -- Now Playing info updates correctly
    func testSetPlaybackState_paused_setsCorrectPlaybackState() {
        coordinator.updateNowPlaying(
            title: "Test", artist: nil, album: nil,
            elapsed: 10, duration: 100, isPlaying: true, playbackRate: .normalTime
        )

        coordinator.setPlaybackState(playing: false)

        let playbackState = infoCenter.playbackState
        XCTAssertEqual(playbackState, .paused)
    }

    /// SRS: AUDIO-005 -- Now Playing info updates correctly
    func testSetPlaybackState_playing_setsNonZeroRate() {
        coordinator.updateNowPlaying(
            title: "Test", artist: nil, album: nil,
            elapsed: 10, duration: 100, isPlaying: true, playbackRate: .normalTime
        )

        coordinator.setPlaybackState(playing: true)

        let info = infoCenter.nowPlayingInfo
        let rate = info?[MPNowPlayingInfoPropertyPlaybackRate] as? Double ?? 0

        XCTAssertGreaterThan(rate, 0.0, "Rate should be positive when playing")
    }

    /// SRS: AUDIO-005 -- Now Playing info updates correctly
    func testSetPlaybackState_paused_setsZeroRate() {
        coordinator.updateNowPlaying(
            title: "Test", artist: nil, album: nil,
            elapsed: 10, duration: 100, isPlaying: true, playbackRate: .normalTime
        )

        coordinator.setPlaybackState(playing: false)

        let info = infoCenter.nowPlayingInfo
        let rate = info?[MPNowPlayingInfoPropertyPlaybackRate] as? Double ?? -1

        XCTAssertEqual(rate, 0.0, accuracy: 0.01, "Rate should be 0 when paused")
    }

    // MARK: - updatePlaybackRate Tests

    /// SRS: AUDIO-005 -- Now Playing info updates correctly
    func testUpdatePlaybackRate_updatesDefaultRate() {
        coordinator.updateNowPlaying(
            title: "Test", artist: nil, album: nil,
            elapsed: 10, duration: 100, isPlaying: true, playbackRate: .normalTime
        )

        coordinator.updatePlaybackRate(.doubleTime)

        let info = infoCenter.nowPlayingInfo
        let defaultRate = info?[MPNowPlayingInfoPropertyDefaultPlaybackRate] as? Double ?? -1
        let rateValue = Double(PlaybackRate.convert(rate: .doubleTime))

        XCTAssertEqual(defaultRate, rateValue, accuracy: 0.01,
                        "Default rate should match new rate")
    }

    // MARK: - updateArtwork Tests

    /// SRS: AUDIO-005 -- Now Playing info updates correctly
    func testUpdateArtwork_setsArtworkInInfo() {
        coordinator.updateNowPlaying(
            title: "Test", artist: nil, album: nil,
            elapsed: 10, duration: 100, isPlaying: false, playbackRate: .normalTime
        )

        let testImage = UIImage(systemName: "book")!
        coordinator.updateArtwork(testImage)

        let info = infoCenter.nowPlayingInfo
        XCTAssertNotNil(info?[MPMediaItemPropertyArtwork],
                         "Artwork should be set in Now Playing info")
    }

    /// SRS: AUDIO-005 -- Now Playing info updates correctly
    func testUpdateArtwork_nil_clearsArtwork() {
        let testImage = UIImage(systemName: "book")!
        coordinator.updateArtwork(testImage)
        coordinator.updateArtwork(nil)

        // After clearing, artwork should not be added to subsequent updates
        coordinator.updateNowPlaying(
            title: "Test", artist: nil, album: nil,
            elapsed: 0, duration: 100, isPlaying: false, playbackRate: .normalTime
        )

        let info = infoCenter.nowPlayingInfo
        XCTAssertNil(info?[MPMediaItemPropertyArtwork],
                      "Artwork should be nil after clearing")
    }

    // MARK: - clearNowPlaying Tests

    /// SRS: AUDIO-005 -- Now Playing info updates correctly
    func testClearNowPlaying_removesAllInfo() {
        coordinator.updateNowPlaying(
            title: "Test", artist: "Artist", album: "Album",
            elapsed: 50, duration: 300, isPlaying: true, playbackRate: .normalTime
        )

        coordinator.clearNowPlaying()

        let info = infoCenter.nowPlayingInfo
        XCTAssertNil(info, "Now Playing info should be nil after clearing")
    }

    /// SRS: AUDIO-005 -- Now Playing info updates correctly
    func testClearNowPlaying_setsStoppedState() {
        coordinator.updateNowPlaying(
            title: "Test", artist: nil, album: nil,
            elapsed: 0, duration: 100, isPlaying: true, playbackRate: .normalTime
        )

        coordinator.clearNowPlaying()

        let state = infoCenter.playbackState
        XCTAssertEqual(state, .stopped)
    }

    // MARK: - Rapid updates

    /// SRS: AUDIO-005 -- Now Playing info updates correctly
    func testUpdateNowPlaying_rapidUpdates_lastOneWins() {
        for i in 0..<10 {
            coordinator.updateNowPlaying(
                title: "Chapter \(i)",
                artist: nil,
                album: nil,
                elapsed: Double(i * 10),
                duration: 300.0,
                isPlaying: true,
                playbackRate: .normalTime
            )
        }

        let title = infoCenter.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String
        XCTAssertEqual(title, "Chapter 9", "each title change is written at once, so the latest is shown")
    }

    /// SRS: AUDIO-005 -- Now Playing info updates correctly
    func testUpdateNowPlaying_preservesArtwork_acrossUpdates() {
        let testImage = UIImage(systemName: "book")!
        coordinator.updateArtwork(testImage)

        coordinator.updateNowPlaying(
            title: "Chapter After Artwork",
            artist: nil,
            album: nil,
            elapsed: 0,
            duration: 100,
            isPlaying: false,
            playbackRate: .normalTime
        )

        let info = infoCenter.nowPlayingInfo
        XCTAssertNotNil(info?[MPMediaItemPropertyArtwork],
                         "Artwork should be preserved across updateNowPlaying calls")
    }
}
