//
//  AdobeActivationDedupTests.swift
//  PalaceTests
//
//  Producer-level coverage for the borrow-time Adobe activation de-duplication
//  (PP-4952 / Crashlytics `ed05e903c2777582d68747b624e4f548`).
//
//  `AdobeActivationCoordinatorTests` proves the GATE works in isolation. This
//  file proves the gate is actually WIRED into the method borrows call —
//  `AdobeDRMService.ensureDeviceActivated`. That distinction matters here: the
//  recurring failure mode in this codebase is a green test on a helper the real
//  caller bypasses, so these tests drive the production entry point and assert
//  on how many times the RMSDK seam (`TPPDRMAuthorizing.authorize`) was entered.
//
//  Only the SDK seam is mocked. The guard order, licensor parsing, coalescing,
//  and account write-back are the real production code.
//

import XCTest
@testable import Palace

final class AdobeActivationDedupTests: XCTestCase {

    /// In-memory stand-in for the user account.
    ///
    /// Deliberately NOT a real `TPPUserAccount`. CLAUDE.md forbids tests
    /// touching real keychain state, and a concurrency test has a specific
    /// reason to care: `TPPUserAccount` serializes its credentials through a
    /// synchronous `accountInfoQueue.sync(flags: .barrier)`, so 10 racing
    /// activations would sit in blocking dispatch work on cooperative-pool
    /// threads. Plain locked storage here — no keychain, no dispatch, no
    /// blocking, so the test measures the coalescing and nothing else.
    private final class StubActivationAccount: AdobeActivationAccount, @unchecked Sendable {
        private let lock = NSLock()
        private var _userID: String?
        private var _deviceID: String?
        private let _licensor: [String: Any]?

        init(licensor: [String: Any]?, userID: String? = nil, deviceID: String? = nil) {
            self._licensor = licensor
            self._userID = userID
            self._deviceID = deviceID
        }

        var userID: String? { lock.withLock { _userID } }
        var deviceID: String? { lock.withLock { _deviceID } }
        var licensor: [String: Any]? { _licensor }
        func setUserID(_ id: String) { lock.withLock { _userID = id } }
        func setDeviceID(_ id: String) { lock.withLock { _deviceID = id } }
    }

    private var drm: TPPDRMAuthorizingMock!
    private var account: StubActivationAccount!
    private var coordinator: AdobeActivationCoordinator!
    private var service: AdobeDRMService!

    override func setUpWithError() throws {
        try super.setUpWithError()
        drm = TPPDRMAuthorizingMock()
        account = StubActivationAccount(
            licensor: ["vendor": "palace-vendor", "clientToken": "token-user|token-password"]
        )
        coordinator = AdobeActivationCoordinator()
        service = AdobeDRMService(activationCoordinator: coordinator)
    }

    override func tearDownWithError() throws {
        drm.reset()
        drm = nil
        account = nil
        coordinator = nil
        service = nil
        try super.tearDownWithError()
    }


    /// Runs `body` under a hard deadline.
    ///
    /// A concurrency test that can hang is worse than no test: it wedges the
    /// whole CI run instead of reporting a failure. Anything in this file that
    /// awaits a cross-task edge goes through here, so a lost wake-up surfaces as
    /// a named failure with the coordinator/mock state attached rather than as a
    /// silent park.
    /// Polls `condition` until true, or fails after `seconds`. A yield-loop on
    /// observable state cannot lose a wake-up the way a continuation barrier
    /// can, and on timeout it fails fast instead of parking the CI run.
    private func waitUntil(_ what: String,
                           seconds: Double = 10,
                           file: StaticString = #filePath,
                           line: UInt = #line,
                           _ condition: @escaping @Sendable () async -> Bool) async {
        let limit = Date().addingTimeInterval(seconds)
        while Date() < limit {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail("timed out after \(seconds)s waiting for \(what)", file: file, line: line)
    }


    /// Thread-safe one-shot outcome holder, so a call can be awaited under a
    /// deadline instead of unbounded. Without this the wedge test PARKS when its
    /// guard regresses — verified: deleting the deadline hangs the run — and a
    /// hung CI job reports nothing at all.
    private final class OutcomeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        private var _error: Error?
        var isSet: Bool { lock.withLock { done } }
        var error: Error? { lock.withLock { _error } }
        func set(_ e: Error?) { lock.withLock { done = true; _error = e } }
    }

