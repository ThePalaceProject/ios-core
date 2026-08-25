//
//  AdobeActivationLicensorGraceTests.swift
//  PalaceTests
//
//  Regression coverage for the borrow-vs-licensor-save race observed while
//  validating the Wipro 2.0 DRM connector (PP-5025).
//
//  Observed on device and simulator, in this order:
//
//      12:09:38.942  No Adobe DRM licensor credentials stored — cannot activate
//      12:09:38.942  Borrow failed: Device not activated
//      12:09:51.885  Saving DRM licensor credentials (activation deferred to borrow time)
//
//  The licensor arrives on the user-profile-document leg of sign-in, which can
//  land AFTER the auth gate has already released the queued borrow. The borrow
//  read `userAccount.licensor`, found nil, and failed outright — thirteen
//  seconds before the credentials it needed actually arrived. Borrowing again
//  afterwards worked, which is what made this look like a DRM/connector fault
//  rather than an ordering bug: it is neither, and it reproduces regardless of
//  which connector is installed.
//
//  The fix gives the licensor a bounded grace period instead of failing on the
//  first read. These tests pin both halves of that: a licensor that shows up
//  late is waited for, and a licensor that never shows up still fails with
//  `.noActivation` — so the guard is delayed, never deleted.
//

import XCTest
@testable import Palace

final class AdobeActivationLicensorGraceTests: XCTestCase {

    /// In-memory account whose `licensor` can start absent and appear later,
    /// mimicking the profile-document leg completing after the borrow begins.
    /// Deliberately not a real `TPPUserAccount` — CLAUDE.md forbids tests
    /// touching keychain state.
    private final class LateLicensorAccount: AdobeActivationAccount, @unchecked Sendable {
        private let lock = NSLock()
        private var _userID: String?
        private var _deviceID: String?
        private var _licensor: [String: Any]?
        private var readsUntilAvailable: Int
        private(set) var licensorReadCount = 0

        /// - Parameter appearsAfterReads: how many nil reads to serve before the
        ///   credentials "arrive". `0` means present from the outset;
        ///   `Int.max` means never.
        init(appearsAfterReads: Int,
             licensor: [String: Any]? = ["vendor": "palace-vendor",
                                         "clientToken": "token-user|token-password"],
             userID: String? = nil,
             deviceID: String? = nil) {
            self.readsUntilAvailable = appearsAfterReads
            self._licensor = licensor
            self._userID = userID
            self._deviceID = deviceID
        }

        var userID: String? { lock.withLock { _userID } }
        var deviceID: String? { lock.withLock { _deviceID } }

        var licensor: [String: Any]? {
            lock.withLock {
                licensorReadCount += 1
                guard readsUntilAvailable != Int.max else { return nil }
                if licensorReadCount > readsUntilAvailable { return _licensor }
                return nil
            }
        }

        var reads: Int { lock.withLock { licensorReadCount } }
        func setUserID(_ id: String) { lock.withLock { _userID = id } }
        func setDeviceID(_ id: String) { lock.withLock { _deviceID = id } }
    }

    private var drm: TPPDRMAuthorizingMock!
    private var service: AdobeDRMService!

    override func setUpWithError() throws {
        try super.setUpWithError()
        drm = TPPDRMAuthorizingMock()
        service = AdobeDRMService(activationCoordinator: AdobeActivationCoordinator())
    }

    override func tearDownWithError() throws {
        drm.reset()
        drm = nil
        service = nil
        try super.tearDownWithError()
    }

    // MARK: - The defect

    /// THE regression test: credentials that arrive after the borrow has begun
    /// must be waited for, not treated as absent.
    func test_ensureDeviceActivated_whenLicensorArrivesLate_waitsAndActivates() async throws {
        let account = LateLicensorAccount(appearsAfterReads: 2)

        try await service.ensureDeviceActivated(
            authorizer: { [drm] in drm },
            userAccount: account,
            isDRMAvailable: true,
            licensorGracePeriod: 2.0
        )

        XCTAssertEqual(drm.authorizeCallCount, 1,
                       "a borrow whose licensor lands moments later must still activate, not fail outright")
        XCTAssertGreaterThan(account.reads, 1,
                             "the licensor must be re-read after the initial miss")
    }

    // MARK: - The guard is delayed, not deleted

