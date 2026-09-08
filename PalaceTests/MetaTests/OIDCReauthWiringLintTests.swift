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
        XCTAssertTrue(
            code.contains("case .presentationFailed where attempt == 0"),
            "The retry branch for a presentation failure is gone. Without it a code-3 failure strands the patron "
            + "with credentialsStale credentials and a sign-in sheet that re-presents until relaunch."
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
            code.contains("UIApplication.shared.mainWindowScene?.windows.first"),
            "The anchor no longer falls back to a real window from the active scene. Going straight from "
            + "mainKeyWindow to ASPresentationAnchor() hands iOS a scene-less window and guarantees code 3."
        )

        XCTAssertFalse(
            code.contains("mainKeyWindow ?? ASPresentationAnchor()"),
            "The anchor reverted to the scene-less fallback that caused the build-499 presentation failures."
        )
    }
}
