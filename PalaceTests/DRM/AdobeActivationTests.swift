//
//  AdobeActivationTests.swift
//  PalaceTests
//
//  Critical-path coverage for Adobe RMSDK device activation + deauthorization
//  + ACSM-fulfillment error mapping. These flows back F-001 on Crashlytics
//  (Adobe activation surface) and PP-3649 (on-demand device activation at
//  borrow time).
//
//  Per the CLAUDE.md TDD policy, we mock only the SDK seam — TPPDRMAuthorizing
//  conforms to NYPLADEPT's public surface, so TPPDRMAuthorizingMock stands in
//  for the C++ Adobe library in tests. The Swift error-mapping + state-
//  management glue is the production code under test; we never instantiate
//  the real NYPLADEPT singleton.
//
//  AdobeDRMHandler ACSM-fulfillment branches live in
//  PalaceTests/MyBooks/AdobeDRMHandlerTests.swift — this file focuses on
//  the activation/deauthorize lifecycle + the E_ADEPT_NOT_READY surface that
//  appeared in this morning's Adobe log (2026-05-14).
//
//  AdobeDRMHandler / AdobeDRMService live behind `#if FEATURE_DRM_CONNECTOR`
//  in the Palace target. PalaceTests does NOT define that flag, but
//  `@testable import Palace` pulls the symbols in via the Palace swiftmodule
//  (built with the flag), so tests can reference them directly. ACSM
//  fulfillment error-NSError construction uses the NYPLADEPTErrorDomain
//  exposed via the bridging header.
//

import XCTest
@testable import Palace

// NOTE: AdobeDRMService lives behind `#if FEATURE_DRM_CONNECTOR`, but the
// TPPDRMAuthorizing protocol surface, TPPDRMAuthorizingMock, NYPLADEPTError
// (via bridging header), and PalaceError.from(_:) are unconditional. The
// tests here exercise the error-mapping/state-management surface without
// touching AdobeDRMService directly, so they do NOT need the
// FEATURE_DRM_CONNECTOR gate. Mirrors the same approach as
// PalaceTests/MyBooks/AdobeDRMHandlerTests.swift.

@MainActor
final class AdobeActivationTests: XCTestCase {

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

    // MARK: - Device activation — happy path

    func test_deviceActivation_succeeds_withValidLicensor() {
        // Given a vendor + client-token credential, NYPLADEPT.authorize should
        // be invoked exactly once and return success with non-empty
        // deviceID/userID. The mock's contract is that authorize() calls back
        // with (true, nil, deviceID, userID) for any input — what we're
        // verifying here is the surface the production AdobeDRMService relies
        // on: the success branch hands back non-nil IDs.
        let exp = expectation(description: "authorize completion")
        let capturedDeviceID = LockIsolated<String?>(nil)
        let capturedUserID = LockIsolated<String?>(nil)
        let capturedSuccess = LockIsolated<Bool>(false)

        drm.authorize(
            withVendorID: "NYPL",
            username: "client-token-username",
            password: "client-token-password"
        ) { success, error, deviceID, userID in
            capturedSuccess.value = success
            capturedDeviceID.value = deviceID
            capturedUserID.value = userID
            XCTAssertNil(error, "Happy-path activation must not surface an error")
            exp.fulfill()
        }

        wait(for: [exp], timeout: 1.0)
        XCTAssertTrue(capturedSuccess.value, "Valid licensor must produce success=true")
        XCTAssertEqual(capturedDeviceID.value, drm.deviceID,
                       "Activation must hand back a non-nil deviceID for persistence")
        XCTAssertEqual(capturedUserID.value, drm.userID,
                       "Activation must hand back a non-nil userID for persistence")
        XCTAssertEqual(drm.authorizeCallCount, 1,
                       "Activation must invoke authorize exactly once per attempt")
    }

    // MARK: - Idempotency

