//
//  AudiobookSessionBootstrapperWiringTests.swift
//  PalaceTests
//
//  The session primes the audio session through the bootstrapper its
//  container gave it, not the app's, so a test or second container sees the
//  calls on its own bootstrapper.
//

import XCTest
@testable import Palace
import PalaceBookModel

@MainActor
final class AudiobookSessionBootstrapperWiringTests: AudiobookSessionOpenTestCase {

    /// An open activates the audio session before the first play, through the
    /// injected bootstrapper.
    func testOpen_activatesTheAudioSessionThroughTheInjectedBootstrapper() async throws {
        await startParkedOpen(downloadedBook("book-a"))

        XCTAssertEqual(audioSessionPrimer.activateForPlaybackCount, 1)
        await finishOpens()
    }

    /// A foreground return with a bound player re-primes the audio session
    /// through the injected bootstrapper.
    func testForegroundRecovery_withABoundPlayer_reinitializesThroughTheInjectedBootstrapper() async throws {
        await startParkedOpen(downloadedBook("book-a"))
        adapters[0].complete(with: .success((json: Self.playableManifest(id: "book-a"), decryptor: nil)))
        await awaitConditionAsync { self.sut.manager != nil }
        XCTAssertNotNil(sut.manager, "Setup: the open must bind a player")

        sut.recoverPlaybackForForegroundEntry()

        XCTAssertEqual(audioSessionPrimer.initializeCount, 1)
        await finishOpens()
    }

    /// With no player bound there is nothing to recover, so nothing is primed.
    func testForegroundRecovery_withNoPlayer_doesNotPrime() {
        sut.recoverPlaybackForForegroundEntry()

        XCTAssertEqual(audioSessionPrimer.initializeCount, 0)
    }

    private static func playableManifest(id: String) -> [String: Any] {
        [
            "@context": ["https://readium.org/webpub-manifest/context.jsonld"],
            "id": id,
            "metadata": [
                "@type": "http://schema.org/Audiobook",
                "identifier": id,
                "title": "Bootstrapper Fixture",
                "duration": 300
            ],
            "readingOrder": [
                ["title": "One", "href": "https://example.com/one.mp3", "duration": 100, "type": "audio/mpeg"],
                ["title": "Two", "href": "https://example.com/two.mp3", "duration": 200, "type": "audio/mpeg"]
            ]
        ]
    }
}
