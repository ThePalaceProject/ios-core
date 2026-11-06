//  AudiobookLoaderNowPlayingWriterTests.swift
//
//  PP-5504: pins the loader step that turns off the toolkit's own Now Playing
//  writes, so `NowPlayingCoordinator` is the only writer of the lock screen
//  and CarPlay.

import MediaPlayer
import XCTest
@testable import Palace
@testable import PalaceAudiobookToolkit

@MainActor
final class AudiobookLoaderNowPlayingWriterTests: XCTestCase {

    /// With a toolkit writer left in place, the toolkit's heartbeat and
    /// lifecycle writes race the coordinator's on the lock screen.
    func testLeaveNowPlayingToCoordinator_removesTheToolkitWriter() {
        let host = FakeNowPlayingWriterHost()
        XCTAssertNotNil(host.nowPlayingWriter, "precondition: the toolkit default is a writer")

        AudiobookLoader().leaveNowPlayingToCoordinator(manager: host)

        XCTAssertNil(host.nowPlayingWriter)
    }
}

private final class FakeNowPlayingWriterHost: AudiobookNowPlayingWriterHost {
    var nowPlayingWriter: NowPlayingInfoWriting? = RecordingNowPlayingWriter()
}

private final class RecordingNowPlayingWriter: NowPlayingInfoWriting {
    var nowPlayingInfo: [String: Any]?
    var playbackState: MPNowPlayingPlaybackState = .unknown
}