    // MARK: - The crash this fixes

    func test_ensureDeviceActivated_whileOneBorrowIsActivating_aSecondBorrowNeverEntersAdobe() async throws {
        // The reported crash: DownloadStartCoordinator started the same borrow
        // twice 2.3s apart and both reached `authorize`, corrupting RMSDK's
        // shared C++ heap. This is that scenario, deterministically.
        drm.shouldDeferAuthorize = true
        let service = self.service!
        let drm = self.drm!
        let account = self.account!
        let coordinator = self.coordinator!

        let first = Task {
            try await service.ensureDeviceActivated(authorizer: { [drm] in drm }, userAccount: account, isDRMAvailable: true)
        }
        await waitUntil("the first borrow to reach Adobe RMSDK") { drm.authorizeCallCount == 1 }

        let second = Task {
            try await service.ensureDeviceActivated(authorizer: { [drm] in drm }, userAccount: account, isDRMAvailable: true)
        }
        await waitUntil("the second borrow to coalesce") { await coordinator.coalescedCount == 1 }

        drm.completeDeferredAuthorize(success: true)
        try await first.value
        try await second.value

        XCTAssertEqual(drm.authorizeCallCount, 1,
                       "a borrow arriving during an in-flight activation must never enter Adobe RMSDK a second time")
        let attempts = await coordinator.activationAttemptCount
        XCTAssertEqual(attempts, 1)
    }

    func test_ensureDeviceActivated_whenActivationFails_theCoalescedBorrowSeesTheFailure() async throws {
        drm.shouldDeferAuthorize = true
        let service = self.service!
        let drm = self.drm!
        let account = self.account!
        let coordinator = self.coordinator!

        let first = Task {
            try await service.ensureDeviceActivated(authorizer: { [drm] in drm }, userAccount: account, isDRMAvailable: true)
        }
        await waitUntil("the first borrow to reach Adobe RMSDK") { drm.authorizeCallCount == 1 }

        let second = Task {
            try await service.ensureDeviceActivated(authorizer: { [drm] in drm }, userAccount: account, isDRMAvailable: true)
        }
        await waitUntil("the second borrow to coalesce") { await coordinator.coalescedCount == 1 }

        drm.completeDeferredAuthorize(success: false)

        var secondError: Error?
        do { try await second.value } catch { secondError = error }
        _ = try? await first.value

        XCTAssertEqual(drm.authorizeCallCount, 1,
                       "a failed activation must not be retried by the coalesced caller — that reintroduces the concurrent RMSDK entry")
        guard case .drm(.authenticationFailed)? = secondError as? PalaceError else {
            return XCTFail("the coalesced borrow must surface the activation failure, got \(String(describing: secondError))")
        }
    }


    // MARK: - The wedge guard, against its REAL shape

    func test_ensureDeviceActivated_whenRMSDKNeverCallsBack_timesOutAndFreesTheSlot() async throws {
        // The defect this reproduces: RMSDK accepts the call and never invokes
        // the completion block. An earlier revision "bounded" this by racing the
        // work inside a task group, which CANNOT unwind a non-resuming
        // continuation — the group awaits its children on exit. That guard
        // passed its test only because the test stood in a cancellable
        // `Task.sleep`. Here the completion is genuinely never fired, which is
        // the production shape.
        drm.shouldDeferAuthorize = true          // captured, and never drained
        let service = self.service!
        let drm = self.drm!
        let account = self.account!
        let coordinator = self.coordinator!

        let outcome = OutcomeBox()
        let call = Task {
            do {
                try await service.ensureDeviceActivated(authorizer: { drm },
                                                        userAccount: account,
                                                        isDRMAvailable: true,
                                                        timeout: 0.3)
                outcome.set(nil)
            } catch { outcome.set(error) }
        }
        // Bounded: if the deadline guard regresses this call never returns, and
        // an unbounded await here would wedge CI instead of failing it.
        await waitUntil("the timed-out activation to return", seconds: 10) { outcome.isSet }
        call.cancel()
        guard outcome.isSet else { return }
        guard case .drm(.adobeError)? = outcome.error as? PalaceError else {
            return XCTFail("expected PalaceError.drm(.adobeError), got \(String(describing: outcome.error))")
        }

        // The decisive assertion — the one the old guard could never have made.
        // The slot must be free afterwards, or every later borrow in the process
        // coalesces onto a dead task and hangs forever.
        drm.shouldDeferAuthorize = false
        try await service.ensureDeviceActivated(authorizer: { [drm] in drm },
                                                userAccount: account,
                                                isDRMAvailable: true)
        let attempts = await coordinator.activationAttemptCount
        XCTAssertEqual(attempts, 2, "a timed-out activation must release the single-flight slot for the next borrow")
    }

