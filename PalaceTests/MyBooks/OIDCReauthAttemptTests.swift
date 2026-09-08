//
//  OIDCReauthAttemptTests.swift
//  PalaceTests
//
//  The borrow flow's OIDC re-auth used to collapse every
//  ASWebAuthenticationSession error to `false`, which erased the one
//  distinction that decides what happens next:
//
//    code 1  .canceledLogin              — the patron declined. Respect it.
//    code 3  .presentationContextInvalid — WE failed to present. Retry.
//
//  Reading 3 as a decline is what produced the field report on build 499: the
//  patron never saw a sheet, re-auth silently gave up, credentials stayed
//  `.credentialsStale`, and the sign-in sheet re-presented on every later
//  interaction until a relaunch stored a fresh token. "It keeps re-appearing,
//  but I'm actually logged in after a restart."
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
import AuthenticationServices
@testable import Palace

final class OIDCReauthAttemptTests: XCTestCase {

    /// Builds a real bridged `ASWebAuthenticationSessionError` so `classify`
    /// exercises the same cast production takes, not a stand-in.
    private func sessionError(_ code: ASWebAuthenticationSessionError.Code) -> Error {
        NSError(domain: ASWebAuthenticationSessionErrorDomain, code: code.rawValue)
    }

    // MARK: - Classification

    func testClassify_canceledLogin_isPatronCancelled() {
        XCTAssertEqual(
            OIDCReauthAttempt.classify(error: sessionError(.canceledLogin)),
            .patronCancelled,
            "Code 1 is the patron dismissing the sheet — it must not be confused with a presentation failure"
        )
    }

    func testClassify_presentationContextInvalid_isPresentationFailed() {
        XCTAssertEqual(
            OIDCReauthAttempt.classify(error: sessionError(.presentationContextInvalid)),
            .presentationFailed,
            "Code 3 means iOS rejected OUR anchor. The patron saw nothing, so this is ours to retry — "
            + "treating it as a decline is the build-499 re-auth loop."
        )
    }

    func testClassify_presentationContextNotProvided_isPresentationFailed() {
        XCTAssertEqual(
            OIDCReauthAttempt.classify(error: sessionError(.presentationContextNotProvided)),
            .presentationFailed,
            "Code 2 is the same class of failure as 3 — we did not give iOS a usable anchor"
        )
    }

    func testClassify_nonSessionError_isPlainFailure() {
        let networkish = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        XCTAssertEqual(
            OIDCReauthAttempt.classify(error: networkish),
            .failed,
            "An error that is not an ASWebAuthenticationSessionError must not be guessed into a retryable bucket"
        )
    }

    // MARK: - Retry policy

    /// The whole point: exactly one outcome may be retried.
    func testIsRetryable_isTrueOnlyForPresentationFailure() {
        XCTAssertTrue(OIDCReauthAttempt.presentationFailed.isRetryable,
                      "Our own presentation failure is the one case worth another attempt")

        for outcome in [OIDCReauthAttempt.succeeded, .patronCancelled, .failed] {
            XCTAssertFalse(outcome.isRetryable,
                           "\(outcome) must NOT be retried — re-presenting a sheet the patron dismissed is a defect")
        }
    }

    /// Pins the direction that matters most for consent: a patron who declines
    /// is never shown the sheet again by the retry path.
    func testPatronCancellation_isNeverRetried() {
        let outcome = OIDCReauthAttempt.classify(error: sessionError(.canceledLogin))
        XCTAssertFalse(outcome.isRetryable,
                       "A dismissed sheet must stay dismissed — retrying would re-present it against the patron's choice")
    }
}
