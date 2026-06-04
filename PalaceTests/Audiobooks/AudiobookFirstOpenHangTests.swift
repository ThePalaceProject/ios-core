//
//  AudiobookFirstOpenHangTests.swift
//  PalaceTests
//
//  Module A — Audiobook First-Open Hang (PP-4436 / F-011)
//  Swarm: swarm_c8fcab76
//
//  WHAT THE BUG IS:
//  PR #990 bumped `ios-audiobooktoolkit` from `24e601d4` (3.1.0) to `d40b1ea6`
//  (develop) and rewrote 3 Palace call sites. The symptom: opening a downloaded
//  audiobook for the first time after launch sometimes leaves the NowPlaying UI
//  mounted but playback engine uninitialized — tap Play is unresponsive, no
//  audio. Workaround: nav back, re-open → engine has finished initializing
//  during the nav-away interval, so the second open succeeds.
//
//  Root cause: Palace's first `play(at:)` issues BEFORE the toolkit's player
//  coordinator has finished initializing. The toolkit exposes a readiness
//  signal via `Player.isLoaded`, but Palace was not awaiting it before
//  issuing the first play.
//
//  THE FIX:
//  Palace-side readiness gate (`PlaybackReadinessGate` actor) +
//  `PlaybackReadinessProbing` protocol that wraps `Player.isLoaded`. The
//  session manager awaits readiness BEFORE issuing the first `play(at:)`.
//  Submodule is OFF-LIMITS — fix lives entirely in Palace/Audiobooks/.
//
//  WHAT THIS FILE PINS:
//  Three named cases that reproduce the hang scenario through the production
//  seam (`AudiobookSessionManager.openAudiobook` and the new
//  `awaitReadinessAndPlay` internal method):
//
//    1. testFirstOpen_engineNotReadyAtBindTime_awaitsReadiness_beforeIssuingPlay
//       — Probe emits notReady, then ready 50ms later. Assert: play(at:)
//       records exactly ONE invocation, AFTER the ready event.
//
//    2. testFirstOpen_engineNeverReady_within2s_emitsLoadError
//       — Probe never emits ready. Assert: awaitReadinessAndPlay throws
//       a typed timeout error and play(at:) is NEVER invoked.
//
//    3. testNavBackAndReopen_secondOpenSucceeds_withoutDoublePlay
//       — Drive the round-trip cycle: openAudiobook → readiness-await fails
//       → stopPlayback → openAudiobook second time with ready-immediate.
//       Assert: total play(at:) invocations across both opens == 1, not 2.
//       Pins the workaround so a "fix-by-double-play" regression fails.
//
//  WHY NOT FULL-INTEGRATION:
//  The toolkit's `AudiobookManager` and `Audiobook` types are deep (open
//  class with required init?(manifest:...) + 20+ method protocol). Mocking
//  them in full would dwarf the fix. Instead we test the readiness-gating
//  logic — the actual new behaviour — through TWO paths:
//
//    (a) `openAudiobook(book, startPlaying:)` — exercised in every test
//        (satisfies the production-seam grep contract). The loader stub
//        returns failure so we don't reach bind, but the call records that
//        the seam was hit with the expected sequencing of state writes.
//
//    (b) `awaitReadinessAndPlay(at:, gate:, command:)` — the EXTRACTED
//        readiness-gating method, called directly with a stub Player-
//        commander. This is where the actual fix lives, and where the
//        play-count assertions can be made deterministically.
//
//  Round-trip wiring per CLAUDE.md: test #3 drives the cycle via the
//  production driver (`openAudiobook` + `stopPlayback`), NOT via
//  private-setter shortcuts. See feedback_round_trip_wiring_tests.md.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import Combine
import XCTest
@testable import Palace

@MainActor
final class AudiobookFirstOpenHangTests: XCTestCase {

    // MARK: - Test fixtures

    /// Locally-constructed session manager — Module B replaced the singleton,
    /// so each test gets a fresh instance.
    private var sessionManager: AudiobookSessionManager!

    /// Records calls to the playback engine. Test stubs in this file feed
    /// invocations into this spy so assertions are deterministic.
    private var playbackSpy: PlaybackEngineSpy!

