//
//  TPPDRMAuthorizingMock.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 10/14/20.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

import Foundation
import XCTest
@testable import Palace

/// `@unchecked Sendable`: `TPPDRMAuthorizing` completions are `@Sendable`, so this
/// mock is captured across concurrency domains in concurrent DRM tests. It HONORS
/// that contract: every mutable stored property is guarded by a single `NSLock`
/// (mirroring `TPPBookRegistryMock`). `let` constants and computed accessors are
/// inherently thread-safe and are left unguarded.
class TPPDRMAuthorizingMock: NSObject, TPPDRMAuthorizing, @unchecked Sendable {

    private let lock = NSLock()

    private var _workflowsInProgress = false
    var workflowsInProgress: Bool {
        get { lock.withLock { _workflowsInProgress } }
        set { lock.withLock { _workflowsInProgress = newValue } }
    }

    let deviceID = "drmDeviceID"
    let userID = "drmUserID"

    // MARK: - Configurable Test Properties

    /// Controls what `isUserAuthorized` returns. Default is `true`.
    private var _isUserAuthorizedReturnValue = true
    var isUserAuthorizedReturnValue: Bool {
        get { lock.withLock { _isUserAuthorizedReturnValue } }
        set { lock.withLock { _isUserAuthorizedReturnValue = newValue } }
    }

    /// Tracks whether `authorize` was called.
    private var _authorizeWasCalled = false
    var authorizeWasCalled: Bool {
        get { lock.withLock { _authorizeWasCalled } }
        set { lock.withLock { _authorizeWasCalled = newValue } }
    }

    /// Counts how many times `authorize` was called.
    private var _authorizeCallCount = 0
    var authorizeCallCount: Int {
        get { lock.withLock { _authorizeCallCount } }
        set { lock.withLock { _authorizeCallCount = newValue } }
    }

    /// The (vendorID, username, password) triple of the most recent `authorize`.
    ///
    /// Without this a test can only assert THAT activation happened, never
    /// WITH WHAT — so "activated with the freshly minted licensor" and
    /// "activated with the stale stored one" are the same observation, and
    /// PP-3649's whole fix is unfalsifiable. Recorded rather than subclassed
    /// because three suites need it.
    private var _lastAuthorizeArgs: (vendorID: String?, username: String?, password: String?)?
    var lastAuthorizeArgs: (vendorID: String?, username: String?, password: String?)? {
        lock.withLock { _lastAuthorizeArgs }
    }

    /// When true, `authorize` captures the completion instead of calling it
    /// immediately. Call `completeDeferredAuthorize()` to fire the callback.
    /// Lets a test hold ONE activation in flight while other callers race in —
    /// the setup the Adobe single-flight de-dup tests need (PP-4952).
    private var _shouldDeferAuthorize = false
    var shouldDeferAuthorize: Bool {
        get { lock.withLock { _shouldDeferAuthorize } }
        set { lock.withLock { _shouldDeferAuthorize = newValue } }
    }

    /// Controls whether the (non-deferred) `authorize` reports success.
    private var _authorizeShouldSucceed = true
    var authorizeShouldSucceed: Bool {
        get { lock.withLock { _authorizeShouldSucceed } }
        set { lock.withLock { _authorizeShouldSucceed = newValue } }
    }

    /// ALL captured authorize completions, not just the most recent one. If a
    /// de-duplication regression lets N concurrent activations through, every
    /// one of them parks here and `completeDeferredAuthorize` releases them all
    /// — so the test fails on its assertion instead of hanging on the N-1
    /// callers nobody resumed. A hang is a much worse failure signal than a
    /// count mismatch.
    private var _deferredAuthCompletions: [@Sendable (Bool, Error?, String?, String?) -> Void] = []