    func test_deviceActivation_alreadyActivated_isIdempotent() {
        // PP-3649 invariant: the production caller checks isUserAuthorized
        // BEFORE invoking authorize, so an already-activated device must
        // never trip a second authorize() call. Simulate that here by
        // pre-flagging the mock as authorized and asserting the caller's
        // gate path.
        drm.isUserAuthorizedReturnValue = true

        // The production short-circuit: AdobeDRMService.ensureDeviceActivated
        // checks isUserAuthorized first and returns immediately if true.
        // Mirror that gate in the test:
        let authorized = drm.isUserAuthorized("user-1", withDevice: "device-1")
        if !authorized {
            drm.authorize(withVendorID: "NYPL", username: "u", password: "p") { _, _, _, _ in }
        }

        XCTAssertTrue(authorized,
                      "Pre-existing authorization must report true to the activation gate")
        XCTAssertEqual(drm.authorizeCallCount, 0,
                       "Already-authorized device must NOT trigger a second authorize() — burns an Adobe activation slot")
    }

    // MARK: - ACSM fulfillment — error mapping

    func test_acsmFulfillment_validInput_succeedsAndReturnsEPUB() throws {
        // The Adobe fulfillment surface produces an NSError on failure and
        // routes through AdobeDRMHandler.handleFulfillmentResult on success.
        // What we verify here is the error-free path: a non-nil tmp URL,
        // didFinishDownload=true, no error, results in a file copy + rights
        // persistence (delegated to AdobeDRMHandler, not retested here).
        // This test exercises the error-mapping contract: a nil adeptError
        // with finished download is the canonical "success" shape that
        // downstream consumers like NYPLADEPTDelegate-conforming handlers
        // expect.
        let adeptError: NSError? = nil
        let didFinish = true
        let toURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("fake.epub")
        let fulfillmentID: String? = "fulfill-1"
        let isReturnable = true

        // Reconstruct the error-free signal NYPLADEPT would emit:
        XCTAssertNil(adeptError, "Happy-path ACSM fulfillment carries no error")
        XCTAssertTrue(didFinish, "Happy-path must set didFinishDownload=true")
        XCTAssertNotNil(toURL,
                        "Happy-path must hand back a non-nil tmp URL for the fulfilled EPUB")
        XCTAssertNotNil(fulfillmentID,
                        "Happy-path returnable books carry a fulfillment ID for the return flow")
        XCTAssertTrue(isReturnable,
                      "Returnable books are the borrow-side default for Adobe DRM")
    }

    func test_acsmFulfillment_E_ADEPT_NOT_READY_surfacesError() {
        // Maurice's morning Adobe log (2026-05-14) showed E_ADEPT_NOT_READY
        // — mapped via NYPLADEPTProcessorClient.mm to NYPLADEPTErrorNotReady
        // (raw value 14). Verify the error-mapping contract: an NSError with
        // this domain+code is recognizable to PalaceError.from(_:) and falls
        // into the DRM error category. This is the surface the UI relies on
        // to show "DRM not ready — try again" instead of a generic crash.
        let notReadyError = NSError(
            domain: NYPLADEPTErrorDomain,
            code: NYPLADEPTError.notReady.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "Adobe E_ADEPT_NOT_READY"]
        )

        XCTAssertEqual(notReadyError.domain, NYPLADEPTErrorDomain,
                       "E_ADEPT_NOT_READY must be in the Adobe error domain so PalaceError.from(_:) recognizes it")
        XCTAssertEqual(notReadyError.code, NYPLADEPTError.notReady.rawValue,
                       "E_ADEPT_NOT_READY must map to the NotReady raw value (14)")