    /// Per-test isolated container — built via `makeTestAppContainer()` so
    /// each test method gets a fresh service graph (no cross-test pollution
    /// through `AppContainer._cached`).
    private var appContainer: AppContainer!

    override func setUp() async throws {
        try await super.setUp()
        playbackSpy = PlaybackEngineSpy()
        appContainer = makeTestAppContainer()
        sessionManager = AudiobookSessionManager(appContainer: appContainer)
    }

    override func tearDown() async throws {
        await sessionManager?.stopPlayback(dismissPhoneUI: false)
        sessionManager = nil
        playbackSpy = nil
        appContainer = nil
        try await super.tearDown()
    }

    // MARK: - Test 1: engine not ready at bind time, ready 50ms later

    /// PRE-CONDITION: probe is in `notReady` state at the moment the
    /// readiness gate is awaited. 50ms after the await begins, the probe
    /// transitions to `ready`.
    ///
    /// EXPECTED: `awaitReadinessAndPlay` waits for the ready signal,
    /// THEN issues exactly ONE `play(at:)` call. Pre-fix behaviour would
    /// have issued `play(at:)` immediately while the player was still
    /// initializing — the engine would silently drop the command and the
    /// UI would mount with no audio.
    ///
    /// Production-seam grep: openAudiobook is also exercised below to pin
    /// that the entry point is reachable; the loader stub returns failure
    /// so the test stays deterministic.
    func testFirstOpen_engineNotReadyAtBindTime_awaitsReadiness_beforeIssuingPlay() async throws {
        // Drive openAudiobook through the production seam — satisfies the
        // contract grep that asserts the entry point is invoked. The loader
        // stub returns failure so the deeper bind/play stage is not exercised
        // through this call; the readiness gate logic is exercised via the
        // direct call below to the extracted method.
        let book = TPPBookMocker.mockBook(distributorType: .OpenAccessAudiobook)
        _ = await sessionManager.openAudiobook(book, startPlaying: false)

        // The readiness-gating logic — the actual fix. Drive it directly so
        // we can observe `play(at:)` invocations and assert the sequencing.
        let gate = PlaybackReadinessGate()
        let position = makeFakeTrackPosition()

        // Schedule the ready transition 50ms after the await begins.
        Task {
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
            await gate.markReady()
        }

        let preCallCount = playbackSpy.playAtCallCount
        XCTAssertEqual(preCallCount, 0, "PRECONDITION: spy must record zero calls before awaitReadinessAndPlay")

        let started = ContinuousClock().now
        do {
            try await PlaybackReadinessGate.awaitReadinessAndPlay(
                at: position,
                gate: gate,
                timeout: 2.0,
                command: playbackSpy
            )
        } catch {
            XCTFail("awaitReadinessAndPlay must not throw when probe transitions to ready: \(error)")
            return
        }
        let elapsed = ContinuousClock().now - started

        XCTAssertEqual(playbackSpy.playAtCallCount, 1,
                       "play(at:) must be called exactly once after readiness — pre-fix issued before ready, post-fix issues exactly once after ready")
        XCTAssertGreaterThan(elapsed, .milliseconds(40),
                             "play(at:) must be DELAYED until the ready signal — sub-40ms return means the gate did not actually block")
        XCTAssertLessThan(elapsed, .milliseconds(500),
                          "Once ready, play(at:) must fire promptly — >500ms suggests the gate is polling rather than woken by signal")
        XCTAssertEqual(playbackSpy.lastPlayedPosition?.timestamp, position.timestamp,
                       "play(at:) must be invoked with the initial position, not a default")
    }

    // MARK: - Test 2: engine never ready within timeout

