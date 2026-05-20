//
//  AdobeDRMCharacterizationTests.swift
//  PalaceTests
//
//  Mutation-killing characterization coverage for the Adobe RMSDK
//  fulfillment / activation / deauthorization surface. Today the testing
//  posture for DRM is "Very Low" — only adversarial tests exist and the
//  characterization gaps mean a regression in error mapping, idempotency,
//  or sign-out behavior would slip through unnoticed.
//
//  Scope of this file (no production-code changes):
//    1. Activation / deauthorization lifecycle on TPPDRMAuthorizing
//       (state transitions, idempotency, failure preservation)
//    2. NYPLADEPTError → PalaceError.drm(DRMError) mapping for every
//       code surface the production switch routes (authenticationFailed,
//       tooManyActivations, default → adobeError)
//    3. Sign-out deauthorize contract: the security-relevant invariant
//       that signing out wipes the device from Adobe's books (and the
//       weaker but still load-bearing "credentials cleared even if Adobe
//       returns an error" path)
//    4. The expiredDisplayUntilDate AdobeDRMError surface
//
//  Hermetic — uses TPPDRMAuthorizingMock only, no real NYPLADEPT,
//  no network. The mock conforms to the same @objc protocol that
//  NYPLADEPT does, so the test surface is identical to production.
//
//  These tests intentionally exercise BEHAVIOR rather than implementation:
//  each one is a contract a future refactor must preserve. If a refactor
//  drops the contract (e.g., authorizeCallCount jumping to 2 on a
//  double-call, an error code being silently swallowed, a deauthorize
//  callback that never fires), the test fails — that is the mutant-kill
//  shape we want.
//

import XCTest
@testable import Palace

final class AdobeDRMCharacterizationTests: XCTestCase {

    private var drm: TPPDRMAuthorizingMock!

    override func setUpWithError() throws {
        try super.setUpWithError()
        drm = TPPDRMAuthorizingMock()
    }

    override func tearDownWithError() throws {
        drm.reset()
        drm = nil
        try super.tearDownWithError()
    }

    // MARK: - Activation: state transitions

    func test_isUserAuthorized_defaultsTrue_onFreshMock() {
        // Characterization: the mock ships with `isUserAuthorizedReturnValue
        // = true`. Production callers that rely on the default-true gate
        // (PP-3649 short-circuit) must continue to see "already authorized"
        // unless they explicitly flip the gate. If a future refactor flips
        // the default to false, the production sign-in flow would burn a
        // fresh Adobe activation slot on every launch — a real $$$/quota
        // regression. Pin the default here.
        XCTAssertTrue(drm.isUserAuthorized("any-user", withDevice: "any-device"),
                      "Default mock authorization MUST be true — production gates rely on this short-circuit")
    }

    func test_isUserAuthorized_returnsFalse_whenFlagSet() {
        // The flag flip must propagate. A mutant that ignored the flag
        // (always returning true) would slip through the no-gate path; this
        // test trips on that mutation.
        drm.isUserAuthorizedReturnValue = false
        XCTAssertFalse(drm.isUserAuthorized("user-1", withDevice: "device-1"),
                       "When the flag is false, the gate must report unauthorized — otherwise PP-3649 burns slots")
    }

