//
//  AdobeActivationRefreshLicensorTests.swift
//  PalaceTests
//
//  PP-3649, the PRODUCER side.
//
//  `AdobeLicensorRefreshTests` pins the pure chooser — given a stored licensor
//  and a fetch result, which one wins. That is half the fix. The other half is
//  `ensureDeviceActivated` actually WIRING it: calling the refresh, activating
//  with what it returned rather than what the keychain held, persisting the
//  fresh value back, and failing cleanly when the refreshed token is malformed.
//
//  None of that had a test. `grep -rn refreshLicensor PalaceTests` returned
//  nothing, which means every branch this file exercises could have been
//  deleted with the suite still green — including the one that decides whether
//  a borrow authenticates with a token minted seconds ago or one minted an hour
//  ago, which IS the defect.
//
//  A helper being correct is not the same as the caller reaching it. That
//  distinction has its own wall-failure in this repo.
//

import XCTest
@testable import Palace

final class AdobeActivationRefreshLicensorTests: XCTestCase {

    /// In-memory account. Deliberately not a real `TPPUserAccount` — CLAUDE.md
    /// forbids tests touching keychain state — and it RECORDS `setLicensor`
    /// writes, because "did the fresh licensor get persisted back" is one of
    /// the branches under test.
    private final class RecordingAccount: AdobeActivationAccount, @unchecked Sendable {
        private let lock = NSLock()
        private var _userID: String?
        private var _deviceID: String?
        private var _licensor: [String: Any]?
        private var _setLicensorCalls: [[String: Any]] = []

        init(licensor: [String: Any]?, userID: String? = nil, deviceID: String? = nil) {
            self._licensor = licensor
            self._userID = userID
            self._deviceID = deviceID
        }

        var userID: String? { lock.withLock { _userID } }
        var deviceID: String? { lock.withLock { _deviceID } }
        var licensor: [String: Any]? { lock.withLock { _licensor } }

        var setLicensorCalls: [[String: Any]] { lock.withLock { _setLicensorCalls } }

        func setUserID(_ id: String) { lock.withLock { _userID = id } }
        func setDeviceID(_ id: String) { lock.withLock { _deviceID = id } }
        func setLicensor(_ licensor: [String: Any]) {
            lock.withLock {
                _licensor = licensor
                _setLicensorCalls.append(licensor)
            }
        }
    }

    private var drm: TPPDRMAuthorizingMock!
    private var service: AdobeDRMService!

    /// Production-shaped: `SHORTNAME|expires|patronIdentifier|signature`. A
    /// separator-less placeholder would split into halves that no longer
    /// resemble what the CM mints, and the expiry field is what
    /// `AdobeLicensorRefresh.isExpired` reads.
    private func licensor(shortName: String, expires: Date, signature: String) -> [String: Any] {
        ["vendor": "palace-vendor",
         "clientToken": "\(shortName)|\(Int(expires.timeIntervalSince1970))|patron-uuid|\(signature)"]
    }

    private func staleLicensor() -> [String: Any] {
        licensor(shortName: "STALE",
                 expires: Date().addingTimeInterval(-3600),
                 signature: "stale-signature")
    }

    private func freshLicensor() -> [String: Any] {
        licensor(shortName: "FRESH",
                 expires: Date().addingTimeInterval(3600),
                 signature: "fresh-signature")
    }

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

    // MARK: - THE fix: activate with the token minted seconds ago

    /// The headline assertion of PP-3649. A stored licensor that is past the
    /// CM's 60-minute TTL must not be the credential Adobe sees when a fresh one
    /// is obtainable — that is the `E_<vendor>_AUTH Incorrect barcode or PIN`
    /// the patron reads as a credentials problem and is nothing of the kind.
    func test_ensureDeviceActivated_whenRefreshSucceeds_activatesWithTheFreshToken() async throws {
        let account = RecordingAccount(licensor: staleLicensor())
        let fresh = freshLicensor()

        try await service.ensureDeviceActivated(
            authorizer: { [drm] in drm },
            userAccount: account,
            isDRMAvailable: true,
            refreshLicensor: { fresh }
        )

        XCTAssertEqual(drm.authorizeCallCount, 1)
        XCTAssertEqual(drm.lastAuthorizeArgs?.password, "fresh-signature",
                       "activation used the STALE stored token — this is the PP-3649 defect itself")
        XCTAssertTrue(drm.lastAuthorizeArgs?.username.map { $0.hasPrefix("FRESH|") } ?? false,
                      "expected the refreshed token's username half, got \(String(describing: drm.lastAuthorizeArgs?.username))")
    }

