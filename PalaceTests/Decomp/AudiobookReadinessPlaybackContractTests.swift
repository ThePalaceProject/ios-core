//
//  AudiobookReadinessPlaybackContractTests.swift
//  PalaceTests
//
//  Pins the first-open readiness wiring in `AudiobookSessionManager` as call ORDER:
//  `probe.start` → `command.play` → `probe.stop`, and no `command.play` on the
//  timeout path (F-011). `AudiobookFirstOpenHangTests` covers the counts; this
//  catches a reorder that keeps them (docs/architecture/god-class-decomposition-plan.md §3a-1).
//  Drives `awaitReadinessAndIssueFirstPlay(...)` with spies for the internal probe
//  and command protocols. LCP first-open (`confirmLCPFirstPlay`) is DRM-specific
//  and verified on a simulator.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Combine
import Foundation
import XCTest
@testable import Palace

// MARK: - Recording readiness spies (conform to the internal protocols)

/// Records `start`/`stop` into a `CallLog` in order. `behavior` decides
/// whether `start` drives the gate ready (so the wiring's `awaitReadinessAndPlay`
/// resolves and issues `command.play`) or stays silent (so the gate times out
/// and `command.play` is never reached).
@MainActor
private final class RecordingProbe: PlaybackReadinessProbing {
    enum Behavior { case markReadyOnStart, neverReady }

    let log: CallLog
    private let behavior: Behavior

    init(log: CallLog, behavior: Behavior) {
        self.log = log
        self.behavior = behavior
    }

    func start(driving gate: PlaybackReadinessGate) {
        log.record("probe.start")
        switch behavior {
        case .markReadyOnStart:
            Task { await gate.markReady() }
        case .neverReady:
            break
        }
    }

    func stop() {
        log.record("probe.stop")
    }

    func isCurrentlyReady() -> Bool { false }
}

/// Records `play(at:)` (with its position timestamp) into the shared `CallLog`.
@MainActor
private final class RecordingCommand: PlaybackEngineCommanding {
    let log: CallLog
    init(log: CallLog) { self.log = log }

    func play(at position: TrackPositionShape) async throws {
        log.record("command.play", args: ["timestamp": position.timestamp])
    }
}

/// Minimal `TrackPositionShape` — the readiness path consumes only `timestamp`.
private struct FakeReadyPosition: TrackPositionShape {
    let timestamp: Double
}

// MARK: - Tests

@MainActor
final class AudiobookReadinessPlaybackContractTests: XCTestCase {

    private var log: CallLog!
    private var appContainer: AppContainer!
    private var sut: AudiobookSessionManager!

    override func setUp() async throws {
        try await super.setUp()
        log = CallLog()
        appContainer = makeTestAppContainer()
        sut = AudiobookSessionManager(appContainer: appContainer)
    }

    override func tearDown() async throws {
        await sut?.stopPlayback(dismissPhoneUI: false)
        sut = nil
        appContainer = nil
        log = nil
        try await super.tearDown()
    }

    // MARK: - 1. Ready gate → play is DEFERRED behind the gate, then fires

    /// Locks the F-011 happy-path ORDER as byte-equal JSON:
    ///   1. `probe.start`
    ///   2. `command.play` (timestamp forwarded)   ← only AFTER the gate opens
    ///   3. `probe.stop`   (defer — leak prevention)
    ///
    /// A regression that issued `command.play` before `probe.start` (i.e.
    /// stopped deferring behind the gate — the pre-F-011 bug) reorders the
    /// snapshot; a regression that dropped the `defer { probe.stop() }` deletes
    /// the trailing line. Both keep the play COUNT at 1, so the existing
    /// count-based first-open tests do not distinguish them.
    func test_readyGate_deferredThenPlaysInOrder() async {
        let probe = RecordingProbe(log: log, behavior: .markReadyOnStart)
        let command = RecordingCommand(log: log)

        await sut.awaitReadinessAndIssueFirstPlay(
            bookId: "contract-ready",
            initialPosition: FakeReadyPosition(timestamp: 42.0),
            probe: probe,
            command: command,
            budget: 1.0
        )

        XCTAssertEqual(
            log.snapshot().map(\.method),
            ["probe.start", "command.play", "probe.stop"],
            "F-011 ready path: play is DEFERRED behind the gate, fires only after it opens, then probe stops (defer)."
        )
    }

    // MARK: - 2. Timeout gate → play is STRUCTURALLY ABSENT

    /// Locks the core F-011 invariant as a sequence: when the gate never opens,
    /// the recorded order is exactly
    ///   1. `probe.start`
    ///   2. `probe.stop`
    /// with NO `command.play` between them. The whole point of the fix is to
    /// NOT fire play against an uninitialized engine; encoding that as the
    /// ABSENCE of a `command.play` line makes an extraction that reintroduces a
    /// blind play (even a single one) drift the snapshot — where a `== 0` count
    /// assertion in isolation could be silently deleted during the move.
    ///
    /// (The timeout branch's session-level effects — `state = .error` +
    /// `errorPublisher.send(.playerCreationFailed)` — are count/value-covered by
    /// `AudiobookFirstOpenHangTests`; this snapshot pins the call SEQUENCE.)
    func test_timeoutGate_neverIssuesPlay() async {
        let probe = RecordingProbe(log: log, behavior: .neverReady)
        let command = RecordingCommand(log: log)

        await sut.awaitReadinessAndIssueFirstPlay(
            bookId: "contract-timeout",
            initialPosition: FakeReadyPosition(timestamp: 7.0),
            probe: probe,
            command: command,
            budget: 0.1  // short — keeps the suite fast while proving the wait
        )

        XCTAssertEqual(
            log.snapshot().map(\.method),
            ["probe.start", "probe.stop"],
            "F-011 timeout path: NO command.play between start and stop — never play against an uninitialized engine."
        )
    }
}