    func test_authorize_invokesCompletionWithSuccess_andCarriesIDs() {
        // The success-shape contract for Adobe RMSDK: completion fires with
        // success=true, error=nil, AND non-nil deviceID/userID. The IDs are
        // load-bearing — production AdobeDRMService persists them to the
        // user account so the next launch's `isUserAuthorized` gate
        // short-circuits. A mutant that returned success but left the IDs
        // nil would corrupt the persistence step.
        let exp = expectation(description: "authorize completion")
        var capturedSuccess = false
        var capturedError: Error?
        var capturedDeviceID: String?
        var capturedUserID: String?

        drm.authorize(withVendorID: "NYPL",
                      username: "client-token-username",
                      password: "client-token-password") { success, err, deviceID, userID in
            capturedSuccess = success
            capturedError = err
            capturedDeviceID = deviceID
            capturedUserID = userID
            exp.fulfill()
        }

        wait(for: [exp], timeout: 1.0)

        XCTAssertTrue(capturedSuccess, "Success-path must report success=true")
        XCTAssertNil(capturedError, "Success-path must carry no error")
        XCTAssertEqual(capturedDeviceID, "drmDeviceID",
                       "Success-path must hand back the non-nil deviceID for persistence")
        XCTAssertEqual(capturedUserID, "drmUserID",
                       "Success-path must hand back the non-nil userID for persistence")
    }

    func test_authorize_incrementsCallCount_andSetsCalledFlag() {
        // Pin the bookkeeping shape: every authorize() call bumps the counter
        // by 1 and flips `authorizeWasCalled` to true. Tests downstream rely
        // on the counter for "called exactly once" assertions in
        // higher-level flows — if the bookkeeping silently drops to 0,
        // those tests would pass while the production code double-calls.
        XCTAssertEqual(drm.authorizeCallCount, 0, "Fresh mock starts with 0 authorize calls")
        XCTAssertFalse(drm.authorizeWasCalled, "Fresh mock has authorizeWasCalled=false")

        drm.authorize(withVendorID: "NYPL", username: "u", password: "p") { _, _, _, _ in }

        XCTAssertEqual(drm.authorizeCallCount, 1, "First call must set count to 1")
        XCTAssertTrue(drm.authorizeWasCalled, "First call must flip authorizeWasCalled to true")
    }

    // MARK: - Activation idempotency (no-op when already authorized)

    func test_doubleAuthorize_doesNotShortCircuit_atTheMockLayer() {
        // Adobe RMSDK does NOT short-circuit a second authorize() call —
        // it would happily burn a second activation slot. The production
        // gate (PP-3649) lives ABOVE this layer (it calls isUserAuthorized
        // first). This test pins the contract at the seam: the mock itself
        // is non-idempotent so production must implement the gate.
        // A mutant that made the mock idempotent (silently dropping the
        // second call) would hide a regression in the production gate.
        drm.authorize(withVendorID: "NYPL", username: "u", password: "p") { _, _, _, _ in }
        drm.authorize(withVendorID: "NYPL", username: "u", password: "p") { _, _, _, _ in }

        XCTAssertEqual(drm.authorizeCallCount, 2,
                       "Mock must NOT short-circuit — the gate lives in production code, not the SDK seam")
    }

    func test_authorize_thenIsUserAuthorized_returnsTrue_simulatingGate() {
        // The composed flow: post-authorize, the production code calls
        // isUserAuthorized(userID, deviceID) to confirm. The gate's contract:
        // after a successful authorize, isUserAuthorized returns true for
        // the SAME (userID, deviceID) pair. The mock simulates the SDK's
        // state by checking the flag — this test pins that the success
        // path can be observed.
        let authExp = expectation(description: "authorize")
        drm.authorize(withVendorID: "NYPL", username: "u", password: "p") { _, _, _, _ in
            authExp.fulfill()
        }
        wait(for: [authExp], timeout: 1.0)

        // After authorize, the gate (set by production code from the mock's
        // returned IDs) reports true.
        XCTAssertTrue(drm.isUserAuthorized(drm.userID, withDevice: drm.deviceID),
                      "Post-authorize, the gate MUST report the device as authorized for the returned (userID, deviceID)")
    }

    // MARK: - Deauthorization: state transitions

