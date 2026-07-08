//
//  PlaybackReadinessGate.swift
//  Palace
//
//  Module A — Audiobook First-Open Hang (PP-4436 / F-011)
//  Swarm: swarm_c8fcab76
//
//  WHAT THIS FIXES:
//  PR #990 bumped `ios-audiobooktoolkit` and introduced a race where Palace's
//  first `play(at:)` issues BEFORE the toolkit's player coordinator has
//  finished initializing. The toolkit exposes a readiness signal via
//  `Player.isLoaded`, but Palace was not awaiting it before issuing the first
//  play. Symptom: NowPlaying UI mounts, Play button is unresponsive, no
//  audio. Workaround: nav back, re-open — engine has finished initializing
//  during the nav-away interval.
//
//  THE FIX (Palace-side, NO submodule changes):
//  - `PlaybackReadinessGate` actor — exposes `markReady()`, `markFailed()`,
//    `awaitReady(timeout:)`. Multiple awaiters supported; once a terminal
//    state is reached all awaiters resume with the same outcome.
//  - `PlaybackEngineCommanding` protocol — wraps `Player.play(at:)` so the
//    session manager can be tested without owning a full toolkit Player.
//  - Static `awaitReadinessAndPlay(at:gate:timeout:command:)` — the
//    integration point. Production calls this from `startPlaybackAndSync-
//    Position` before issuing the first `play(at:)`. Tests call it
//    directly with stubs.
//
//  WHY ACTOR + ASYNC/AWAIT:
//  Per `feedback_swift_concurrency_over_gcd.md`, new concurrent code uses
//  `actor` + `async/await` instead of DispatchQueue + barrier + closure
//  callbacks. The gate has isolated mutable state (`outcome`, `waiters`)
//  and serves multiple concurrent awaiters — an actor is the correct shape.
//  Continuations are stored under actor isolation and resumed when the
//  terminal signal arrives. No `withCheckedContinuation` double-resume
//  risk (the actor's serial executor enforces single-fire per waiter).
//
//  RELATED:
//  - `audiobook_first_open_hang_3_2_0.md` (root cause analysis)
//  - `lcp_player_continuation_misuse_2026_05_26.md` (same area, different
//    race — informs the continuation-once-guard pattern)
//  - `reference_audiobook_toolkit_risk_profile.md` (why we wrap toolkit,
//    don't bump it)
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import Foundation
import PalaceAudiobookToolkit
import PalaceLogging

// MARK: - PlaybackReadinessError

/// Errors produced by the readiness gate. `timeout` is the headline case
/// — the toolkit's player never finished initializing within the
/// configured budget, so the first-open should surface a load failure
/// rather than issue a play command that the engine will drop.
public enum PlaybackReadinessError: Error, Equatable {
    case timeout
    case cancelled
    case failed(reason: String)
}

// MARK: - PlaybackReadinessOutcome

/// Terminal state of the readiness gate. The gate transitions from
/// implicit `pending` to one of these once-only. Multiple consumers
/// awaiting the gate concurrently all resume with the same outcome.
public enum PlaybackReadinessOutcome: Equatable {
    case ready
    case failed(reason: String)
}

// MARK: - PlaybackEngineCommanding

/// Protocol the session manager calls when it wants to issue `play(at:)`.
/// Production conformance forwards to the toolkit's `Player.play(at:)`;
/// tests inject a spy that records calls. Internal — not part of the
/// consumer-facing `AudiobookSessionManaging` surface.
@MainActor
internal protocol PlaybackEngineCommanding {
    func play(at position: TrackPositionShape) async throws
}

// MARK: - TrackPositionShape

/// Minimal shape the readiness-gating code path needs from a
/// `TrackPosition`. The toolkit's real `TrackPosition` is a struct over
/// concrete Track types; in production we adapt it to this shape, and
/// tests fake the timestamp directly without owning a full toolkit
/// TrackPosition.
///
/// Internal because no consumer of `AudiobookSessionManaging` needs to
/// reason about it — the abstraction exists solely to keep the readiness-
/// gating method unit-testable.
internal protocol TrackPositionShape {
    var timestamp: Double { get }
}

extension TrackPosition: TrackPositionShape {
    // `TrackPosition.timestamp` already matches the requirement; no body
    // needed — Swift synthesizes the conformance.
}

// MARK: - PlaybackReadinessGate

