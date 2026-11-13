//
//  The borrow flow's OIDC re-auth must distinguish ASWebAuthenticationSession
//  code 1 (.canceledLogin: the patron declined) from code 3
//  (.presentationContextInvalid: the app failed to present, so retry). Treating
//  both as `false` left credentials `.credentialsStale` and re-presented sign-in
//  on every interaction until relaunch (field report, build 499).
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

    // MARK: - shouldRetry: the retry decision as a table

    // A source-text lint catches deletion but not addition or reordering; as a
    // pure function the decision can be asserted cell by cell.

    func testShouldRetry_onlyPresentationFailure_andOnlyOnFirstAttempt() {
        let all: [OIDCReauthAttempt] = [.succeeded, .patronCancelled, .presentationFailed, .failed]
        for outcome in all {
            for attempt in 0..<2 {
                let expected = (outcome == .presentationFailed) && attempt == 0
                XCTAssertEqual(
                    OIDCReauthAttempt.shouldRetry(outcome, attempt: attempt, maxAttempts: 2),
                    expected,
                    "shouldRetry(\(outcome), attempt: \(attempt)) must be \(expected)")
            }
        }
    }

    /// The bound is a value, so narrowing it fails a test rather than being a
    /// silent loop-header edit.
    func testShouldRetry_maxAttemptsOne_neverRetries() {
        XCTAssertFalse(
            OIDCReauthAttempt.shouldRetry(.presentationFailed, attempt: 0, maxAttempts: 1),
            "With one permitted attempt there is no retry — pins the bound itself")
    }

    /// A dismissed sheet is never re-presented, at any attempt index.
    func testShouldRetry_patronCancellation_isNeverRetried() {
        for attempt in 0..<5 {
            XCTAssertFalse(
                OIDCReauthAttempt.shouldRetry(.patronCancelled, attempt: attempt, maxAttempts: 5),
                "Re-presenting a sheet the patron dismissed is a consent defect (attempt \(attempt))")
        }
    }
}
