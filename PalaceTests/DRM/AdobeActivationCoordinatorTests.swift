//
//  AdobeActivationCoordinatorTests.swift
//  PalaceTests
//
//  Contract for the Adobe device-activation single-flight gate (PP-4952).
//
//  The defect these lock down: Adobe's RMSDK is legacy C++ and aborts the
//  process when two `authorize` calls run concurrently (Crashlytics
//  `ed05e903c2777582d68747b624e4f548`, new in 3.2.3). `AdobeActivationCoordinator`
//  is the gate that makes a second concurrent caller wait rather than enter the
//  SDK. Every test here fails if the coalescing branch is removed — see the
//  reintroduction check in the PR body.
//
//  Determinism note: exactly TWO callers per test, never N racers. The first
//  parks inside its work so the activation is genuinely in flight for the whole
//  of the second's lifetime; the second is then observed to coalesce. Progress
//  is established by polling plain actor state (`coalescedCount`) under a
//  bounded yield-loop, never by sleeping and never by a continuation barrier.
//
//  This shape is deliberate. An earlier N-racer version synchronised through a
//  continuation barrier that could lose a wake-up, which PARKED the suite rather
//  than failing it — the worst outcome for CI, since a hung run reports nothing
//  at all. A yield-loop cannot lose a wake-up and fails fast with the counters
//  attached. Wall-clock sleeps are also out: they starve under parallel
//  sim-clone oversubscription, a documented source of flakes in this suite.
//

import XCTest
@testable import Palace

final class AdobeActivationCoordinatorTests: XCTestCase {

    /// Counts how many times the underlying work actually ran, across threads.
    private final class WorkCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        var count: Int { lock.withLock { _count } }
        func increment() { lock.withLock { _count += 1 } }
    }

    private struct ActivationFailure: Error, Equatable {
        let id: Int
    }


    /// Polls `condition` until true, or fails after `seconds`.
    ///
    /// Deliberately a poll on plain observable actor state rather than a
    /// continuation barrier. The barrier this replaced had a lost wake-up that
    /// PARKED the suite rather than failing it, which is the worst possible
    /// outcome for CI: a hung run reports nothing at all. A yield-loop cannot
    /// lose a wake-up, and on timeout this fails fast with the counters shown.
    private func waitUntil(_ what: String,
                           seconds: Double = 10,
                           file: StaticString = #filePath,
                           line: UInt = #line,
                           _ condition: @escaping @Sendable () async -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail("timed out after \(seconds)s waiting for \(what)", file: file, line: line)
    }

    // MARK: - The fix

    func test_activate_whileOneIsInFlight_aSecondCallerCoalescesInsteadOfEnteringRMSDK() async throws {
        let coordinator = AdobeActivationCoordinator()
        let counter = WorkCounter()
        let firstEnteredWork = AsyncGate()
        let releaseFirstWork = AsyncGate()

        // A claims the slot and parks INSIDE its work, so the activation is
        // genuinely in flight for the whole of B's lifetime.
        let a = Task {
            try await coordinator.activate {
                counter.increment()
                await firstEnteredWork.open()
                await releaseFirstWork.wait()
            }
        }
        await waitUntil("the first activation to be in flight") { await firstEnteredWork.isOpened }

        // B arrives while A holds the slot. It must NOT enter the SDK.
        let b = Task { try await coordinator.activate { counter.increment() } }
        await waitUntil("the second caller to coalesce") { await coordinator.coalescedCount == 1 }

        await releaseFirstWork.open()
        try await a.value
        try await b.value

        XCTAssertEqual(counter.count, 1,
                       "a borrow arriving during an in-flight activation must NOT run a second one — two concurrent entries into Adobe's RMSDK is the heap corruption that kills the app")
        let attempts = await coordinator.activationAttemptCount
        XCTAssertEqual(attempts, 1, "only one caller may claim the single-flight slot")
    }

    func test_activate_whenTheInFlightActivationFails_theCoalescedCallerSeesThatFailure() async throws {
        let coordinator = AdobeActivationCoordinator()
        let firstEnteredWork = AsyncGate()
        let releaseFirstWork = AsyncGate()

        let a = Task {
            try await coordinator.activate {
                await firstEnteredWork.open()
                await releaseFirstWork.wait()
                throw ActivationFailure(id: 7)
            }
        }
        await waitUntil("the first activation to be in flight") { await firstEnteredWork.isOpened }

        let b = Task { try await coordinator.activate { XCTFail("coalesced caller must not run its own work") } }
        await waitUntil("the second caller to coalesce") { await coordinator.coalescedCount == 1 }

        await releaseFirstWork.open()

        var bError: Error?
        do { try await b.value } catch { bError = error }
        _ = try? await a.value

        XCTAssertEqual(bError as? ActivationFailure, ActivationFailure(id: 7),
                       "a coalesced caller must receive the in-flight activation's error, not silently succeed")
    }

    // MARK: - The slot must free up again

    func test_activate_afterSuccess_theNextCallerRunsAFreshActivation() async throws {
        let coordinator = AdobeActivationCoordinator()
        let counter = WorkCounter()

        try await coordinator.activate { counter.increment() }
        try await coordinator.activate { counter.increment() }

        XCTAssertEqual(counter.count, 2,
                       "sequential activations must each run — the gate coalesces concurrent callers, it does not cache the result forever")
    }

    func test_activate_afterFailure_theNextCallerMayRetry() async {
        let coordinator = AdobeActivationCoordinator()
        let counter = WorkCounter()

        do {
            try await coordinator.activate {
                counter.increment()
                throw ActivationFailure(id: 1)
            }
            XCTFail("expected the activation to throw")
        } catch {
            // expected
        }

        // A failed activation must not poison the slot: a patron who retries the
        // borrow has to be able to activate.
        do {
            try await coordinator.activate { counter.increment() }
        } catch {
            XCTFail("a failed activation must release the slot, got \(error)")
        }

        XCTAssertEqual(counter.count, 2)
    }

    // MARK: - Bounding is NOT this type's job
    //
    // The wedge guard moved to the continuation in `ensureDeviceActivated`, and
    // is tested against a genuinely never-resuming completion in
    // `AdobeActivationDedupTests.test_ensureDeviceActivated_whenRMSDKNeverCallsBack_...`.
    // A test here would have to stand in a cancellable sleep for the hang, which
    // is exactly the fixture mismatch that let the previous inert guard ship.
}

/// Minimal await-able gate: callers suspend on `wait()` until `open()` is
/// called, after which it stays open. Used to hold an activation in flight for
/// a deterministic race.
private actor AsyncGate {
    private var isOpen = false
    var isOpened: Bool { isOpen }
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // Re-check inside the body: `open()` can land between the early
            // return above and this closure running, and a blind append would
            // park this caller on a gate that is already open.
            if isOpen {
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}
