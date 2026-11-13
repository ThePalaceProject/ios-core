//
//  AudiobookSamplePlayerTests.swift
//  PalaceTests
//
//  The preview's skip-back moves the playhead 30 s back and keeps the
//  play/pause state; it used to restart the preview from the start (PP-4027).
//

import XCTest
@testable import Palace

/// Records what the sample player asks of the audio engine.
private final class FakeSampleAudioEngine: SampleAudioEngine {
    var currentTime: TimeInterval = 0
    let duration: TimeInterval
    private(set) var playCount = 0
    private(set) var pauseCount = 0

    init(duration: TimeInterval) { self.duration = duration }

    @discardableResult func play() -> Bool { playCount += 1; return true }
    func pause() { pauseCount += 1 }
    func stop() {}
}

private struct StubSample: Sample {
    let url = URL(string: "https://example.org/preview.mp3")!
    let type = SampleType.overdriveAudiobookMpeg
    func fetchSample() async -> NYPLResult<Data> { .success(Data([0x1]), nil) }
}

@MainActor
final class AudiobookSamplePlayerTests: XCTestCase {

    private var engine: FakeSampleAudioEngine!
    private var player: AudiobookSamplePlayer!

    override func setUp() async throws {
        try await super.setUp()
        let engine = FakeSampleAudioEngine(duration: 120)
        self.engine = engine
        player = AudiobookSamplePlayer(sample: StubSample(), makeEngine: { _, _ in engine })
        await awaitConditionAsync { self.player.state == .playing }
    }

    override func tearDown() async throws {
        player = nil
        engine = nil
        try await super.tearDown()
    }

    func testGoBack_whilePlaying_movesThePlayhead30sBackAndKeepsPlaying() {
        engine.currentTime = 45

        player.goBack()

        XCTAssertEqual(engine.currentTime, 15)
        XCTAssertEqual(player.remainingTime, 105)
        XCTAssertEqual(player.state, .playing)
        XCTAssertEqual(engine.playCount, 1, "skip-back must not start playback again")
    }

    func testGoBack_whilePaused_movesThePlayheadAndStaysPaused() {
        player.pauseAudiobook()
        engine.currentTime = 70

        player.goBack()

        XCTAssertEqual(engine.currentTime, 40)
        XCTAssertEqual(player.state, .paused)
        XCTAssertEqual(engine.playCount, 1, "skip-back while paused must not start playback")
    }

    func testGoBack_withinTheFirst30s_stopsAtTheStart() {
        engine.currentTime = 10

        player.goBack()

        XCTAssertEqual(engine.currentTime, 0)
        XCTAssertEqual(player.remainingTime, 120)
    }
}
