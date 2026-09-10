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
    }

    func test_attempt_whenClientTokenHasNoSeparator_isRefusedRatherThanSentAsGarbage() {
        // The previous inline split produced (username: "", password: whole-token)
        // for this input and handed it to Adobe, which cannot succeed. Refusing
        // makes the impossibility visible instead of spending a round trip.
        let attempt = AdobeDeauthorization.attempt(
            licensor: ["vendor": "V", "clientToken": "no-separators-at-all"],
            userID: "user", deviceID: "device")

        XCTAssertNil(attempt)
    }

    func test_attempt_withoutLicensor_cannotBeMade() {
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

    func test_attempt_stillRefusesTheOneThingThatCannotWork() {
        // The guard that survives: a token that cannot be split cannot
        // authenticate, whatever Adobe does with the rest.
        XCTAssertNil(AdobeDeauthorization.attempt(licensor: ["vendor": "V", "clientToken": "nosep"],
                                                  userID: "u", deviceID: "d"))
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

    // MARK: - The condition that made the leak predictable

    func test_expiredLicensor_isRecognisedBeforeTheAttemptIsSpent() {
        // Same 60-minute CM token as the borrow path. If it is already dead we
        // know the deauthorization will fail, and that is the line worth logging.
        XCTAssertTrue(AdobeLicensorRefresh.isExpired(
            ["vendor": "V", "clientToken": expiredToken]))
        XCTAssertFalse(AdobeLicensorRefresh.isExpired(liveLicensor()))
    }

    // MARK: - Redaction (these tokens are live credentials for 60 minutes)

    func test_redacted_neverContainsTheSignature() {
        // `Documents/Logs/palace_error.log` is exportable by the patron and is
        // routinely attached to support tickets. This is the assertion that
        // matters: the secret half must not survive.
        let signature = "s3cr3tSignatureValue"
        let output = AdobeDeauthorization.redacted("PALACE|1893456000|patron-1|\(signature)")

        XCTAssertFalse(output.contains(signature),
                       "the signature reached the log: \(output)")
    }

    func test_redacted_keepsWhatDiagnosisActuallyNeeds() {
        // Which library minted it and when it dies are the two questions asked
        // of this value in every investigation so far; both are non-secret.
        let output = AdobeDeauthorization.redacted("PALACE|1893456000|patron-1|sig")

        XCTAssertTrue(output.contains("PALACE"), output)
        XCTAssertTrue(output.contains("2030-01-01"), "expiry should be readable: \(output)")
    }

    func test_redacted_distinguishesAbsentFromMalformed() {
        // "none" and "unparseable" are different defects with different fixes,
        // and collapsing them is how a malformed token reads as no token.
        XCTAssertEqual(AdobeDeauthorization.redacted(nil), "none")
        XCTAssertEqual(AdobeDeauthorization.redacted(""), "none")
        XCTAssertTrue(AdobeDeauthorization.redacted("garbage").contains("unparseable"))
    }
}