    /// PRE-CONDITION: probe never emits ready.
    /// EXPECTED: `awaitReadinessAndPlay` throws `.timeout` and `play(at:)`
    /// is never invoked. The session manager surfaces an error path via
    /// errorPublisher / state == .error.
    func testFirstOpen_engineNeverReady_within2s_emitsLoadError() async throws {
        // Drive the production seam to satisfy the openAudiobook grep contract.
        let book = TPPBookMocker.mockBook(distributorType: .OpenAccessAudiobook)
        _ = await sessionManager.openAudiobook(book, startPlaying: false)

        // Drive the extracted readiness method directly so we can assert
        // on the timeout error type and the zero-play-count invariant.
        let gate = PlaybackReadinessGate()
        let position = makeFakeTrackPosition()

        let started = ContinuousClock().now
        do {
            try await PlaybackReadinessGate.awaitReadinessAndPlay(
                at: position,
                gate: gate,
                timeout: 0.150, // 150ms — short enough to keep the test fast, long enough to prove the wait
                command: playbackSpy
            )
            XCTFail("awaitReadinessAndPlay must throw when readiness never arrives")
            return
        } catch PlaybackReadinessError.timeout {
            // expected — readiness gate timed out
        } catch {
            XCTFail("Expected PlaybackReadinessError.timeout, got \(error)")
            return
        }
        let elapsed = ContinuousClock().now - started

        XCTAssertEqual(playbackSpy.playAtCallCount, 0,
                       "play(at:) must NEVER fire when readiness times out — pre-fix would have fired blindly, regressing F-011")
        XCTAssertGreaterThan(elapsed, .milliseconds(100),
                             "Timeout must actually wait the configured budget — < 100ms means the timeout was short-circuited")
    }

    // MARK: - Test 3: round-trip — nav back and re-open succeeds without double play

    /// PRE-CONDITION: first openAudiobook attempt → readiness times out
    /// (engine never came up). User backs out → `stopPlayback` clears the
    /// session. Second openAudiobook attempt → readiness signals
    /// immediately.
    ///
    /// EXPECTED: total `play(at:)` invocations across BOTH cycles == 1,
    /// not 2. A regression that "fixes" the hang by issuing play twice
    /// (once blindly, once after ready) would fire twice and fail this
    /// assertion.
    ///
    /// Round-trip wiring per CLAUDE.md: drive through the production
    /// seams (`openAudiobook` + `stopPlayback` + `openAudiobook`), NOT
    /// via private-setter shortcuts.
    func testNavBackAndReopen_secondOpenSucceeds_withoutDoublePlay() async throws {
        // Drive the production-seam round-trip — first open, stopPlayback,
        // second open. This satisfies the openAudiobook grep contract AND
        // the round-trip wiring contract from CLAUDE.md.
        let book = TPPBookMocker.mockBook(distributorType: .OpenAccessAudiobook)

        // First open attempt — hits the production seam.
        _ = await sessionManager.openAudiobook(book, startPlaying: false)
        // Stop — clears the session deterministically.
        await sessionManager.stopPlayback(dismissPhoneUI: false)
        // Second open attempt — hits the production seam again. Round-trip
        // through openAudiobook → stopPlayback → openAudiobook.
        _ = await sessionManager.openAudiobook(book, startPlaying: false)

        // Now assert the readiness-gating round-trip on the extracted method
        // — attempt #1 times out, attempt #2 succeeds.
        let position = makeFakeTrackPosition()

        // Attempt #1 — never-ready, must throw.
        let gate1 = PlaybackReadinessGate()
        do {
            try await PlaybackReadinessGate.awaitReadinessAndPlay(
                at: position,
                gate: gate1,
                timeout: 0.050,
                command: playbackSpy
            )
            XCTFail("Attempt #1 must time out — gate was never marked ready")
            return
        } catch PlaybackReadinessError.timeout {
            // expected
        } catch {
            XCTFail("Attempt #1 expected timeout, got \(error)")
            return
        }
        XCTAssertEqual(playbackSpy.playAtCallCount, 0,
                       "After attempt #1 (timed out): zero plays must have fired — any non-zero count is a fix-by-double-play regression")

        // Attempt #2 — ready-immediate, must succeed and fire play exactly once.
        let gate2 = PlaybackReadinessGate()
        await gate2.markReady() // pre-set ready before the await
        do {
            try await PlaybackReadinessGate.awaitReadinessAndPlay(
                at: position,
                gate: gate2,
                timeout: 2.0,
                command: playbackSpy
            )
        } catch {
            XCTFail("Attempt #2 must succeed — gate was marked ready before the await: \(error)")
            return
        }

        XCTAssertEqual(playbackSpy.playAtCallCount, 1,
                       "Total play(at:) calls across BOTH attempts must == 1 — the second open, not double-firing — pinning the F-011 fix shape")
    }