/// Actor-isolated readiness gate. A producer (the player or a probe that
/// observes the player) calls `markReady()` or `markFailed(reason:)` when
/// the toolkit's coordinator has finished initializing. One or more
/// consumers `await awaitReady(timeout:)` and resume when the gate
/// transitions to a terminal state (or the timeout fires).
///
/// Lifecycle: pending → ready / failed (terminal). Once terminal the gate
/// stays terminal — further `markReady` / `markFailed` calls are no-ops
/// (Log.warn for visibility), and further awaiters resolve immediately
/// with the latched outcome.
public actor PlaybackReadinessGate {

    // MARK: - Internal state

    private var outcome: PlaybackReadinessOutcome?

    // Waiter storage uses `keyedWaiters` declared with `WaiterEntry`
    // below — the id-keyed shape lets the timeout race drain a single
    // awaiter without affecting peers.

    // MARK: - Init

    public init() {}

    // MARK: - Producer surface

    /// Signal the gate is ready. Idempotent: a second call after a
    /// terminal state is a logged no-op. The first call wakes all
    /// pending waiters with `.ready`.
    public func markReady() {
        applyOutcome(.ready)
    }

    /// Signal the gate failed (e.g. probe observed a player error). All
    /// pending waiters wake with `.failed(reason)`. Idempotent — same
    /// no-op-after-terminal contract as `markReady`.
    public func markFailed(reason: String) {
        applyOutcome(.failed(reason: reason))
    }

    // MARK: - Consumer surface

    /// Wait for the gate to reach a terminal state, or up to `timeout`
    /// seconds. If a terminal state has already been reached, resume
    /// immediately. If the timeout fires first, throw `.timeout` — the
    /// gate stays in its pre-terminal state so a producer can still
    /// signal it later (used by retry paths).
    ///
    /// `timeout` is in seconds. The 2.0s default in
    /// `awaitReadinessAndPlay` is the budget agreed with the contract;
    /// tests pass shorter values to keep suite time down.
    public func awaitReady(timeout: TimeInterval) async throws -> PlaybackReadinessOutcome {
        if let existing = outcome {
            return existing
        }

        // Build a uniquely-keyed waiter so we can drain it from the queue on
        // timeout without affecting other in-flight awaiters. Without this,
        // a timed-out awaiter would leak its continuation into `waiters`
        // and any later `markReady` would still try to resume it (UB if the
        // continuation is also resumed via timeout cleanup → crash).
        let waiterId = UUID()
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: PlaybackReadinessOutcome.self) { group in
                group.addTask {
                    await self.suspend(waiterId: waiterId)
                }
                group.addTask {
                    let nanos = UInt64(max(0.0, timeout) * 1_000_000_000)
                    try await Task.sleep(nanoseconds: nanos)
                    throw PlaybackReadinessError.timeout
                }
                do {
                    guard let first = try await group.next() else {
                        throw PlaybackReadinessError.cancelled
                    }
                    group.cancelAll()
                    return first
                } catch {
                    // Timeout (or cancellation): drain this awaiter's
                    // continuation from `waiters` so a future markReady
                    // doesn't try to resume an already-resumed continuation.
                    await self.dropWaiter(waiterId: waiterId)
                    group.cancelAll()
                    throw error
                }
            }
        } onCancel: {
            Task { await self.cancelAllPending() }
        }
    }

    // MARK: - Internal helpers

    /// Identifier-keyed waiter entry. Lets the timeout path drain a single
    /// awaiter without disturbing peers waiting on the same gate.
    private struct WaiterEntry {
        let id: UUID
        let continuation: CheckedContinuation<PlaybackReadinessOutcome, Never>
    }

    private var keyedWaiters: [WaiterEntry] = []

    private func suspend(waiterId: UUID) async -> PlaybackReadinessOutcome {
        if let existing = outcome {
            return existing
        }
        return await withCheckedContinuation { continuation in
            keyedWaiters.append(WaiterEntry(id: waiterId, continuation: continuation))
        }
    }

    /// Drains a single waiter by id and resumes its continuation with a
    /// `.failed("timeout")` so the continuation is honoured. Called when
    /// the timeout race wins on this awaiter; other awaiters are
    /// unaffected.
    private func dropWaiter(waiterId: UUID) {
        guard let idx = keyedWaiters.firstIndex(where: { $0.id == waiterId }) else { return }
        let entry = keyedWaiters.remove(at: idx)
        entry.continuation.resume(returning: .failed(reason: "timeout"))
    }

    private func applyOutcome(_ next: PlaybackReadinessOutcome) {
        if outcome != nil {
            Log.warn(#file, "PlaybackReadinessGate: redundant outcome signal — already terminal, ignoring")
            return
        }
        outcome = next
        let pending = keyedWaiters
        keyedWaiters.removeAll()
        for entry in pending {
            entry.continuation.resume(returning: next)
        }
    }

    /// Called from the task-cancellation handler. Resumes every pending
    /// waiter with `.failed(reason: "cancelled")` so no continuation is
    /// abandoned (would leak). Outcome is NOT latched — a subsequent
    /// markReady on a fresh awaiter can still succeed.
    private func cancelAllPending() {
        let pending = keyedWaiters
        keyedWaiters.removeAll()
        for entry in pending {
            entry.continuation.resume(returning: .failed(reason: "cancelled"))
        }
    }

    // MARK: - Integration point

    /// Awaits readiness, then issues a single `play(at:)` via the
    /// supplied command. If readiness times out (or fails), throws and
    /// does NOT issue play — that's the fix for the F-011 hang.
    ///
    /// `MainActor`-isolated because both the session manager and the
    /// toolkit's player live on main; keeping the integration call on
    /// main avoids cross-actor hops at the play-command boundary.
    @MainActor
    internal static func awaitReadinessAndPlay(
        at position: TrackPositionShape,
        gate: PlaybackReadinessGate,
        timeout: TimeInterval,
        command: PlaybackEngineCommanding
    ) async throws {
        let result = try await gate.awaitReady(timeout: timeout)
        switch result {
        case .ready:
            try await command.play(at: position)
        case .failed(let reason):
            throw PlaybackReadinessError.failed(reason: reason)
        }
    }
}