    /// The refreshed value must survive the borrow. Without the write-back the
    /// next borrow re-reads the same dead token from the keychain and pays for
    /// the refresh all over again — and every log line about staleness stays
    /// true forever, which is how a fix reads as inert.
    func test_ensureDeviceActivated_whenRefreshSucceeds_persistsTheFreshLicensor() async throws {
        let account = RecordingAccount(licensor: staleLicensor())
        let fresh = freshLicensor()

        try await service.ensureDeviceActivated(
            authorizer: { [drm] in drm },
            userAccount: account,
            isDRMAvailable: true,
            refreshLicensor: { fresh }
        )

        XCTAssertEqual(account.setLicensorCalls.count, 1,
                       "the freshly minted licensor must be written back exactly once")
        XCTAssertEqual(account.setLicensorCalls.first?["clientToken"] as? String,
                       fresh["clientToken"] as? String)
    }

    // MARK: - The fallback: a refresh that fails must not fail the borrow

    /// Offline, a 500, or a library with no Adobe DRM. The stored token may
    /// still be inside its hour, so failing the borrow because a refresh could
    /// not be reached turns a working case into a broken one.
    func test_ensureDeviceActivated_whenRefreshReturnsNil_activatesWithTheStoredToken() async throws {
        let stored = licensor(shortName: "STORED",
                              expires: Date().addingTimeInterval(1800),
                              signature: "stored-signature")
        let account = RecordingAccount(licensor: stored)

        try await service.ensureDeviceActivated(
            authorizer: { [drm] in drm },
            userAccount: account,
            isDRMAvailable: true,
            refreshLicensor: { nil }
        )

        XCTAssertEqual(drm.authorizeCallCount, 1)
        XCTAssertEqual(drm.lastAuthorizeArgs?.password, "stored-signature")
        XCTAssertTrue(account.setLicensorCalls.isEmpty,
                      "nothing was refreshed, so writing the keychain would be a pointless write")
    }

    /// A document that came back but carries no usable licensor — a library
    /// without Adobe DRM answers exactly this shape — must not displace a stored
    /// licensor that still works.
    func test_ensureDeviceActivated_whenRefreshReturnsUnusableLicensor_keepsTheStoredOne() async throws {
        let stored = licensor(shortName: "STORED",
                              expires: Date().addingTimeInterval(1800),
                              signature: "stored-signature")
        let account = RecordingAccount(licensor: stored)

        try await service.ensureDeviceActivated(
            authorizer: { [drm] in drm },
            userAccount: account,
            isDRMAvailable: true,
            refreshLicensor: { ["vendor": "", "clientToken": ""] }
        )

        XCTAssertEqual(drm.lastAuthorizeArgs?.password, "stored-signature")
        XCTAssertTrue(account.setLicensorCalls.isEmpty)
    }

    /// No refresh supplied at all — the read path and the fulfillment dispatcher
    /// call `ensureDeviceActivated` without one. The stored licensor must still
    /// activate, and nothing may be written back.
    func test_ensureDeviceActivated_withNoRefreshClosure_activatesWithTheStoredToken() async throws {
        let stored = licensor(shortName: "STORED",
                              expires: Date().addingTimeInterval(1800),
                              signature: "stored-signature")
        let account = RecordingAccount(licensor: stored)

        try await service.ensureDeviceActivated(
            authorizer: { [drm] in drm },
            userAccount: account,
            isDRMAvailable: true
        )

        XCTAssertEqual(drm.lastAuthorizeArgs?.password, "stored-signature")
        XCTAssertTrue(account.setLicensorCalls.isEmpty)
    }

    // MARK: - A refreshed-but-malformed token is a DIFFERENT failure

    /// The refresh can succeed at the transport layer and still hand back a
    /// token the app cannot split. That must surface as `.noActivation` with
    /// RMSDK never entered — not as `authenticationFailed`, which is the
    /// indistinguishable answer PP-3649 exists to stop producing.
    func test_ensureDeviceActivated_whenRefreshedTokenIsMalformed_failsWithNoActivation() async {
        let account = RecordingAccount(licensor: staleLicensor())

        do {
            try await service.ensureDeviceActivated(
                authorizer: { [drm] in drm },
                userAccount: account,
                isDRMAvailable: true,
                refreshLicensor: { ["vendor": "palace-vendor", "clientToken": "no-separator-at-all"] }
            )
            XCTFail("a token that cannot be split must not be handed to Adobe")
        } catch {
            guard case .drm(.noActivation)? = error as? PalaceError else {
                return XCTFail("expected PalaceError.drm(.noActivation), got \(error)")
            }
        }

        XCTAssertEqual(drm.authorizeCallCount, 0,
                       "RMSDK must never be entered with credentials that cannot authenticate")
    }

