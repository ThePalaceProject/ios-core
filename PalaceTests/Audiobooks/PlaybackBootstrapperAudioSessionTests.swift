//
//  PlaybackBootstrapperAudioSessionTests.swift
//  PalaceTests
//
//  Tests for the launch-path audio-session deferral added in swarm_27c181b5
//  (Startup-AppLifecycle, C3). At app launch `PlaybackBootstrapper.ensureInitialized()`
//  must register the MPRemoteCommandCenter handlers SYNCHRONOUSLY (CarPlay cold
//  start needs them before the first transport command) while deferring the
//  AVAudioSession category configuration off the synchronous launch path (it
//  routinely fails OSStatus -50 that early and is re-run later).
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import AVFoundation
import MediaPlayer
@testable import Palace

@MainActor
final class PlaybackBootstrapperAudioSessionTests: XCTestCase {

    private var appContainer: AppContainer!

    override func setUp() async throws {
        try await super.setUp()
        appContainer = makeTestAppContainer()
    }

    override func tearDown() async throws {
        appContainer = nil
        try await super.tearDown()
    }

    /// The remote command center is configured synchronously during
    /// `ensureInitialized()`, while the audio-session configuration is handed to
    /// the launch dispatcher (deferred) rather than run inline.
    func testPlaybackBootstrapper_launch_defersAudioSession_keepsRemoteCommands() {
        let manager = AudiobookSessionManager(appContainer: appContainer)

        var dispatchCount = 0
        var deferredWork: (() -> Void)?
        let bootstrapper = PlaybackBootstrapper(
            appContainer: appContainer,
            audiobookSessionProvider: { manager },
            launchAudioSessionDispatcher: { work in
                dispatchCount += 1
                deferredWork = work
            }
        )

        bootstrapper.ensureInitialized()

        // Remote commands were registered SYNCHRONOUSLY (CarPlay cold-start need).
        let commandCenter = MPRemoteCommandCenter.shared()
        XCTAssertTrue(commandCenter.skipForwardCommand.isEnabled,
                      "skip-forward must be enabled synchronously at launch")
        XCTAssertEqual(commandCenter.skipForwardCommand.preferredIntervals, [30],
                       "skip interval must be configured synchronously at launch")
        XCTAssertFalse(commandCenter.nextTrackCommand.isEnabled,
                       "track-navigation must be disabled synchronously at launch")

        // Audio-session configuration was DEFERRED, not run inline.
        XCTAssertEqual(dispatchCount, 1,
                       "audio-session configuration must be dispatched exactly once")
        XCTAssertNotNil(deferredWork,
                        "audio-session configuration must be deferred (captured), not run synchronously")

        // Running the deferred work actually configures the session category —
        // proving the deferred closure IS the audio-session config, not a no-op.
        deferredWork?()
        XCTAssertEqual(AVAudioSession.sharedInstance().category, .playback,
                       "the deferred work must configure the playback audio category")
    }

    /// `ensureInitialized()` is idempotent: a second call must NOT re-dispatch
    /// the audio-session configuration. Kills the `guard !isInitialized` mutant.
    func testPlaybackBootstrapper_ensureInitialized_isIdempotent_doesNotRedispatch() {
        let manager = AudiobookSessionManager(appContainer: appContainer)

        var dispatchCount = 0
        let bootstrapper = PlaybackBootstrapper(
            appContainer: appContainer,
            audiobookSessionProvider: { manager },
            launchAudioSessionDispatcher: { _ in dispatchCount += 1 }
        )

        bootstrapper.ensureInitialized()
        bootstrapper.ensureInitialized()

        XCTAssertEqual(dispatchCount, 1,
                       "the initialized guard must prevent a second audio-session dispatch")
    }
}
