//
//  AdobeDeauthorizationTests.swift
//  PalaceTests
//
//  Sign-out is the ONLY thing in the app that frees an Adobe activation slot.
//  When it silently fails, the patron's next sign-in consumes another one, and
//  the ceiling arrives with nothing in any log to explain it. These tests pin
//  the two decisions that path makes.
//

import XCTest
@testable import Palace

final class AdobeDeauthorizationTests: XCTestCase {

    private let expiredToken  = "PALACE|1000000000|patron-1|sig"   // 2001
    private let liveTokenBase = "PALACE|%.0f|patron-1|sig"

    private func liveLicensor() -> [String: Any] {
        let future = Date().addingTimeInterval(1800).timeIntervalSince1970
        return ["vendor": "ThePalaceProject",
                "clientToken": String(format: liveTokenBase, future)]
    }

    // MARK: - What we send to Adobe

    func test_attempt_splitsClientTokenIntoUsernameAndPassword() {
        let attempt = AdobeDeauthorization.attempt(
            licensor: ["vendor": "V", "clientToken": "PALACE|123|patron-1|thesignature"],
            userID: "user", deviceID: "device")

        XCTAssertEqual(attempt?.username, "PALACE|123|patron-1")
        XCTAssertEqual(attempt?.password, "thesignature")
        XCTAssertEqual(attempt?.canReleaseServerSlot, true,
                       "a token that splits can authenticate, so the slot is releasable")
    }

    func test_attempt_whenClientTokenHasNoSeparator_stillCallsButCannotFreeTheSlot() {
        // THE inversion this test exists to record. The first version of this
        // guard returned nil here, on the reasoning that a token which cannot
        // be split cannot authenticate — true, and not the whole story.
        // `deauthorize` has TWO effects: the network release, which this input
        // genuinely cannot achieve, and RMSDK's clear of the LOCAL activation
        // files, which it achieves regardless. That local clear is what lets the
        // next sign-in re-activate, and it is the entire point of Reset Account.
        // Returning nil withheld it from the patron whose token had gone bad —
        // exactly the patron the screen exists for.
        let attempt = AdobeDeauthorization.attempt(
            licensor: ["vendor": "V", "clientToken": "no-separators-at-all"],
            userID: "user", deviceID: "device")

        XCTAssertNotNil(attempt, "the local activation clear must still be attempted")
        XCTAssertEqual(attempt?.canReleaseServerSlot, false,
                       "but the caller must be able to say the slot is lost")
    }

    func test_attempt_unparseableToken_sendsEmptyCredentials_notTheRawToken() {
        // `develop` sent (username: "", password: <whole token>) here. Passing
        // the raw token as a password is not more likely to work and puts a
        // credential-shaped string into whatever Adobe logs.
        let attempt = AdobeDeauthorization.attempt(
            licensor: ["vendor": "V", "clientToken": "no-separators-at-all"],
            userID: "user", deviceID: "device")

        XCTAssertEqual(attempt?.username, "")
        XCTAssertEqual(attempt?.password, "")
    }

    func test_attempt_licensorWithNoClientTokenAtAll_stillClearsLocally() {
        let attempt = AdobeDeauthorization.attempt(
            licensor: ["vendor": "V"], userID: "user", deviceID: "device")

        XCTAssertNotNil(attempt)
        XCTAssertEqual(attempt?.canReleaseServerSlot, false)
    }

    func test_attempt_withoutLicensor_cannotBeMade() {
        // The one genuine skip: no licensor means no Adobe state was ever
        // written for this library, so there is nothing to clear and nothing to
        // release. This is `develop`'s bar, restored exactly.
        XCTAssertNil(AdobeDeauthorization.attempt(licensor: nil, userID: "u", deviceID: "d"))
    }