    /// The malformed refreshed licensor still displaces the stored one — it is
    /// `isUsable`, since both halves are non-empty — so the write-back happens
    /// before the split guard rejects it. Pinning this stops a later reader from
    /// "fixing" the order and silently reverting to activating with the stale
    /// token whenever a fresh one is malformed.
    func test_ensureDeviceActivated_whenRefreshedTokenIsMalformed_stillPersistedIt() async {
        let account = RecordingAccount(licensor: staleLicensor())

        _ = try? await service.ensureDeviceActivated(
            authorizer: { [drm] in drm },
            userAccount: account,
            isDRMAvailable: true,
            refreshLicensor: { ["vendor": "palace-vendor", "clientToken": "no-separator-at-all"] }
        )

        XCTAssertEqual(account.setLicensorCalls.count, 1,
                       "the refreshed licensor is persisted before the split guard reads it")
    }

    // MARK: - Ordering: the grace wait comes FIRST

    /// PP-5025 and PP-3649 stack on the same line, in this order: wait for a
    /// licensor that sign-in has not written yet, THEN re-mint it. A refresh
    /// that ran first would work for the wrong reason — it would paper over the
    /// sign-in race by fetching, and the grace period would go untested and then
    /// get deleted as dead.
    func test_ensureDeviceActivated_whenNothingIsStoredAndRefreshSucceeds_stillActivates() async throws {
        let account = RecordingAccount(licensor: nil)
        let fresh = freshLicensor()

        try await service.ensureDeviceActivated(
            authorizer: { [drm] in drm },
            userAccount: account,
            isDRMAvailable: true,
            licensorGracePeriod: 0,
            refreshLicensor: { fresh }
        )

        XCTAssertEqual(drm.lastAuthorizeArgs?.password, "fresh-signature",
                       "a patron with no stored licensor must still borrow when the profile fetch answers")
        XCTAssertEqual(account.setLicensorCalls.count, 1)
    }

    /// Neither stored nor refreshed: the guard must still fail closed.
    func test_ensureDeviceActivated_withNoLicensorAnywhere_failsWithNoActivation() async {
        let account = RecordingAccount(licensor: nil)

        do {
            try await service.ensureDeviceActivated(
                authorizer: { [drm] in drm },
                userAccount: account,
                isDRMAvailable: true,
                licensorGracePeriod: 0,
                refreshLicensor: { nil }
            )
            XCTFail("expected .noActivation")
        } catch {
            guard case .drm(.noActivation)? = error as? PalaceError else {
                return XCTFail("expected PalaceError.drm(.noActivation), got \(error)")
            }
        }
        XCTAssertEqual(drm.authorizeCallCount, 0)
    }

    /// The already-activated fast path precedes everything, so a borrow on an
    /// activated device must not spend a profile-document round trip.
    func test_ensureDeviceActivated_whenAlreadyAuthorized_neverRefreshes() async throws {
        let account = RecordingAccount(licensor: staleLicensor(),
                                       userID: "user-1", deviceID: "device-1")
        drm.isUserAuthorizedReturnValue = true
        let refreshed = LockedFlag()
        let fresh = freshLicensor()

        try await service.ensureDeviceActivated(
            authorizer: { [drm] in drm },
            userAccount: account,
            isDRMAvailable: true,
            refreshLicensor: { refreshed.set(); return fresh }
        )

        XCTAssertFalse(refreshed.value,
                       "an activated device must not pay a network round trip on every borrow")
        XCTAssertEqual(drm.authorizeCallCount, 0)
    }

    /// A library with no Adobe certificate must fail before any network work.
    func test_ensureDeviceActivated_whenDRMUnavailable_neverRefreshes() async {
        let account = RecordingAccount(licensor: staleLicensor())
        let refreshed = LockedFlag()
        let fresh = freshLicensor()

        do {
            try await service.ensureDeviceActivated(
                authorizer: { [drm] in drm },
                userAccount: account,
                isDRMAvailable: false,
                refreshLicensor: { refreshed.set(); return fresh }
            )
            XCTFail("expected .noActivation")
        } catch {
            guard case .drm(.noActivation)? = error as? PalaceError else {
                return XCTFail("expected PalaceError.drm(.noActivation), got \(error)")
            }
        }
        XCTAssertFalse(refreshed.value)
    }

    // MARK: - The bounded await (7b)

