//  AudiobookLoaderNowPlayingWriterTests.swift
//
//  PP-5504: the manager the loader builds leaves Now Playing to
//  `NowPlayingCoordinator`, so the coordinator is the only writer of the lock
//  screen and CarPlay.

import XCTest
@testable import Palace
@testable import PalaceAudiobookToolkit

@MainActor
final class AudiobookLoaderNowPlayingWriterTests: XCTestCase {

    /// With a toolkit writer left in place, the toolkit's heartbeat and
    /// lifecycle writes race the coordinator's on the lock screen.
    func testMakeManager_leavesNowPlayingToTheCoordinator() throws {
        let manifest = try Manifest.from(jsonFileName: ManifestJSON.snowcrash.rawValue,
                                         bundle: Bundle(for: type(of: self)))
        let audiobook = try XCTUnwrap(AudiobookFactory.audiobook(
            for: manifest,
            bookIdentifier: "AudiobookLoaderNowPlayingWriterTests",
            decryptor: nil,
            token: nil,
            fulfillURL: nil
        ))
        let networkService = DefaultAudiobookNetworkService(
            tracks: audiobook.tableOfContents.allTracks,
            decryptor: nil
        )

        let manager = AudiobookLoader.makeManager(
            metadata: AudiobookMetadata(title: "Snow Crash", authors: ["Author"]),
            audiobook: audiobook,
            networkService: networkService,
            playbackTrackerDelegate: nil
        )
        defer { manager.unload() }

        XCTAssertNil(manager.nowPlayingWriter)
    }
}
