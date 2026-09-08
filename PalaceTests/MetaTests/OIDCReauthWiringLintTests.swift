//
//  OIDCReauthWiringLintTests.swift
//  PalaceTests
//
//  Pins the WIRING of the borrow flow's OIDC re-auth recovery.
//
//  `OIDCReauthAttempt` is a pure value type and fully unit-tested, but the
//  same SoD review that blocked this PR measured the matching failure one
//  level up: a classifier nothing consults, or a retry nothing performs, is
//  a guard protected by nothing while its own tests stay green. The
//  session completion and the presentation anchor both live behind
//  `ASWebAuthenticationSession`, which no unit test can drive, so the
//  structure is asserted instead — same shape and same reasoning as
//  `FCMRegistrationReadinessLintTests` and `AccountProfileGateLintTests`.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest

final class OIDCReauthWiringLintTests: XCTestCase {

    private var sourcePath: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // MetaTests/
            .deletingLastPathComponent()  // PalaceTests/
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("Palace/MyBooks/BorrowOperation.swift")
    }

    /// Strips `//` tails so the lint scans CODE, not the prose that
    /// necessarily names every symbol asserted below.
    private func strippingComments(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                guard let range = line.range(of: "//") else { return String(line) }
                return String(line[line.startIndex..<range.lowerBound])
            }
            .joined(separator: "\n")
    }

    private func loadCode() throws -> String {
        let code = strippingComments(try String(contentsOf: sourcePath, encoding: .utf8))
        // Self-test: a lint that cannot find its target must FAIL, not pass.
        XCTAssertTrue(code.contains("func attemptOIDCSilentReauth"),
                      "Lint could not find attemptOIDCSilentReauth in \(sourcePath.path). Fix the lint; do not delete it.")
        return code
    }

    /// The classifier must actually be consulted.
    func testSessionCompletion_classifiesTheError() throws {
        let code = try loadCode()
        XCTAssertTrue(
            code.contains("OIDCReauthAttempt.classify(error:"),
            "The session completion no longer classifies its error. Collapsing every error to a bare failure "
            + "is the original defect: a code-3 presentation failure becomes indistinguishable from the patron "
            + "declining, and the classifier's own tests stay green while it happens."
        )
    }

    /// A presentation failure must lead to a retry, not a silent give-up.
    func testPresentationFailure_isRetried() throws {
        let code = try loadCode()
        // Pin that the retry decision routes through `isRetryable`, NOT through a
        // literal `.presentationFailed` pattern. SoD review measured that with a
        // literal pattern, adding `case .patronCancelled where attempt == 0: continue`
        // passed every lint and every unit test — the consent guard was decorative.
        // Routing through the property makes `isRetryable`'s tests load-bearing.
        XCTAssertTrue(
            code.contains("outcome.isRetryable && attempt == 0"),
            "The retry decision no longer routes through `OIDCReauthAttempt.isRetryable`. With a literal case "
            + "pattern the property has zero production readers, so its consent tests pin nothing and a "
            + "`.patronCancelled` retry branch would pass the whole suite."
        )
    }

    /// The anchor must not fall straight back to a scene-less window.
    ///
    /// `ASPresentationAnchor()` is a bare `UIWindow` with no scene — precisely
    /// what iOS rejects with `.presentationContextInvalid`. Falling back to it
    /// directly from `mainKeyWindow` manufactures the failure it is meant to
    /// avoid, so the scene-window step between them is load-bearing.
    func testPresentationAnchor_prefersARealSceneWindow() throws {
        let code = try loadCode()

        XCTAssertTrue(
            code.contains("UIApplication.shared.webAuthPresentationAnchor"),
            "The anchor no longer uses the shared resolver. Resolving inline is how the three OIDC paths "
            + "drifted apart in the first place — two of them still carried the scene-less fallback."
        )

        XCTAssertFalse(
            code.contains("mainKeyWindow ?? ASPresentationAnchor()"),
            "The anchor reverted to the scene-less fallback that caused the build-499 presentation failures."
        )
    }
}
