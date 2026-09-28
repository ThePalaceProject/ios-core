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
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    /// Called by a stub collaborator. Records the entry, then suspends until
    /// `release()` — the refresh stays in flight for as long as the test needs.
    func enterAndWait() async {
        entryCount += 1
        entryWaiters.forEach { $0.resume() }
        entryWaiters.removeAll()
        guard !isReleased else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    /// Suspends until at least one stub call has entered the gate.
    func waitUntilEntered() async {
        guard entryCount == 0 else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        isReleased = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

/// Polls `condition` until it holds or `timeout` elapses. Returns whether it
/// held, so the caller can release any gate before asserting — a failed wait
/// must not leave a stub suspended and hang the test.
func awaitCondition(
    timeout: TimeInterval = 5,
    _ condition: () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        await Task.yield()
    }
    return await condition()
}

/// Two refreshes where the second caller provably joins the first: the gate
/// holds the first flight open until the coordinator reports the join, then
/// releases it. `joined` is false if the join was never observed; the gate
/// is released either way so a failed run cannot hang.
func refreshWithSecondCallerJoiningFirst(
    _ coordinator: AuthCoordinator,
    gate: RefreshGate,
    reason: ReauthReason = .expiredToken
) async -> (
    first: Result<Void, AuthRefreshCancellation>,
    second: Result<Void, AuthRefreshCancellation>,
    joined: Bool
) {
    let first = Task { await coordinator.refreshCredentialsIfNeeded(reason: reason) }
    await gate.waitUntilEntered()
    let second = Task { await coordinator.refreshCredentialsIfNeeded(reason: reason) }
    let joined = await awaitCondition { await coordinator.joinedInFlightRefreshCount == 1 }
    await gate.release()
    return (await first.value, await second.value, joined)
}
