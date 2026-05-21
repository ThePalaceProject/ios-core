//
//  AudiobookSessionManagerShutdownTests.swift
//  PalaceTests
//
//  Targets Crashlytics F-001:
//    Adobe RMSDK background watchdog kill, 47 users / 156 events on 3.0.0
//
//  WHAT THE CRASH IS:
//  iOS watchdog kills the app because applicationDidEnterBackground returns
//  late. The blocker is RMSDK's C++ static dtors running over the
//  ~5-second iOS background budget. Audiobook session teardown happens
//  in the same window — pause + unload + decryptor release — and the
//  more rapid the background/foreground cycles, the more it stacks
//  lifecycle work into a single watchdog tick.
//
//  WHAT WE TEST:
//  Two things we CAN exercise from XCTest:
//    1. AudiobookSessionManager state must stay coherent across rapid
//       background/foreground cycles. If the state machine ever
//       deadlocks or asserts during teardown, the watchdog kill
//       Crashlytics records would be compounded by hangs.
//    2. stopPlayback (the audiobook-side teardown that runs alongside
//       RMSDK dtors during background) must complete fast and idempotent.
//       Repeated stopPlayback calls in tight succession must not pile up
//       state.
//
//  WHAT WE CAN'T TEST:
//  The actual RMSDK static-destructor budget overrun. That lives in
//  Adobe-owned C++ binary code initialised at app launch and torn down
//  by the OS. CLAUDE.md bans live RMSDK calls from unit tests anyway.
//  A device-level integration test in simdrive that backgrounds the
//  app repeatedly is the proper coverage for the F-001 watchdog
//  itself; this file is the unit-level scaffolding around it.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import Combine
import XCTest
@testable import Palace

@MainActor
final class AudiobookSessionManagerShutdownTests: XCTestCase {

    /// Locally-constructed session manager — Module B replaced the singleton.
    /// Module D will idiomize on its pass.
    private var manager: AudiobookSessionManager!

    override func setUp() async throws {
        try await super.setUp()
        manager = AudiobookSessionManager(appContainer: AppContainer.production())
    }

    // MARK: - F-001: state coherence across rapid background/foreground

    /// Drives the session manager through 10 rapid stopPlayback calls in
    /// a row — modelling the worst-case "user keeps app-switching" pattern
    /// the F-001 watchdog cluster fires under. Every stop must leave the
    /// manager in .idle with no leaked state. If the state machine had a
    /// race here, the F-001 watchdog kill rate would be compounded by
    /// state corruption rebuilding the player on next foreground.
    func test_rapidStopPlayback_leavesSessionInIdleState() async {
        for cycle in 0..<10 {
            await manager.stopPlayback(dismissPhoneUI: false)
            XCTAssertEqual(manager.state, .idle,
                           "Cycle \(cycle): rapid stopPlayback must always leave the session in .idle")
            XCTAssertNil(manager.currentBook,
                         "Cycle \(cycle): currentBook must be nil after stop")
            XCTAssertNil(manager.manager,
                         "Cycle \(cycle): manager must be nil after stop")
            XCTAssertNil(manager.audiobook,
                         "Cycle \(cycle): audiobook must be nil after stop")
            XCTAssertFalse(manager.isPlaying,
                           "Cycle \(cycle): isPlaying must be false after stop")
        }
    }

    /// Idempotency contract: stopPlayback called twice with no work in
    /// between must produce identical state, with no compounding side
    /// effects. The F-001 watchdog window is short enough that the OS
    /// could call applicationDidEnterBackground while a previous
    /// teardown is still draining; that path must be safe.
    func test_doubleStopPlayback_isIdempotent() async {
        await manager.stopPlayback(dismissPhoneUI: false)
        let stateAfterFirst = manager.state
        let bookIdAfterFirst = manager.currentBook?.identifier

        await manager.stopPlayback(dismissPhoneUI: false)

        XCTAssertEqual(manager.state, stateAfterFirst,
                       "Second stopPlayback must produce identical state — non-idempotent teardown would corrupt the state machine on rapid background cycles")
        XCTAssertEqual(manager.currentBook?.identifier, bookIdAfterFirst,
                       "currentBook must be stable across redundant stops")
    }

    // MARK: - F-001: state publisher emits .idle on stop

    /// State publisher must emit `.idle` on every stopPlayback. CarPlay
    /// observes this publisher to clear its now-playing screen during
    /// background transitions. If the publisher misses the emit during
    /// the F-001 watchdog window, the lock-screen UI gets stuck on
    /// "Playing" while the app is being killed — a known regression
    /// vector for the watchdog crashes.
    func test_stopPlayback_emitsIdleStateToPublisher() async {
        // Bring the publisher subscription up BEFORE the stop so we don't
        // miss the emit. (PassthroughSubject doesn't replay.)
        var receivedStates: [AudiobookSessionState] = []
        let cancellable = manager.playbackStatePublisher
            .sink { state in
                receivedStates.append(state)
            }

        await manager.stopPlayback(dismissPhoneUI: false)

        XCTAssertTrue(
            receivedStates.contains(.idle),
            "stopPlayback must emit .idle to playbackStatePublisher — CarPlay relies on it during background transitions"
        )
        cancellable.cancel()
    }

    // MARK: - F-001: teardown must not depend on a bound manager

