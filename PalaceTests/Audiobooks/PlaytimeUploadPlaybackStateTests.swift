//
//  PlaytimeUploadPlaybackStateTests.swift
//  PalaceTests
//
//  Which session states let background play-time ticks run (PP-5508).
//

import Combine
import XCTest
@testable import Palace

@MainActor
final class PlaytimeUploadPlaybackStateTests: XCTestCase {

    func testIsPlaying_OnlyThePlayingStateCountsAsPlaying() {
        let cases: [(AudiobookSessionState, Bool)] = [
            (.playing(bookId: "b"), true),
            (.paused(bookId: "b"), false),
            (.loading(bookId: "b"), false),
            (.idle, false),
            (.error(bookId: "b", message: "m"), false),
        ]
        for (state, expected) in cases {
            XCTAssertEqual(PlaytimeUploadSchedule.isPlaying(state), expected, "\(state)")
        }
    }

    func testIsAudioPlaying_StartsWithTheSessionValueThenFollowsPublishedStates() {
        let session = SpyShimSession()
        session.isPlaying = true
        var received: [Bool] = []
        let subscription = PlaytimeUploadSchedule.isAudioPlaying(from: session)
            .sink { received.append($0) }

        session.playbackStatePublisher.send(.paused(bookId: "b"))
        session.playbackStatePublisher.send(.loading(bookId: "b"))
        session.playbackStatePublisher.send(.playing(bookId: "b"))

        XCTAssertEqual(received, [true, false, true], "repeats of the same value are dropped")
        subscription.cancel()
    }

    func testPublishedPlayingState_LetsABackgroundTickSend() {
        let session = SpyShimSession()
        let scheduler = FakeActivityTickScheduler()
        let policy = makeTestActivityPolicy(scheduler: scheduler)
        var sends = 0
        let subscription = PlaytimeUploadSchedule.triggers(
            from: policy,
            isAudioPlaying: PlaytimeUploadSchedule.isAudioPlaying(from: session)
        )
        .sink { sends += 1 }
        scheduler.fireAll()
        XCTAssertEqual(sends, 0, "launch in the background, not playing")

        session.playbackStatePublisher.send(.playing(bookId: "b"))
        scheduler.fireAll()

        XCTAssertEqual(sends, 1)
        XCTAssertEqual(scheduler.armedIntervals, [900])
        subscription.cancel()
    }
}