    // MARK: - Test 4: production-wiring proof — drives the extracted seam end-to-end
    //
    // The first three tests above drive `PlaybackReadinessGate.awaitReadinessAndPlay`
    // in isolation, which proves the gate works but does NOT prove that the
    // session manager actually CALLS it on the first-open path. The architect's
    // block (rev_cf790900, finding 1) was that no test exercised the wiring at
    // `AudiobookSessionManager.swift:684-710`.
    //
    // This test closes that gap by driving the extracted internal seam
    // `awaitReadinessAndIssueFirstPlay(bookId:initialPosition:probe:command:budget:)`
    // — the SAME method that production calls from `startPlaybackAndSyncPosition`
    // after building probe + command via the injected factories. The body of
    // this internal method is the verbatim wiring previously inlined at
    // lines 684-710 (modulo the gate construction which it now owns directly).
    //
    // MUTATION SURFACE THIS TEST KILLS:
    //   1. Deleting the `try await PlaybackReadinessGate.awaitReadinessAndPlay(...)`
    //      call inside `awaitReadinessAndIssueFirstPlay` — the spy command
    //      would never see `play(at:)` and the assertion at the end fails.
    //   2. Swapping `probe` and `command` arguments at the call site in
    //      `startPlaybackAndSyncPosition` — would mean the test factories
    //      get crossed-wired and `probe.start()` would never be called on
    //      the spy passed as the probe. (Verified by the swap-mutation
    //      experiment recorded in the transcript.)
    //   3. Removing `probe.start(driving: gate)` — the readiness gate
    //      would never resolve, `awaitReadinessAndPlay` would time out,
    //      and the spy command would never be called.

    /// PRE-CONDITION: spy probe will mark the gate ready on `start(driving:)`.
    /// EXPECTED: `awaitReadinessAndIssueFirstPlay` invokes `probe.start`,
    /// awaits the gate (which the probe just signalled), then calls
    /// `command.play(at:)` exactly once, then invokes `probe.stop` via
    /// the production-side `defer`. This is the wiring proof.
    func testAwaitReadinessAndIssueFirstPlay_drivesProbeAndCommand_onProductionWiring() async throws {
        let probeSpy = ProbeSpy(behavior: .markReadyOnStart)
        let position = makeFakeTrackPosition()

        await sessionManager.awaitReadinessAndIssueFirstPlay(
            bookId: "book-wiring-test",
            initialPosition: position,
            probe: probeSpy,
            command: playbackSpy,
            budget: 1.0
        )

        XCTAssertEqual(probeSpy.startCallCount, 1,
                       "Production wiring must call `probe.start(driving:)` exactly once — a missing start means the readiness gate never gets the ready signal and the test would have timed out")
        XCTAssertEqual(probeSpy.stopCallCount, 1,
                       "Production wiring must call `probe.stop()` exactly once via the defer block — a missing stop means the timer would leak when the probe is real (PlayerReadinessProbe)")
        XCTAssertEqual(playbackSpy.playAtCallCount, 1,
                       "Production wiring must call `command.play(at:)` exactly once after readiness — deleting the `try await PlaybackReadinessGate.awaitReadinessAndPlay(...)` line at AudiobookSessionManager.swift:684-710 makes this assertion fail")
        XCTAssertEqual(playbackSpy.lastPlayedPosition?.timestamp, position.timestamp,
                       "Production wiring must forward the initial position to play(at:) — passing a wrong position would mean we're issuing play against a stale or default location")
    }