    func test_attempt_withoutDeviceID_isStillMade_becauseRefusingWouldLeakTheSlot() {
        // This assertion is inverted from its first version, and the inversion
        // is the point. Requiring a (user, device) pair looked obviously right
        // — Adobe releases a pair — but `NYPLADEPT` is a binary, so whether a
        // nil userID actually fails there cannot be established from this repo.
        // Refusing on an unverifiable precondition means a patron with a
        // licensor and no stored deviceID skips deauthorization entirely and
        // leaks the activation: strictly worse than attempting and failing.
        // `TPPIdleSignOutRegressionTests` seeds exactly this shape and asserts
        // deauthorize IS called.
        let noDevice = AdobeDeauthorization.attempt(licensor: liveLicensor(),
                                                    userID: "u", deviceID: nil)
        XCTAssertNotNil(noDevice)
        XCTAssertNil(noDevice?.deviceID, "the missing half is passed through, not invented")

        let noUser = AdobeDeauthorization.attempt(licensor: liveLicensor(),
                                                  userID: nil, deviceID: "d")
        XCTAssertNotNil(noUser)
        XCTAssertNil(noUser?.userID)
    }

    func test_attempt_expiredButParseableToken_isStillReleasable() {
        // Expiry and parseability are different questions, and only the second
        // is knowable with certainty from here. An expired token will very
        // likely be rejected — the caller logs that separately — but the app
        // does not get to decide that on Adobe's behalf.
        let attempt = AdobeDeauthorization.attempt(
            licensor: ["vendor": "V", "clientToken": expiredToken],
            userID: "u", deviceID: "d")

        XCTAssertEqual(attempt?.canReleaseServerSlot, true)
    }

    // MARK: - What we conclude afterwards

    func test_outcome_success_freesTheSlot() {
        XCTAssertEqual(AdobeDeauthorization.outcome(success: true, error: nil), .freed)
    }

    func test_outcome_failure_isALeakedActivation_notAnExpectedNoOp() {
        // The code this replaces logged EVERY failure as "(expected)" at warn
        // level. A patron who hits the activation ceiling did so through this
        // branch, and nothing distinguished it from a benign one.
        let outcome = AdobeDeauthorization.outcome(
            success: false,
            error: NSError(domain: NYPLADEPTErrorDomain, code: 7, userInfo: nil))

        guard case .notFreed = outcome else {
            return XCTFail("a failed deauthorization leaves the activation consumed")
        }
    }

    func test_outcome_failure_namesTheAdobeCodeSoTheLeakIsDiagnosable() {
        let outcome = AdobeDeauthorization.outcome(
            success: false,
            error: NSError(domain: NYPLADEPTErrorDomain, code: 7,
                           userInfo: [NYPLADEPTErrorOriginalCodeKey: "E_DEACT_USER_MISMATCH"]))

        guard case .notFreed(let reason) = outcome else {
            return XCTFail("expected notFreed")
        }
        XCTAssertTrue(reason.contains("E_DEACT_USER_MISMATCH"),
                      "the Adobe original code is the only field that says WHY; got: \(reason)")
    }

    func test_outcome_failureWithNoError_stillReadsAsNotFreed() {
        // Adobe's completion can report `success == false` with a nil error.
        // Absence of an error object is not evidence the slot came back.
        guard case .notFreed = AdobeDeauthorization.outcome(success: false, error: nil) else {
            return XCTFail("no error object is not a success")
        }
    }

    // MARK: - The literal that mirrors an ADEPT header

    /// `AdobeDeauthorization` compiles into `Palace-noDRM`, where the ADEPT
    /// headers do not exist, so it spells the userInfo key out rather than
    /// importing `NYPLADEPTErrorOriginalCodeKey`. That is a duplication, and a
    /// duplication nobody compares is a drift waiting to happen: if the header
    /// ever renames the key, `outcome` would silently stop naming the Adobe code
    /// and every leak would go back to being anonymous. This is the comparison.
    func test_adobeOriginalCodeKey_matchesTheADEPTHeaderConstant() {
        XCTAssertEqual(AdobeDeauthorization.adobeOriginalCodeKey,
                       NYPLADEPTErrorOriginalCodeKey,
                       "the ungated literal has drifted from the ADEPT header it mirrors")
    }

    // MARK: - The condition that made the leak predictable

    func test_expiredLicensor_isRecognisedBeforeTheAttemptIsSpent() {
        // Same 60-minute CM token as the borrow path. If it is already dead we
        // know the deauthorization will fail, and that is the line worth logging.
        XCTAssertTrue(AdobeLicensorRefresh.isExpired(
            ["vendor": "V", "clientToken": expiredToken]))
        XCTAssertFalse(AdobeLicensorRefresh.isExpired(liveLicensor()))
    }
}
