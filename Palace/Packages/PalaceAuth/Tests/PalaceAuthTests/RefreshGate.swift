//
//  RefreshGate.swift
//  PalaceAuthTests
//
//  Holds a stubbed refresh open so a single-flight test can put a second
//  caller provably inside the in-flight window. Without it, a stub that
//  returns immediately lets the first flight finish and clear its slot
//  before the second caller reaches the coordinator, and the second caller
//  then correctly starts a flight of its own.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
@testable import PalaceAuth

actor RefreshGate {
    private var entryCount = 0
    private var isReleased = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    /// Whether any stub call has entered the gate. Polled with a deadline
    /// rather than awaited, so a refresh that never reaches the stub fails
    /// the test by name instead of suspending it forever.
    var hasEntered: Bool { entryCount > 0 }

    /// Called by a stub collaborator. Records the entry, then suspends until
    /// `release()` — the refresh stays in flight for as long as the test needs.
    func enterAndWait() async {
        entryCount += 1
        guard !isReleased else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func release() {
        isReleased = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

/// Polls `condition` every millisecond until it holds or `timeout` elapses,
/// and returns whether it held.
func awaitCondition(
    timeout: TimeInterval = 5,
    _ condition: () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return await condition()
}

/// Outcome of `refreshWithSecondCallerJoiningFirst`. `second` is nil when the
/// first refresh never reached the stub, because the second caller is then
/// never started.
struct JoinedRefreshRun {
    let first: Result<Void, AuthRefreshCancellation>
    let second: Result<Void, AuthRefreshCancellation>?
    let entered: Bool
    let joined: Bool
}

/// Two refreshes where the second caller provably joins the first: the gate
/// holds the first flight open until the coordinator reports the join, then
/// releases it.
///
/// Both waits are bounded. If the first refresh never reaches the stub — it
/// was routed elsewhere, or short-circuited — `entered` is false; if the
/// second caller never joins, `joined` is false. The gate is released on every
/// path before any refresh is awaited, so neither case can leave the test
/// suspended.
func refreshWithSecondCallerJoiningFirst(
    _ coordinator: AuthCoordinator,
    gate: RefreshGate,
    reason: ReauthReason = .expiredToken
) async -> JoinedRefreshRun {
    let first = Task { await coordinator.refreshCredentialsIfNeeded(reason: reason) }
    guard await awaitCondition({ await gate.hasEntered }) else {
        await gate.release()
        return JoinedRefreshRun(first: await first.value, second: nil, entered: false, joined: false)
    }
    let second = Task { await coordinator.refreshCredentialsIfNeeded(reason: reason) }
    let joined = await awaitCondition { await coordinator.joinedInFlightRefreshCount == 1 }
    await gate.release()
    return JoinedRefreshRun(first: await first.value, second: await second.value, entered: true, joined: joined)
}