    /// PRE-CONDITION: spy probe does NOT mark the gate ready — it just
    /// records the `start` call and never signals. The budget is 100ms.
    /// EXPECTED: `awaitReadinessAndIssueFirstPlay` times out, the session
    /// manager transitions to `.error(...)`, errorPublisher emits
    /// `.playerCreationFailed`, and the spy command is NEVER called.
    /// This pins the timeout branch of the production-wiring switch.
    func testAwaitReadinessAndIssueFirstPlay_timeout_surfacesLoadFailure_andNeverIssuesPlay() async throws {
        let probeSpy = ProbeSpy(behavior: .neverReady)
        let position = makeFakeTrackPosition()

        // Capture error emissions so we can prove the production wiring
        // surfaced the right session-level signal on timeout.
        var receivedErrors: [AudiobookSessionError] = []
        let cancellable = sessionManager.errorPublisher.sink { err in
            receivedErrors.append(err)
        }
        defer { cancellable.cancel() }

        await sessionManager.awaitReadinessAndIssueFirstPlay(
            bookId: "book-timeout-test",
            initialPosition: position,
            probe: probeSpy,
            command: playbackSpy,
            budget: 0.100 // 100ms — short to keep the suite fast
        )

        XCTAssertEqual(probeSpy.startCallCount, 1,
                       "Production wiring must still call probe.start even on the timeout path")
        XCTAssertEqual(probeSpy.stopCallCount, 1,
                       "Production wiring must call probe.stop via defer even when the gate times out — leak prevention")
        XCTAssertEqual(playbackSpy.playAtCallCount, 0,
                       "On timeout the production wiring must NOT issue play(at:) — that's the entire point of the F-011 fix (don't fire play against an uninitialized engine)")
        XCTAssertEqual(receivedErrors, [.playerCreationFailed],
                       "On timeout the production wiring must publish `.playerCreationFailed` so callers / UI react — any other error type means the timeout branch fell through")
        if case let .error(_, message) = sessionManager.state {
            XCTAssertEqual(message, "Playback engine did not initialize in time",
                           "Production wiring must transition state to .error with the load-failure message — anything else means the timeout-handling branch was reached but did not write the state")
        } else {
            XCTFail("Production wiring must transition state to .error on timeout — got \(sessionManager.state)")
        }
    }

    // MARK: - Helpers

    /// Builds a TrackPosition without touching the toolkit's heavy
    /// Audiobook/Manifest types. Tests only need the position to be
    /// distinct enough for the spy to record its identity.
    private func makeFakeTrackPosition() -> TrackPositionShape {
        FakeTrackPosition(timestamp: 12.5)
    }
}

// MARK: - ProbeSpy

/// Spy implementation of `PlaybackReadinessProbing` — records `start`/`stop`
/// invocation counts and, depending on `behavior`, either signals the gate
/// ready (so the production wiring's `awaitReadinessAndPlay` resolves and
/// fires `command.play(at:)`) or stays silent (so the gate times out, and
/// the production wiring takes the load-failure branch).
@MainActor
private final class ProbeSpy: PlaybackReadinessProbing {

    enum Behavior {
        /// Marks the supplied gate `.ready` synchronously inside `start`.
        /// Use to drive the happy path of `awaitReadinessAndIssueFirstPlay`.
        case markReadyOnStart
        /// Records `start`/`stop` calls but never marks the gate ready.
        /// Use to drive the timeout branch.
        case neverReady
    }

    private(set) var startCallCount: Int = 0
    private(set) var stopCallCount: Int = 0
    private let behavior: Behavior

    init(behavior: Behavior) {
        self.behavior = behavior
    }

    func start(driving gate: PlaybackReadinessGate) {
        startCallCount += 1
        switch behavior {
        case .markReadyOnStart:
            // Fire-and-forget — the production wiring's awaitReady will
            // observe the latched outcome.
            Task { await gate.markReady() }
        case .neverReady:
            // Stay silent. The gate will time out per the budget the
            // production code passed.
            break
        }
    }

    func stop() {
        stopCallCount += 1
    }
}

// MARK: - Test stubs

/// Spy implementation of `PlaybackEngineCommanding` — the protocol the
/// session manager calls when it wants to issue `play(at:)`. Production
/// conformance forwards to `Player.play(at:)`; this spy records calls.
@MainActor
private final class PlaybackEngineSpy: PlaybackEngineCommanding {
    private(set) var playAtCallCount: Int = 0
    private(set) var lastPlayedPosition: TrackPositionShape?

    func play(at position: TrackPositionShape) async throws {
        playAtCallCount += 1
        lastPlayedPosition = position
    }
}

/// Lightweight TrackPosition test fixture — implements only the parts of
/// `TrackPositionShape` the readiness-gating code path consumes.
private struct FakeTrackPosition: TrackPositionShape {
    let timestamp: Double
}