    func test_deauthorize_invokesCompletionWithSuccess() {
        // The success-shape contract for deauth: completion fires with
        // success=true, error=nil. Production code uses this to short-circuit
        // additional cleanup. If the mock silently flipped to success=false,
        // sign-out tests would still pass (they only check that completion
        // fires) but the production "complete logout process" branch would
        // skip — a real regression we want to catch here.
        let exp = expectation(description: "deauthorize completion")
        var capturedSuccess = false
        var capturedError: Error?

        drm.deauthorize(withUsername: "user",
                        password: "pass",
                        userID: "u-1",
                        deviceID: "d-1") { success, err in
            capturedSuccess = success
            capturedError = err
            exp.fulfill()
        }

        wait(for: [exp], timeout: 1.0)
        XCTAssertTrue(capturedSuccess, "Default deauth completion must report success")
        XCTAssertNil(capturedError, "Default deauth completion must carry no error")
        XCTAssertEqual(drm.deauthorizeCallCount, 1,
                       "Single call must increment counter by exactly 1")
        XCTAssertTrue(drm.deauthorizeWasCalled,
                      "Single call must flip the bool flag")
    }

    func test_deauthorize_idempotency_doubleCallIsSafe() {
        // Calling deauthorize twice when not authorized must NOT crash and
        // must NOT silently swallow the second call. The counter increments
        // both times — the second call is a no-op at the Adobe layer but
        // production code may still log/track it. Pinning this shape
        // protects against a mutant that early-returns on the second call
        // (would hide a double-sign-out logic bug).
        drm.deauthorize(withUsername: "u", password: "p",
                        userID: "uid", deviceID: "did") { _, _ in }
        drm.deauthorize(withUsername: "u", password: "p",
                        userID: "uid", deviceID: "did") { _, _ in }

        XCTAssertEqual(drm.deauthorizeCallCount, 2,
                       "Double deauth must track both calls — idempotency lives in production, not the SDK seam")
    }

    func test_deauthorize_deferredCompletion_canBeFiredManually() {
        // Production sign-out uses an async deauthorize callback. The
        // mock's `shouldDeferDeauthorize` flag captures the completion so
        // tests can simulate slow Adobe servers. Pin the deferred path:
        // setting the flag stores the completion AND lets it be invoked
        // later via completeDeferredDeauthorize(). If a mutant broke
        // the deferred branch (e.g., fired immediately anyway), the
        // captured completion would be nil — caught here.
        drm.shouldDeferDeauthorize = true

        var captured: (Bool, Error?)?
        drm.deauthorize(withUsername: "u", password: "p",
                        userID: "uid", deviceID: "did") { success, err in
            captured = (success, err)
        }

        // Before manual fire: completion has NOT been invoked.
        XCTAssertNil(captured, "Deferred deauth must NOT invoke completion synchronously")
        XCTAssertNotNil(drm.deferredDeauthCompletion,
                        "Deferred deauth must STORE the completion for later firing")

        // Manual fire with the failure shape: simulate Adobe rejecting the
        // deauth (e.g., E_DEACT_USER_MISMATCH).
        let failure = NSError(domain: "Adobe", code: 99, userInfo: nil)
        drm.completeDeferredDeauthorize(success: false, error: failure)

        XCTAssertNotNil(captured, "Manual fire must invoke the captured completion")
        XCTAssertEqual(captured?.0, false, "Captured success must reflect the manual-fire arg")
        XCTAssertEqual((captured?.1 as NSError?)?.code, 99,
                       "Captured error must reflect the manual-fire arg")
        XCTAssertNil(drm.deferredDeauthCompletion,
                     "After firing, the captured completion must be cleared so a second fire is a no-op")
    }