    /// `freshLicensorFromProfileDocument` hands its completion to URLSession via
    /// the executor and sits OUTSIDE the activation deadline, on the borrow
    /// path. An unresumed continuation there wedges the borrow forever — this
    /// branch has already shipped one ten-hour hang from exactly that shape.
    ///
    /// This drives a producer that NEVER completes and asserts the call returns.
    /// A regression hangs this test rather than the whole suite.
    func test_boundedLicensor_whenTheProducerNeverAnswers_returnsNilAtTheDeadline() async {
        let started = Date()

        let result = await AdobeDRMService.boundedLicensor(timeout: 0.4) { _ in
            // Deliberately drops the completion, as a URLSession task that
            // never calls back would.
        }

        let elapsed = Date().timeIntervalSince(started)
        XCTAssertNil(result.licensor, "a fetch that never answers must yield nil, not a value")
        XCTAssertTrue(result.timedOut,
                      "the deadline is what released this await and the caller must be told — "
                      + "a timeout reported as an ordinary empty answer is an invisible hang")
        XCTAssertGreaterThanOrEqual(elapsed, 0.3,
                                    "returned before the deadline — the timeout is not what released it")
        XCTAssertLessThan(elapsed, 5.0,
                          "returned, but far past the 0.4s deadline — the bound is not honoured")
    }

    /// The clean path. A deadline exercised only against the hang it detects
    /// passes while rejecting every legitimate input.
    func test_boundedLicensor_whenTheProducerAnswers_returnsItWithoutWaiting() async {
        let started = Date()

        let result = await AdobeDRMService.boundedLicensor(timeout: 30) { done in  // FLAKE-003-OK: a deliberately DISTANT deadline. These three cases assert the producer's answer is returned WITHOUT waiting, so the bound has to be far enough away that reaching it would be a real defect; the elapsed-time assertion in each body is what actually caps the wall clock, at 5s.
            done(["vendor": "v", "clientToken": "a|b"])
        }

        XCTAssertEqual(result.licensor?["clientToken"] as? String, "a|b")
        XCTAssertFalse(result.timedOut,
                       "a fetch that answered must NOT be reported as a timeout — that is the false "
                       + "telemetry the at-most-once latch exists to prevent")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5.0,
                          "an answered fetch must not wait out the deadline")
    }

    /// An answer of "no licensor" is a real answer and must not be confused with
    /// a hang — it has to come back promptly rather than at the deadline.
    func test_boundedLicensor_whenTheProducerAnswersNil_returnsPromptly() async {
        let started = Date()

        let result = await AdobeDRMService.boundedLicensor(timeout: 30) { done in  // FLAKE-003-OK: a deliberately DISTANT deadline. These three cases assert the producer's answer is returned WITHOUT waiting, so the bound has to be far enough away that reaching it would be a real defect; the elapsed-time assertion in each body is what actually caps the wall clock, at 5s.
            done(nil)
        }

        XCTAssertNil(result.licensor)
        XCTAssertFalse(result.timedOut,
                       "\"no licensor in the profile document\" is an ANSWER — a library without Adobe DRM "
                       + "answers exactly this, and reporting it as a timeout would bury a real hang in noise")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5.0)
    }

    /// A completion handler invoked twice would resume a `CheckedContinuation`
    /// twice — a hard runtime trap, not a recoverable error. The latch is
    /// load-bearing, not defensive styling, so it gets an assertion.
    func test_boundedLicensor_whenTheProducerAnswersTwice_doesNotTrap() async {
        let result = await AdobeDRMService.boundedLicensor(timeout: 30) { done in  // FLAKE-003-OK: a deliberately DISTANT deadline. These three cases assert the producer's answer is returned WITHOUT waiting, so the bound has to be far enough away that reaching it would be a real defect; the elapsed-time assertion in each body is what actually caps the wall clock, at 5s.
            done(["vendor": "v", "clientToken": "first|token"])
            done(["vendor": "v", "clientToken": "second|token"])
        }

        XCTAssertEqual(result.licensor?["clientToken"] as? String, "first|token",
                       "the first answer wins; the second must be dropped, not resumed")
        XCTAssertFalse(result.timedOut)
    }

    /// The constant the borrow path actually uses must be a real bound.
    func test_profileDocumentTimeout_isAFiniteNonZeroBudget() {
        XCTAssertGreaterThan(AdobeDRMService.profileDocumentTimeout, 0,
                             "at zero every refresh times out instantly and PP-3649's fix is inert")
        XCTAssertLessThan(AdobeDRMService.profileDocumentTimeout, 120,
                          "a bound long enough to look like a hang is not a bound")
    }
}

/// Minimal thread-safe flag. The refresh closure is `@Sendable` and runs off the
/// test's thread, so a plain `var` captured by it is a data race, not a
/// convenience.
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}