    func test_ensureDeviceActivated_whenLicensorNeverArrives_stillFailsWithNoActivation() async {
        let account = LateLicensorAccount(appearsAfterReads: Int.max)

        do {
            try await service.ensureDeviceActivated(
                authorizer: { [drm] in drm },
                userAccount: account,
                isDRMAvailable: true,
                licensorGracePeriod: 0.3
            )
            XCTFail("a genuinely absent licensor must still fail — the grace period defers the guard, it does not remove it")
        } catch {
            guard case .drm(.noActivation)? = error as? PalaceError else {
                return XCTFail("expected PalaceError.drm(.noActivation), got \(error)")
            }
        }
        XCTAssertEqual(drm.authorizeCallCount, 0,
                       "RMSDK must never be entered without licensor credentials")
        XCTAssertGreaterThan(account.reads, 1,
                             "with a non-zero budget the licensor must be re-read before failing — otherwise this test cannot tell 'waited then failed' from 'failed on the first read'")
    }

    /// A library with no Adobe DRM at all must not pay the grace period on a
    /// path that cannot succeed, so a zero budget short-circuits immediately.
    func test_ensureDeviceActivated_withZeroGracePeriod_failsWithoutWaiting() async {
        let account = LateLicensorAccount(appearsAfterReads: Int.max)

        do {
            try await service.ensureDeviceActivated(
                authorizer: { [drm] in drm },
                userAccount: account,
                isDRMAvailable: true,
                licensorGracePeriod: 0
            )
            XCTFail("expected .noActivation")
        } catch {
            guard case .drm(.noActivation)? = error as? PalaceError else {
                return XCTFail("expected PalaceError.drm(.noActivation), got \(error)")
            }
        }
        XCTAssertEqual(account.reads, 1,
                       "a zero grace period must read the licensor once and fail — no polling")
    }

    // MARK: - The default is fail-safe

    /// The grace period is opt-in: `ensureDeviceActivated` defaults to no wait,
    /// so a new caller cannot silently acquire a 15-second stall. Only the
    /// borrow path passes a budget. Without this, changing the default in the
    /// signature would revert PP-5025 (or re-introduce the read-path stall)
    /// with the whole suite still green.
    func test_ensureDeviceActivated_byDefault_doesNotWaitForALateLicensor() async {
        let account = LateLicensorAccount(appearsAfterReads: 2)

        do {
            try await service.ensureDeviceActivated(
                authorizer: { [drm] in drm },
                userAccount: account,
                isDRMAvailable: true
            )
            XCTFail("the default must not wait — the borrow path opts in explicitly")
        } catch {
            guard case .drm(.noActivation)? = error as? PalaceError else {
                return XCTFail("expected PalaceError.drm(.noActivation), got \(error)")
            }
        }
        XCTAssertEqual(account.reads, 1,
                       "the default budget must read the licensor once and fail — no polling on paths that hold a spinner")
    }

    /// The value the borrow path opts into must actually be a wait.
    func test_defaultLicensorGracePeriod_isANonZeroBudget() {
        XCTAssertGreaterThan(AdobeDRMService.defaultLicensorGracePeriod, 0,
                             "the borrow path opts into this constant; at zero the PP-5025 fix is inert")
    }

    // MARK: - Existing behaviour preserved

    func test_ensureDeviceActivated_whenLicensorPresentImmediately_doesNotPoll() async throws {
        let account = LateLicensorAccount(appearsAfterReads: 0)

        // `licensorGracePeriod: 0` is load-bearing: it proves the value came
        // from the pre-loop fast path. Deleting that fast path would still
        // yield reads == 1 under a non-zero budget (the single read just moves
        // inside the loop), so a generous budget cannot pin this.
        try await service.ensureDeviceActivated(
            authorizer: { [drm] in drm },
            userAccount: account,
            isDRMAvailable: true,
            licensorGracePeriod: 0
        )

        XCTAssertEqual(drm.authorizeCallCount, 1)
        XCTAssertEqual(account.reads, 1,
                       "credentials already present must be used on the first read, with no waiting")
    }

    /// The already-activated fast path precedes the licensor guard, so it must
    /// not consult the licensor at all.
    func test_ensureDeviceActivated_whenAlreadyAuthorized_neverReadsLicensor() async throws {
        let account = LateLicensorAccount(appearsAfterReads: Int.max,
                                          userID: "user-1",
                                          deviceID: "device-1")

        try await service.ensureDeviceActivated(
            authorizer: { [drm] in drm },
            userAccount: account,
            isDRMAvailable: true,
            licensorGracePeriod: 5.0
        )

        XCTAssertEqual(drm.authorizeCallCount, 0)
        XCTAssertEqual(account.reads, 0,
                       "an already-activated device must short-circuit before the licensor is consulted")
    }
}