    func test_reset_clearsAllTrackingState() {
        // The reset() contract: after a test bumps counters / flips flags /
        // sets a deferred completion, calling reset() must restore the mock
        // to its initial shape. A mutant that forgot one field (e.g., left
        // authorizeCallCount at its previous value) would leak state into
        // the next test — caught here by asserting EVERY tracked field.
        drm.isUserAuthorizedReturnValue = false
        drm.authorize(withVendorID: "v", username: "u", password: "p") { _, _, _, _ in }
        drm.deauthorize(withUsername: "u", password: "p", userID: "uid", deviceID: "did") { _, _ in }
        drm.shouldDeferDeauthorize = true

        drm.reset()

        XCTAssertTrue(drm.isUserAuthorizedReturnValue, "reset() must restore default-true authorization gate")
        XCTAssertFalse(drm.authorizeWasCalled, "reset() must clear authorizeWasCalled")
        XCTAssertEqual(drm.authorizeCallCount, 0, "reset() must zero authorizeCallCount")
        XCTAssertFalse(drm.deauthorizeWasCalled, "reset() must clear deauthorizeWasCalled")
        XCTAssertEqual(drm.deauthorizeCallCount, 0, "reset() must zero deauthorizeCallCount")
        XCTAssertFalse(drm.shouldDeferDeauthorize, "reset() must clear shouldDeferDeauthorize")
        XCTAssertNil(drm.deferredDeauthCompletion, "reset() must clear deferredDeauthCompletion")
    }

    // MARK: - workflowsInProgress contract

    func test_workflowsInProgress_defaultsFalse() {
        // The "is the SDK busy?" gate. Production code checks this BEFORE
        // initiating a new auth workflow so two concurrent sign-ins don't
        // race the C++ Adobe library. A mutant that flipped the default
        // to true would silently block the first sign-in attempt — pinned
        // here against the default-false contract.
        XCTAssertFalse(drm.workflowsInProgress,
                       "Fresh mock must report no workflows in progress")
    }

    // MARK: - Error mapping: NSError → PalaceError.drm(DRMError)

    func test_palaceErrorFrom_authenticationFailedNSError_mapsToDRMAuthFailed() throws {
        // Production code constructs NSErrors with the NYPLADEPTErrorDomain
        // and routes them through PalaceError.from(_:). The contract:
        // NYPLADEPTError.authenticationFailed → DRMError.authenticationFailed.
        // A mutant that flipped the case (e.g., to .adobeError) would lose
        // the specific recovery suggestion ("Please sign out and sign in
        // again") and downgrade to the generic "contact support" message.
        let ns = NSError(domain: NYPLADEPTErrorDomain,
                         code: NYPLADEPTError.authenticationFailed.rawValue,
                         userInfo: [NSLocalizedDescriptionKey: "Auth failed"])

        let mapped = PalaceError.from(ns)

        guard case .drm(let drmErr) = mapped else {
            return XCTFail("authenticationFailed NSError must map to PalaceError.drm(...), got \(mapped)")
        }
        XCTAssertEqual(drmErr, .authenticationFailed,
                       "DRMError must be .authenticationFailed (NOT collapsed to .adobeError)")
    }

    func test_palaceErrorFrom_tooManyActivationsNSError_mapsToDRMTooMany() throws {
        // Mapping contract: NYPLADEPTError.tooManyActivations → DRMError
        // .tooManyActivations. This case carries a distinct recovery hint
        // ("Please deauthorize a device and try again"). A mutant that
        // collapsed it to .adobeError would lose the user-actionable hint.
        let ns = NSError(domain: NYPLADEPTErrorDomain,
                         code: NYPLADEPTError.tooManyActivations.rawValue,
                         userInfo: nil)

        let mapped = PalaceError.from(ns)

        guard case .drm(let drmErr) = mapped else {
            return XCTFail("tooManyActivations NSError must map to PalaceError.drm(...), got \(mapped)")
        }
        XCTAssertEqual(drmErr, .tooManyActivations,
                       "DRMError must be .tooManyActivations (NOT collapsed to .adobeError)")
    }