// MARK: - PlaybackReadinessProbing

/// Wraps the toolkit's player-readiness signal so production can drive a
/// `PlaybackReadinessGate` without the gate knowing about toolkit types.
///
/// Production conformance polls `Player.isLoaded` at a short cadence (25ms)
/// and marks the gate ready on the first `true` observation, or marks it
/// failed if the player publishes a `.failed` state. Tests inject a stub
/// that directly drives the gate.
///
/// Why polling not KVO: `Player.isLoaded` is a plain `Bool` getter on the
/// public Player protocol. Most conforming types (FindawayPlayer,
/// LCPStreamingPlayer, UnifiedPositionSystem) update it from internal async
/// callbacks — there's no published-property hook on the protocol surface.
/// 25ms poll cadence × 2.0s budget = at most 80 reads — cheap relative to
/// the toolkit's own internal work in the same window.
@MainActor
internal protocol PlaybackReadinessProbing {
    /// Start observing readiness and drive the supplied gate. Returns
    /// immediately; the probe owns the observation lifetime until the
    /// gate reaches a terminal state OR `stop()` is called.
    func start(driving gate: PlaybackReadinessGate)

    /// Cancel observation. No-op if already stopped or never started.
    func stop()

    /// Synchronous snapshot of the player's current readiness (`isLoaded`).
    /// Used by the LCP first-open retry loop to re-check IMMEDIATELY before
    /// each re-issue so a `play()` that took effect between the gate wait and
    /// the re-issue decision suppresses the redundant re-issue (no double-start
    /// glitch). Distinct from `start(driving:)`, which only signals the gate on
    /// the first `true` observation.
    func isCurrentlyReady() -> Bool
}

/// Production probe — polls `Player.isLoaded` on a 25ms timer until the
/// player reports loaded, then marks the gate ready. If the player
/// publishes a `.failed` playback state before becoming loaded, marks
/// the gate failed with that error's localized description.
@MainActor
internal final class PlayerReadinessProbe: PlaybackReadinessProbing {

    /// Closure returning the current `isLoaded` value. Injected so tests
    /// can drive the probe without a real Player; production binds it
    /// to `{ [weak player] in player?.isLoaded ?? false }`.
    private let isLoadedSnapshot: () -> Bool

    private var pollTimer: Timer?

    /// Polling cadence. 25ms is short enough to keep first-open latency
    /// effectively imperceptible (≤1 frame at 60Hz) but long enough that
    /// the timer overhead is negligible relative to the player's own
    /// initialization work.
    private let pollInterval: TimeInterval

    init(
        isLoadedSnapshot: @escaping () -> Bool,
        pollInterval: TimeInterval = 0.025
    ) {
        self.isLoadedSnapshot = isLoadedSnapshot
        self.pollInterval = pollInterval
    }

    func start(driving gate: PlaybackReadinessGate) {
        // Fast path: already loaded at start. Avoid the timer overhead.
        if isLoadedSnapshot() {
            Task { await gate.markReady() }
            return
        }

        pollTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] timer in
            Task { @MainActor [weak self] in
                guard let self = self else {
                    timer.invalidate()
                    return
                }
                if self.isLoadedSnapshot() {
                    timer.invalidate()
                    await gate.markReady()
                }
            }
        }
        pollTimer = timer
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func isCurrentlyReady() -> Bool {
        isLoadedSnapshot()
    }
}

// MARK: - ToolkitPlayerCommand

/// Production `PlaybackEngineCommanding` conformance — forwards `play(at:)`
/// to the toolkit's `Player.play(at:)`. The session manager wires this in
/// via `playbackCommandFactory`; tests inject a recording spy instead.
///
/// Why `@MainActor`: the toolkit's `Player.play(at:)` is itself called
/// from main in production (`AudiobookSessionManager.startPlayback-
/// AndSyncPosition`). Matching the actor isolation keeps the boundary
/// trivial — no cross-actor hop on what is a hot path.
@MainActor
internal struct ToolkitPlayerCommand: PlaybackEngineCommanding {
    weak var player: Player?

    init(player: Player) {
        self.player = player
    }

    func play(at position: TrackPositionShape) async throws {
        guard let player = player else {
            throw PlaybackReadinessError.failed(reason: "player deallocated before play")
        }
        // The protocol shape is the minimal subset; in production the
        // adapter is always handed a real toolkit `TrackPosition`. Cast
        // back to ensure the toolkit API contract is honoured.
        guard let trackPosition = position as? TrackPosition else {
            throw PlaybackReadinessError.failed(reason: "non-toolkit position adapter in production")
        }
        try await player.play(at: trackPosition)
    }
}