    /// Once `completeDeferredAuthorize` has fired, deferral STOPS: any later
    /// `authorize` completes immediately with the same outcome. Drain-and-stay-
    /// open, like a latch. Without this a de-duplication regression deadlocks
    /// the test — the extra concurrent activations arrive after the drain and
    /// park on a completion nobody will ever fire — and a deadlock tells you far
    /// less than `authorizeCallCount` reading 10 instead of 1.
    private var _authorizeDeferralDrained = false
    private var _drainedOutcome: (success: Bool, error: Error?) = (true, nil)

    /// Fires every previously captured authorization completion.
    func completeDeferredAuthorize(success: Bool = true, error: Error? = nil) {
        let completions: [@Sendable (Bool, Error?, String?, String?) -> Void] = lock.withLock {
            let c = _deferredAuthCompletions
            _deferredAuthCompletions = []
            _authorizeDeferralDrained = true
            _drainedOutcome = (success, error)
            return c
        }
        for completion in completions {
            completion(success, error, success ? deviceID : nil, success ? userID : nil)
        }
    }

    /// Tracks whether `deauthorize` was called.
    private var _deauthorizeWasCalled = false
    var deauthorizeWasCalled: Bool {
        get { lock.withLock { _deauthorizeWasCalled } }
        set { lock.withLock { _deauthorizeWasCalled = newValue } }
    }

    /// Counts how many times `deauthorize` was called.
    private var _deauthorizeCallCount = 0
    var deauthorizeCallCount: Int {
        get { lock.withLock { _deauthorizeCallCount } }
        set { lock.withLock { _deauthorizeCallCount = newValue } }
    }

    /// When true, `deauthorize` captures the completion instead of calling it
    /// immediately. Call `completeDeferredDeauthorize()` to fire the callback.
    private var _shouldDeferDeauthorize = false
    var shouldDeferDeauthorize: Bool {
        get { lock.withLock { _shouldDeferDeauthorize } }
        set { lock.withLock { _shouldDeferDeauthorize = newValue } }
    }

    /// Captured deauthorization completion for simulating slow DRM callbacks.
    private var _deferredDeauthCompletion: ((Bool, Error?) -> Void)?
    private(set) var deferredDeauthCompletion: ((Bool, Error?) -> Void)? {
        get { lock.withLock { _deferredDeauthCompletion } }
        set { lock.withLock { _deferredDeauthCompletion = newValue } }
    }

    /// Waits for `deauthorize` to be called, and FAILS rather than hangs if it
    /// never is.
    ///
    /// A polling loop, deliberately, and the boring choice is the point. The
    /// unbounded `withCheckedContinuation` this replaces held a run open for
    /// **ten hours** at 0% CPU on 2026-09-10 when a production change stopped
    /// reaching `deauthorize`.
    ///
    /// The first repair was worse than the bug: a `withTaskGroup` racing the
    /// continuation against `Task.sleep`. That cannot work, and review caught
    /// it. `withTaskGroup` awaits every child before it returns, and a
    /// `CheckedContinuation` that is never resumed does not observe
    /// cancellation — so when the sleep leg won, the group could not drain and
    /// the call hung exactly as before, with the `XCTFail` unreachable. A
    /// timeout that cannot fire reports the same thing as no timeout.
    ///
    /// Polling has no such failure mode: every iteration re-reads the flag and
    /// the loop is bounded by wall clock. `XCTFail` does not halt the caller,
    /// so on timeout this returns and lets the caller's own assertions run
    /// against the un-deauthorized state and say something more specific.
    func _awaitDeauthorizeCalledForTesting(timeout: TimeInterval = 5,
                                           file: StaticString = #filePath,
                                           line: UInt = #line) async {
        if await _awaitDeauthorizeCalledOrTimeout(timeout: timeout) { return }
        XCTFail("deauthorize() was never called within \(timeout)s — the sign-out path returned before reaching it",
                file: file, line: line)
    }