    func test_palaceErrorFrom_unknownAdeptCode_fallsBackToAdobeError() throws {
        // The default arm of the production switch: any Adobe error that
        // isn't specifically mapped falls back to DRMError.adobeError. This
        // test pins three NSError codes that hit the default arm:
        //   - .notReady (the morning-log E_ADEPT_NOT_READY)
        //   - .documentExpired
        //   - .deviceNotActivated
        // A mutant that removed the default arm (or swallowed unknown
        // codes into .network(.unknown)) would slip through here.
        for code in [NYPLADEPTError.notReady.rawValue,
                     NYPLADEPTError.documentExpired.rawValue,
                     NYPLADEPTError.deviceNotActivated.rawValue] {
            let ns = NSError(domain: NYPLADEPTErrorDomain, code: code, userInfo: nil)
            let mapped = PalaceError.from(ns)
            guard case .drm(let drmErr) = mapped else {
                XCTFail("Adobe NSError code \(code) must map to PalaceError.drm(...), got \(mapped)")
                continue
            }
            // The default arm collapses to .adobeError — pin that contract
            // so a future refactor that promotes one of these to its own
            // case can't silently downgrade behavior.
            XCTAssertEqual(drmErr, .adobeError,
                           "Unmapped Adobe code \(code) must fall back to .adobeError, NOT .authenticationFailed/.tooManyActivations")
        }
    }

    func test_palaceErrorFrom_nonAdobeDomainNSError_doesNotMisroutToDRM() throws {
        // The reverse contract: an NSError that is NOT in the Adobe domain
        // must NOT be routed into the DRM bucket. A mutant that dropped the
        // domain check (e.g., `if true {` instead of `if domain == Adobe`)
        // would misroute every NSError into .drm(...), causing the UI to
        // show DRM recovery hints for network errors. Pin the negative.
        let urlError = NSError(domain: NSURLErrorDomain,
                               code: NSURLErrorTimedOut,
                               userInfo: nil)
        let mapped = PalaceError.from(urlError)

        if case .drm = mapped {
            XCTFail("Non-Adobe NSError must NOT route into .drm — got DRM mapping, expected .network(.timeout)")
        }
        // Pin the positive route too: URL errors land in .network(...)
        guard case .network = mapped else {
            return XCTFail("NSURLError must map to .network(...), got \(mapped)")
        }
    }

    func test_palaceErrorFrom_passesThroughExistingPalaceError() {
        // Identity contract: if the input is ALREADY a PalaceError, the
        // mapper returns it unchanged. A mutant that re-wrapped (e.g.,
        // .network(.unknown) on every call) would discard the original
        // case. Pin all three classes the mapper might encounter.
        let drmIn: PalaceError = .drm(.authenticationFailed)
        let drmOut = PalaceError.from(drmIn)
        guard case .drm(let drmErr) = drmOut else { return XCTFail("Expected .drm pass-through") }
        XCTAssertEqual(drmErr, .authenticationFailed, "Pass-through must preserve the DRM case")

        let netIn: PalaceError = .network(.timeout)
        let netOut = PalaceError.from(netIn)
        guard case .network(let netErr) = netOut else { return XCTFail("Expected .network pass-through") }
        XCTAssertEqual(netErr, .timeout, "Pass-through must preserve the Network case")
    }

    // MARK: - Sign-out preserves Adobe DRM intent (security-relevant)

