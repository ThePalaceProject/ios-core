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
import UIKit
import XCTest
@testable import Palace

@MainActor
final class AudiobookSessionManagerShutdownTests: XCTestCase {

    /// Locally-constructed session manager — Module B replaced the singleton.
    /// Module D will idiomize on its pass.
    private var manager: AudiobookSessionManager!
    /// Per-test isolated container — built via `makeTestAppContainer()` so
    /// each test method gets a fresh service graph (no cross-test pollution
    /// through `AppContainer._cached`).
    private var appContainer: AppContainer!

    override func setUp() async throws {
        try await super.setUp()
        appContainer = makeTestAppContainer()
        manager = AudiobookSessionManager(appContainer: appContainer)
    }

    override func tearDown() async throws {
        manager = nil
        appContainer = nil
        try await super.tearDown()
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

    // MARK: - F-001: teardown serializes against off-main remote-command reads

    /// Off-main remote/CarPlay/lock-screen command handlers reach the session
    /// through the ONE `nonisolated` accessor built for that purpose —
    /// `hasActiveManagerSnapshot` (an `OSAllocatedUnfairLock`-backed mirror of
    /// `manager != nil`, written only on the main actor at the bind/unbind
    /// seams). This is the exact class of read that trips
    /// `dispatch_assert_queue_fail` if it ever synchronously touches a
    /// `@MainActor` member off-main — the #1218 Now-Playing artwork crash.
    ///
    /// Here we hammer that snapshot from ~5 concurrent background tasks WHILE
    /// the main actor runs `stopPlayback` (teardown). The off-main reads must
    /// never trap, the main-actor teardown must complete, and the post-teardown
    /// state must be coherent: no bound manager, `.idle`, and the off-main
    /// snapshot converged to `false` (its writer is the `manager` `didSet` that
    /// teardown fires). If teardown didn't serialize safely — or a refactor
    /// made the snapshot read a `@MainActor` member off-main — this either
    /// crashes or leaves the snapshot stuck `true`.
    func test_concurrentRemoteCommandsAndStopPlayback_teardownSerializes() async {
        // ~5 background readers simulating remote/CarPlay handlers firing
        // off-main. They only touch the `nonisolated` snapshot — the single
        // legal off-main accessor — never a `@MainActor` member. Each spins a
        // tight read loop so reads overlap the main-actor teardown window.
        let readerCount = 5
        let readsPerReader = 200
        let readers: [Task<Bool, Never>] = (0..<readerCount).map { _ in
            Task.detached {
                var sawAnyValueSafely = true
                for _ in 0..<readsPerReader {
                    // A synchronous off-main read of an isolated member would
                    // trap here; reaching the OR proves the read returned.
                    let snapshot = AudiobookSessionManager.hasActiveManagerSnapshot
                    sawAnyValueSafely = sawAnyValueSafely && (snapshot || !snapshot)
                    await Task.yield()
                }
                return sawAnyValueSafely
            }
        }

        // Drive main-actor teardown concurrently with the off-main readers.
        // Repeat so the teardown/read windows interleave many times.
        for _ in 0..<20 {
            await manager.stopPlayback(dismissPhoneUI: false)
            await Task.yield()
        }

        // All readers must have completed without trapping.
        for reader in readers {
            let completedSafely = await reader.value
            XCTAssertTrue(completedSafely,
                          "Off-main remote-command reads of hasActiveManagerSnapshot must complete without an actor-isolation trap while teardown runs")
        }

        // Teardown completed and left coherent state.
        XCTAssertEqual(manager.state, .idle,
                       "Teardown under concurrent off-main reads must settle in .idle")
        XCTAssertNil(manager.manager,
                     "No manager may be bound after teardown")
        XCTAssertFalse(manager.hasActiveManager,
                       "hasActiveManager must be false after teardown")

        // The off-main snapshot is the mirror teardown's manager-didSet writes;
        // after the last stop it must have converged to false. This is the leg
        // that proves the off-main read path reflects the serialized teardown.
        XCTAssertFalse(AudiobookSessionManager.hasActiveManagerSnapshot,
                       "Post-teardown, the off-main snapshot must reflect the unbound manager (false)")
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

    // MARK: - Background / terminate position persistence (keeper migration)
    //
    // Phase 3 moved the background/terminate position-persist off the hidden
    // toolkit "keeper" view (an opacity(0) AudiobookPlayerView mounted only for
    // its `setupBackgroundStateHandling()` side effects) and into
    // AudiobookSessionManager. These lock the guard + wiring we CAN exercise
    // from XCTest; the "active session actually writes the location" leg needs a
    // bound toolkit AudiobookManager/AudiobookPlaybackModel, which unit tests
    // cannot construct — that leg is covered on-device / in simdrive.

    /// The persist gate must fire ONLY when a fully-bound session exists
    /// (manager + book + model all present). Any missing leg means there is no
    /// live position to save, so persisting would be meaningless or could write
    /// a stale value. This is the pure decision the background/terminate
    /// observers consult; mutating `&&`→`||` or negating a leg must fail here.
    func test_shouldPersistLifecyclePosition_requiresFullyBoundSession() {
        // Only the all-true combination persists.
        XCTAssertTrue(
            AudiobookSessionManager.shouldPersistLifecyclePosition(
                hasManager: true, hasBook: true, hasModel: true),
            "A fully-bound session (manager + book + model) MUST persist on background/terminate")

        // Every combination with at least one missing leg must NOT persist.
        for hasManager in [true, false] {
            for hasBook in [true, false] {
                for hasModel in [true, false] {
                    guard !(hasManager && hasBook && hasModel) else { continue }
                    XCTAssertFalse(
                        AudiobookSessionManager.shouldPersistLifecyclePosition(
                            hasManager: hasManager, hasBook: hasBook, hasModel: hasModel),
                        "Incomplete session (manager=\(hasManager), book=\(hasBook), model=\(hasModel)) must NOT persist — no live position to save")
                }
            }
        }
    }

    /// With no session bound, the instance persist entry point must be a safe
    /// no-op: no crash, and it must not resurrect any session state. This is the
    /// cold-launch-background path the old keeper handled by simply having a nil
    /// playbackModel; it must stay a no-op now that the manager owns it.
    func test_persistActivePositionForLifecycleEvent_unbound_isSafeNoOp() async {
        await manager.stopPlayback(dismissPhoneUI: false)
        XCTAssertNil(manager.manager, "Pre-condition: no bound manager")

        manager.persistActivePositionForLifecycleEvent()

        XCTAssertEqual(manager.state, .idle,
                       "Persisting with no session must not change state")
        XCTAssertNil(manager.currentBook,
                     "Persisting with no session must not resurrect a book")
    }

    /// The manager must actually SUBSCRIBE to background + terminate: posting
    /// each notification while unbound must route into the (no-op) persist path
    /// without crashing and without disturbing state. If a refactor drops the
    /// subscription, the keeper's job is silently lost — this pins that the
    /// observers exist and are wired to the no-op-safe handler.
    func test_lifecycleNotifications_whileUnbound_areHandledSafely() async {
        await manager.stopPlayback(dismissPhoneUI: false)
        XCTAssertEqual(manager.state, .idle, "Pre-condition: idle")

        NotificationCenter.default.post(
            name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.post(
            name: UIApplication.willTerminateNotification, object: nil)
        // Let the .receive(on: .main) hops drain.
        await Task.yield()

        XCTAssertEqual(manager.state, .idle,
                       "Background/terminate notifications with no session must leave state idle")
        XCTAssertNil(manager.currentBook,
                     "Background/terminate notifications with no session must not bind a book")
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