    /// The same wait, reporting nothing.
    ///
    /// - Returns: `true` if `deauthorize` was called within `timeout`, `false`
    ///   if the deadline passed.
    ///
    /// Split out so the deadline can be PROVEN to fire without recording a
    /// failure. The proof test used to drive the asserting wrapper under
    /// `XCTExpectFailure`, and that is not sound: `XCTExpectFailure` installs an
    /// issue matcher on the current execution context, the `XCTFail` above is
    /// reached after an `await` that may resume on a different thread, and
    /// whether the matcher is still in scope then depends on scheduling. It
    /// passed run alone and failed in a fifteen-suite run — the same code, twice,
    /// with opposite verdicts. A guard whose own proof is order-dependent proves
    /// nothing, so the proof now drives a function that returns its verdict
    /// instead of reporting it.
    func _awaitDeauthorizeCalledOrTimeout(timeout: TimeInterval) async -> Bool {
        let condition = { self.lock.withLock { self._deauthorizeWasCalled } }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 2_000_000)  // 2ms
        }
        // Re-read AFTER the loop rather than reporting `false` outright: a
        // `deauthorize` that lands between the last poll and the deadline did
        // happen, and calling that a timeout would be a manufactured failure.
        return condition()
    }

    func isUserAuthorized(_ userID: String!, withDevice device: String!) -> Bool {
        return isUserAuthorizedReturnValue
    }

    func authorize(withVendorID vendorID: String!, username: String!, password: String!, completion: (@Sendable (Bool, Error?, String?, String?) -> Void)!) {
        // Flag, count, and park-decision under ONE lock acquisition so tests
        // polling `authorizeCallCount` never observe a torn state.
        let didPark: Bool = lock.withLock {
            _authorizeWasCalled = true
            _authorizeCallCount += 1
            _lastAuthorizeArgs = (vendorID, username, password)
            let shouldPark = _shouldDeferAuthorize && !_authorizeDeferralDrained
            if shouldPark {
                _deferredAuthCompletions.append(completion)
            }
            return shouldPark
        }

        guard !didPark else { return }

        let drained: (success: Bool, error: Error?)? = lock.withLock {
            _authorizeDeferralDrained ? _drainedOutcome : nil
        }
        if let drained {
            completion(drained.success, drained.error,
                       drained.success ? deviceID : nil, drained.success ? userID : nil)
            return
        }

        if authorizeShouldSucceed {
            completion(true, nil, deviceID, userID)
        } else {
            completion(false,
                       NSError(domain: "AdobeDRM", code: -1,
                               userInfo: [NSLocalizedDescriptionKey: "mock activation failure"]),
                       nil, nil)
        }
    }

    func deauthorize(withUsername username: String!, password: String!, userID: String!, deviceID: String!, completion: (@Sendable (Bool, Error?) -> Void)!) {
        // One lock acquisition for both writes: `_awaitDeauthorizeCalledForTesting`
        // polls this flag and must never observe the count without the flag.
        lock.withLock {
            _deauthorizeWasCalled = true
            _deauthorizeCallCount += 1
        }

        if shouldDeferDeauthorize {
            deferredDeauthCompletion = completion
        } else {
            completion(true, nil)
        }
    }

    /// Fires the previously captured deauthorization completion.
    func completeDeferredDeauthorize(success: Bool = true, error: Error? = nil) {
        deferredDeauthCompletion?(success, error)
        deferredDeauthCompletion = nil
    }

    /// Resets all tracking properties. Call in test tearDown.
    func reset() {
        isUserAuthorizedReturnValue = true
        authorizeWasCalled = false
        authorizeCallCount = 0
        deauthorizeWasCalled = false
        deauthorizeCallCount = 0
        shouldDeferDeauthorize = false
        shouldDeferAuthorize = false
        authorizeShouldSucceed = true
        deferredDeauthCompletion = nil
        lock.withLock {
            _lastAuthorizeArgs = nil
            _deferredAuthCompletions = []
            _authorizeDeferralDrained = false
            _drainedOutcome = (true, nil)
        }
    }
}