    /// stopPlayback must work even when the session has never been
    /// bound to a real AudiobookManager. The F-001 watchdog can fire
    /// during a cold launch where the app is backgrounded before any
    /// playback started — stopPlayback in that state must be a fast
    /// no-op, not a crash.
    func test_stopPlayback_neverBound_isFastNoOp() async {
        // Force an unbound state explicitly: stop, then immediately
        // stop again. The first stop ensures clean state; the second is
        // the test surface — stopping from a clean state must succeed
        // and stay in .idle.
        await manager.stopPlayback(dismissPhoneUI: false)
        XCTAssertEqual(manager.state, .idle, "Pre-condition: state is .idle")
        XCTAssertNil(manager.manager, "Pre-condition: manager is nil")

        let start = Date()
        await manager.stopPlayback(dismissPhoneUI: false)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(manager.state, .idle,
                       "stopPlayback from unbound state must keep .idle")
        XCTAssertLessThan(elapsed, 0.5,
                          "stopPlayback from unbound state must complete in <500ms — guard against F-001 watchdog budget consumption")
    }

    // MARK: - F-001: validate non-fatal record builder is pure & non-MainActor

    /// `buildPlaybackFailureRecord` is the Crashlytics NSError builder
    /// AudiobookSessionManager calls when playback fails — including from
    /// the background teardown path. It MUST be safely callable from
    /// off the MainActor (it's annotated `nonisolated`). If a refactor
    /// adds a MainActor dependency, the teardown path could deadlock
    /// the watchdog by hopping queues during the F-001 budget window.
    func test_buildPlaybackFailureRecord_isCallableOffMainActor() async {
        // Move to a background actor / global queue to verify the
        // nonisolated contract. The fact that this compiles + runs is
        // half the assertion; the other half is the resulting NSError
        // shape stays correct.
        let nonFatal: NSError = await Task.detached {
            return AudiobookSessionManager.buildPlaybackFailureRecord(
                error: NSError(domain: "test", code: 42, userInfo: ["httpStatusCode": 500]),
                position: nil,
                bookId: "bg-shutdown-book"
            )
        }.value

        XCTAssertEqual(nonFatal.domain, "org.thepalaceproject.palace.audiobookPlayback",
                       "non-fatal record must keep the canonical domain so Crashlytics groups correctly")
        XCTAssertEqual(nonFatal.userInfo["bookId"] as? String, "bg-shutdown-book",
                       "bookId must round-trip — F-001 triage depends on which book was playing")
        XCTAssertEqual(nonFatal.userInfo["httpStatusCode"] as? Int, 500,
                       "httpStatusCode must propagate from the underlying error so background-failure crashlytics groups remain triageable")
        XCTAssertEqual(nonFatal.userInfo["underlyingDomain"] as? String, "test",
                       "underlying domain must propagate so backround failures aren't all flattened into one bucket")
        XCTAssertEqual(nonFatal.userInfo["underlyingCode"] as? Int, 42,
                       "underlying code must propagate — distinguishes a 401 from a 500 in the background-failure bucket")
    }

    // MARK: - F-001: network validation rules survive every cycle

    /// Pure rule check that the network-validation gate (which decides
    /// whether a freshly-opened audiobook can start in the F-001
    /// watchdog window after a background → foreground bounce) returns
    /// stable answers. A regression that makes this stateful would
    /// surface as intermittent open failures right after backgrounding
    /// — i.e. it would compound F-001's effects.
    func test_networkValidationError_isPureAcrossManyCalls() {
        let states: [TPPBookState] = [
            .unregistered, .downloadNeeded, .downloadSuccessful,
            .used, .downloading, .holding, .returning
        ]

        for state in states {
            for connected in [true, false] {
                for onWiFi in [true, false] {
                    for wifiOnly in [true, false] {
                        let first = AudiobookSessionManager.networkValidationError(
                            bookState: state,
                            isConnectedToNetwork: connected,
                            isOnWiFi: onWiFi,
                            downloadOnlyOnWiFi: wifiOnly
                        )
                        let second = AudiobookSessionManager.networkValidationError(
                            bookState: state,
                            isConnectedToNetwork: connected,
                            isOnWiFi: onWiFi,
                            downloadOnlyOnWiFi: wifiOnly
                        )
                        XCTAssertEqual(first, second,
                                       "Pure validator must be deterministic for state=\(state), connected=\(connected), onWiFi=\(onWiFi), wifiOnly=\(wifiOnly)")
                    }
                }
            }
        }
    }

    /// The specific rules that ship today — locks them so a refactor of
    /// the validator can't silently change the bg/fg open semantics.
    /// downloadOnlyOnWiFi + cellular while streaming = .wifiRequired
    /// is the most user-visible rule and the one most likely to be
    /// "simplified" wrong.
    func test_networkValidationError_wifiRequiredOnCellularWhileStreaming() {
        let err = AudiobookSessionManager.networkValidationError(
            bookState: .downloadNeeded,   // streaming, not fully downloaded
            isConnectedToNetwork: true,
            isOnWiFi: false,              // on cellular
            downloadOnlyOnWiFi: true      // user has the WiFi-only switch on
        )
        XCTAssertEqual(err, .wifiRequired,
                       "REGRESSION GUARD: streaming book on cellular with WiFi-only setting must always surface .wifiRequired — not a silent crash on background open")
    }

    func test_networkValidationError_fullyDownloadedBypassesAllNetworkRules() {
        for connected in [true, false] {
            for onWiFi in [true, false] {
                for wifiOnly in [true, false] {
                    let err = AudiobookSessionManager.networkValidationError(
                        bookState: .downloadSuccessful,
                        isConnectedToNetwork: connected,
                        isOnWiFi: onWiFi,
                        downloadOnlyOnWiFi: wifiOnly
                    )
                    XCTAssertNil(err,
                                 "Fully downloaded book must bypass ALL network checks (connected=\(connected), onWiFi=\(onWiFi), wifiOnly=\(wifiOnly)) — needed so the F-001 background re-open path doesn't gate on flaky network state")
                }
            }
        }
    }
}