    // MARK: - Success write-back

    func test_ensureDeviceActivated_onSuccess_persistsTheUserAndDeviceIDs() async throws {
        // Without this, deleting the setUserID/setDeviceID write-back leaves the
        // whole suite green — and a lost deviceID means the next borrow
        // re-activates, re-opening the very race this PR closes.
        try await service.ensureDeviceActivated(authorizer: { [drm] in drm },
                                                userAccount: account,
                                                isDRMAvailable: true)

        // The write hops through TPPMainThreadRun.asyncIfNeeded, so it can land
        // after the call returns; poll rather than assert instantaneously.
        await waitUntil("the activation credentials to be persisted") { [account, drm] in
            account?.userID == drm?.userID && account?.deviceID == drm?.deviceID
        }
        XCTAssertEqual(account.userID, drm.userID)
        XCTAssertEqual(account.deviceID, drm.deviceID)
    }

    // MARK: - Guard order (the coalescer must sit BEHIND these)

    func test_ensureDeviceActivated_whenDeviceAlreadyActivated_neverEntersAdobe() async throws {
        account.setUserID("existing-user")
        account.setDeviceID("existing-device")
        drm.isUserAuthorizedReturnValue = true

        try await service.ensureDeviceActivated(authorizer: { [drm] in drm },
                                                userAccount: account,
                                                isDRMAvailable: true)

        XCTAssertEqual(drm.authorizeCallCount, 0,
                       "an already-activated device must short-circuit before touching RMSDK — this is what keeps us from burning a patron's activation")
        let attempts = await coordinator.activationAttemptCount
        XCTAssertEqual(attempts, 0, "the fast path must not even claim the single-flight slot")
    }

    func test_ensureDeviceActivated_whenDRMUnavailable_throwsWithoutEnteringAdobe() async {
        do {
            try await service.ensureDeviceActivated(authorizer: { [drm] in drm },
                                                    userAccount: account,
                                                    isDRMAvailable: false)
            XCTFail("expected .noActivation when the Adobe certificate is missing or expired")
        } catch {
            guard case .drm(.noActivation)? = error as? PalaceError else {
                return XCTFail("expected PalaceError.drm(.noActivation), got \(error)")
            }
        }

        XCTAssertEqual(drm.authorizeCallCount, 0)
        let attempts = await coordinator.activationAttemptCount
        XCTAssertEqual(attempts, 0, "the DRM-availability guard must run before the single-flight slot is claimed")
    }

    func test_ensureDeviceActivated_withoutLicensorCredentials_throwsWithoutEnteringAdobe() async {
        let bare = StubActivationAccount(licensor: nil)

        do {
            try await service.ensureDeviceActivated(authorizer: { [drm] in drm },
                                                    userAccount: bare,
                                                    isDRMAvailable: true)
            XCTFail("expected .noActivation with no stored licensor")
        } catch {
            guard case .drm(.noActivation)? = error as? PalaceError else {
                return XCTFail("expected PalaceError.drm(.noActivation), got \(error)")
            }
        }

        XCTAssertEqual(drm.authorizeCallCount, 0)
    }

    // MARK: - Sequential borrows still work

    func test_ensureDeviceActivated_afterAFailedAttempt_aLaterBorrowCanActivate() async throws {
        drm.authorizeShouldSucceed = false
        do {
            try await service.ensureDeviceActivated(authorizer: { [drm] in drm },
                                                    userAccount: account,
                                                    isDRMAvailable: true)
            XCTFail("expected the first activation to fail")
        } catch {
            // expected
        }

        // The patron taps Borrow again. The gate must not have latched.
        drm.authorizeShouldSucceed = true
        try await service.ensureDeviceActivated(authorizer: { [drm] in drm },
                                                userAccount: account,
                                                isDRMAvailable: true)

        XCTAssertEqual(drm.authorizeCallCount, 2,
                       "a retry after a failed activation must reach RMSDK — the gate coalesces concurrent callers, it must not block sequential ones")
    }
}