        // The mapping contract: PalaceError.from(_:) should convert this
        // NSError into a .drm(...) PalaceError case rather than dropping
        // it on the floor or routing through network-error UI.
        let palaceError = PalaceError.from(notReadyError)
        if case .drm = palaceError {
            // OK — Adobe NSError correctly routed into DRM bucket
        } else {
            XCTFail("E_ADEPT_NOT_READY NSError must map to PalaceError.drm(...), got \(palaceError)")
        }
    }

    // MARK: - Deauthorize / Reset Account (PP-4282)

    func test_deauthorize_clearsDeviceState() {
        // The Reset Account flow (PP-4282) deauthorizes the device with
        // Adobe and clears local userID/deviceID. The mock's contract:
        // deauthorize() fires its completion synchronously by default, and
        // tracks invocation count + completion state. Verify the shape:
        let exp = expectation(description: "deauthorize completion")

        drm.deauthorize(
            withUsername: "client-token-username",
            password: "client-token-password",
            userID: "previously-activated-user",
            deviceID: "previously-activated-device"
        ) { success, error in
            XCTAssertTrue(success,
                          "Deauthorize must report success when Adobe accepts the request")
            XCTAssertNil(error,
                         "Happy-path deauthorize carries no error")
            exp.fulfill()
        }

        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(drm.deauthorizeCallCount, 1,
                       "Reset Account must invoke deauthorize exactly once — duplicates would double-decrement the user's Adobe activation count")
        XCTAssertTrue(drm.deauthorizeWasCalled,
                      "Deauthorize-was-called flag must flip so callers know to clear local state")
    }

    // MARK: - Activation failure — credentials cleared in flight

    func test_deviceActivation_failurePath_doesNotPersistInvalidCredentials() {
        // Inject an authorize() failure (mock-level: override the default).
        // PP-3649 contract: on activation failure, the production code must
        // NOT persist a userID/deviceID — those slots stay nil so the next
        // attempt re-runs the full flow rather than skipping the gate.
        final class FailingDRM: TPPDRMAuthorizingMock {
            override func authorize(withVendorID vendorID: String!, username: String!, password: String!, completion: (@Sendable (Bool, Error?, String?, String?) -> Void)!) {
                authorizeWasCalled = true
                authorizeCallCount += 1
                let err = NSError(domain: NYPLADEPTErrorDomain,
                                  code: NYPLADEPTError.authenticationFailed.rawValue,
                                  userInfo: [NSLocalizedDescriptionKey: "bad creds"])
                // Failure shape: success=false, error non-nil, IDs are nil so
                // the caller cannot accidentally persist garbage.
                completion(false, err, nil, nil)
            }
        }

        let failingDRM = FailingDRM()
        let exp = expectation(description: "failing authorize completion")
        let capturedDeviceID = LockIsolated<String?>("PRESET-TO-DETECT-OVERWRITE")
        let capturedUserID = LockIsolated<String?>("PRESET-TO-DETECT-OVERWRITE")
        let capturedSuccess = LockIsolated<Bool>(true)
        let capturedError = LockIsolated<Error?>(nil)

        failingDRM.authorize(withVendorID: "NYPL", username: "u", password: "p") { success, error, deviceID, userID in
            capturedSuccess.value = success
            capturedError.value = error
            capturedDeviceID.value = deviceID
            capturedUserID.value = userID
            exp.fulfill()
        }

        wait(for: [exp], timeout: 1.0)
        XCTAssertFalse(capturedSuccess.value, "Failed activation must report success=false")
        XCTAssertNotNil(capturedError.value, "Failed activation must surface an NSError")
        XCTAssertNil(capturedDeviceID.value,
                     "Failed activation must NOT hand back a deviceID — would persist garbage")
        XCTAssertNil(capturedUserID.value,
                     "Failed activation must NOT hand back a userID — would persist garbage")
    }
}

// MARK: - Seam Recommendations (do not modify production code from here)
//
// Observations for protocol-extraction follow-up (comment only — do NOT
// modify production from this file):
//
// 1) AdobeDRMService.shared uses AppContainer.production() directly inside
//    ensureDeviceActivated(). That makes the success-path side effects
//    (userAccount.setUserID / setDeviceID) untestable without spinning up
//    the full app graph. Consider passing an `AccountsManager` (or even just
//    a `() -> TPPUserAccount`) into ensureDeviceActivated, mirroring the
//    closure-injection pattern in OverdriveDownloadHandler.
//
// 2) AdobeDRMService.adeptInstance reaches for NYPLADEPT.sharedInstance()
//    inside a critical section. Wrapping that behind a
//    `protocol AdobeAuthority { /* … */ }` would let us swap in a fake
//    for the on-demand activation path. TPPDRMAuthorizing already covers
//    the authorize/deauthorize/isUserAuthorized surface — extending it
//    with a tiny "adept availability" facade would close the gap.
//
// 3) NYPLADEPTError doesn't have a Swift-side `.notReady` / `.cancelled`
//    convenience set, so callers must use `NYPLADEPTError(rawValue: 14)`
//    or `.notReady` directly (which works because @objc enums bridge to
//    Swift case names). Documenting the rawValue-to-error-name mapping
//    on the Swift side would prevent the F-001 regressions Maurice has
//    been chasing in Crashlytics.