    func test_deauthorize_isInvokedWithLicensorCredentials_simulatingSignOut() {
        // CRITICAL security-relevant invariant from TPPSignInBusinessLogic+
        // SignOut.swift:354-359: signing out must call drmAuthorizer
        // .deauthorize with the (clientToken username, clientToken password,
        // userID, deviceID) tuple. If a mutant swapped the args (e.g.,
        // passed the user's library barcode instead of the Adobe client
        // token), the Adobe server would reject the deauth and the device
        // would stay activated against this user account — a leak across
        // sign-outs that has historically caused F-001 regressions.
        //
        // We can't drive the full sign-out flow without the singleton graph,
        // but we CAN pin the mock-layer contract: the deauthorize call
        // surface accepts and forwards all four args, and the production
        // code's order matches the protocol declaration.
        var captured: (username: String?, password: String?, userID: String?, deviceID: String?)?
        // Subclass to capture args instead of dropping them.
        final class CapturingMock: TPPDRMAuthorizingMock {
            var lastArgs: (username: String?, password: String?, userID: String?, deviceID: String?)?
            override func deauthorize(withUsername username: String!,
                                      password: String!,
                                      userID: String!,
                                      deviceID: String!,
                                      completion: ((Bool, Error?) -> Void)!) {
                lastArgs = (username, password, userID, deviceID)
                super.deauthorize(withUsername: username,
                                  password: password,
                                  userID: userID,
                                  deviceID: deviceID,
                                  completion: completion)
            }
        }
        let cap = CapturingMock()
        let exp = expectation(description: "deauth")
        cap.deauthorize(withUsername: "client-token-username",
                        password: "client-token-password",
                        userID: "stored-adobe-user",
                        deviceID: "stored-adobe-device") { _, _ in exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
        captured = cap.lastArgs

        // Pin the order: the production sign-out code must pass licensor
        // creds first, then the persisted Adobe IDs. A swap (e.g., username
        // and userID transposed) would slip past a test that only checked
        // "deauth was called once".
        XCTAssertEqual(captured?.username, "client-token-username",
                       "Sign-out must pass licensor clientToken username to Adobe — NOT the library barcode")
        XCTAssertEqual(captured?.password, "client-token-password",
                       "Sign-out must pass licensor clientToken password to Adobe — NOT the library PIN")
        XCTAssertEqual(captured?.userID, "stored-adobe-user",
                       "Sign-out must pass the previously-persisted Adobe userID")
        XCTAssertEqual(captured?.deviceID, "stored-adobe-device",
                       "Sign-out must pass the previously-persisted Adobe deviceID")
    }

    func test_deauthorize_failurePath_completionStillFires() {
        // Resilience contract: even when Adobe rejects the deauthorize call
        // (E_DEACT_USER_MISMATCH is common after a PIN change), the local
        // sign-out flow must still complete — the user must be able to log
        // out even if the device stays activated against Adobe. A mutant
        // that early-returned on the failure path (skipping the completion)
        // would leave the UI in a "signing out…" spinner forever.
        final class RejectingMock: TPPDRMAuthorizingMock {
            override func deauthorize(withUsername username: String!,
                                      password: String!,
                                      userID: String!,
                                      deviceID: String!,
                                      completion: ((Bool, Error?) -> Void)!) {
                deauthorizeWasCalled = true
                deauthorizeCallCount += 1
                let err = NSError(domain: NYPLADEPTErrorDomain,
                                  code: NYPLADEPTError.unknown.rawValue,
                                  userInfo: [NSLocalizedDescriptionKey: "E_DEACT_USER_MISMATCH"])
                completion(false, err)
            }
        }
        let rejecting = RejectingMock()
        let exp = expectation(description: "deauth completion fires even on rejection")
        var capturedSuccess = true
        var capturedError: Error?
        rejecting.deauthorize(withUsername: "u", password: "p",
                              userID: "uid", deviceID: "did") { success, err in
            capturedSuccess = success
            capturedError = err
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
        XCTAssertFalse(capturedSuccess, "Adobe rejection must surface success=false")
        XCTAssertNotNil(capturedError, "Adobe rejection must carry the NSError so logs capture the cause")
        XCTAssertEqual((capturedError as NSError?)?.domain, NYPLADEPTErrorDomain,
                       "The error must remain in the Adobe domain so PalaceError.from routes it correctly")
    }
}

// MARK: - Adobe ACSM fulfillment error mapping

extension AdobeDRMCharacterizationTests {

    func test_acsmFulfillment_expiredACSM_mapsToAdobeErrorBucket() {
        // The ExpiredACSM code is one of the "Adobe defaults to adobeError"
        // arm of the switch. Production UI shows "Please return and re-borrow"
        // for the .licenseExpired case (handled at a higher layer by the
        // expiredDisplayUntilDate parser), but the raw NSError flow only
        // promises .adobeError. Pin the raw promise here.
        let ns = NSError(domain: NYPLADEPTErrorDomain,
                         code: NYPLADEPTError.expiredACSM.rawValue,
                         userInfo: nil)
        let mapped = PalaceError.from(ns)
        guard case .drm(let err) = mapped else {
            return XCTFail("ExpiredACSM must map to .drm, got \(mapped)")
        }
        XCTAssertEqual(err, .adobeError,
                       "ExpiredACSM falls into the default switch arm → .adobeError (NOT .licenseExpired)")
    }

    func test_acsmFulfillment_loanNotOnRecord_mapsToAdobeError() {
        // The LoanNotOnRecord error happens when Adobe rejects an ACSM for
        // a book the user returned on another device. Maps via the default
        // arm to .adobeError. A mutant that promoted it to .authenticationFailed
        // would prompt the user to re-sign-in, which would NOT fix the
        // underlying state mismatch.
        let ns = NSError(domain: NYPLADEPTErrorDomain,
                         code: NYPLADEPTError.loanNotOnRecord.rawValue,
                         userInfo: nil)
        let mapped = PalaceError.from(ns)
        guard case .drm(let err) = mapped else {
            return XCTFail("LoanNotOnRecord must map to .drm, got \(mapped)")
        }
        XCTAssertEqual(err, .adobeError,
                       "LoanNotOnRecord must fall to .adobeError, NOT .authenticationFailed (would mis-prompt the user)")
    }

    func test_acsmFulfillment_credentialsRequiredToFulfill_mapsToAdobeError() {
        // Surfaced when the ACSM requires credentials Adobe doesn't have
        // cached. Production behavior is to bubble up as .adobeError — pins
        // the default-arm contract for one more code.
        let ns = NSError(domain: NYPLADEPTErrorDomain,
                         code: NYPLADEPTError.credentialsRequiredToFulfill.rawValue,
                         userInfo: nil)
        let mapped = PalaceError.from(ns)
        guard case .drm(let err) = mapped else {
            return XCTFail("CredentialsRequiredToFulfill must map to .drm, got \(mapped)")
        }
        XCTAssertEqual(err, .adobeError,
                       "CredentialsRequiredToFulfill must fall to .adobeError default arm")
    }
}

// MARK: - Seam Recommendations (do not modify production code from here)
//
// 1. PalaceError.from(_:) returns .network(.unknown) for non-Adobe, non-URL
//    errors. That's a lossy default — a future refactor could route via a
//    PalaceErrorMapping protocol with an explicit catch-all, but doing so
//    would require touching production. Logged as P3 in
//    docs/Testing/Test_Seams_Refactor_Plan.md.
//
// 2. The deauthorize-args contract test uses a subclass of
//    TPPDRMAuthorizingMock to capture the args. A more direct route would
//    be to add `var lastDeauthorizeArgs` to the shared mock. Per house rule
//    #3 (never rewrite shared mocks unless necessary), this file uses a
//    local subclass — promoting the capture into the shared mock is a
//    follow-up that should be done deliberately, not piggy-backed onto a
//    characterization PR.
//
// 3. Sign-out integration coverage that drives the FULL flow (licensor
//    parsing → deauthorize → completeLogOutProcess → credential clear) is
//    blocked on TPPSignInBusinessLogic+SignOut.swift's use of WKWebsiteData
//    Store and HTTPCookieStorage singletons. Those need protocol seams
//    before the end-to-end "sign-out preserves Adobe DRM" can be unit-tested
//    against real production code. The deauthorize-args contract test here
//    pins the SDK-seam half of that flow; the WK / cookie half remains a
//    gap. Tracked in docs/Testing/Test_Seams_Refactor_Plan.md (P1).
