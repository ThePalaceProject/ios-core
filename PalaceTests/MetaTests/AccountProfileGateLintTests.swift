//
//  AccountProfileGateLintTests.swift
//  PalaceTests
//
//  Meta-test pinning the WIRING of the /patrons/me/ credentials gate:
//
//    `Account.getProfileDocument` MUST consult
//    `canAuthenticateProfileRequest(hasCredentials:tokenHasExpired:tokenRefreshWillRepair:)`
//    and MUST feed it all three live inputs.
//
//  Why this exists: the predicate is pure and fully unit-tested, but SoD review
//  measured that deleting the entire `if !canAuthenticateProfileRequest(...)`
//  block left every one of those tests green. That is precisely the F-007
//  vacuity this change was written to expose, reproduced one level up — a gate
//  protected by nothing, with a test suite that reports otherwise.
//
//  This file once justified itself by saying `getProfileDocument` offered no
//  seam from which a unit test could observe whether the request was issued.
//  That justification is DEAD: the method now takes `performRequest:` and
//  `userAccount:`, and `AccountProfileDocumentTests` drives the gate in both
//  directions through them. Those behavioural tests are the real guard.
//
//  What remains here is only a monotone structural check, and monotone means it
//  detects DELETION but never INSERTION — an `if` added ABOVE the gate leaves it
//  green. Do not read a pass here as the wiring being safe; that is what the
//  behavioural tests are for. Kept because a cheap deletion alarm still has
//  value, not because it gates anything on its own.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest

final class AccountProfileGateLintTests: XCTestCase {

    private var sourcePath: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // MetaTests/
            .deletingLastPathComponent()  // PalaceTests/
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("Palace/Accounts/Library/Account+profileDocument.swift")
    }

    /// Strips `//` comment tails so the lint scans CODE, not prose.
    ///
    /// Without this the assertions match their own explanatory comments — the
    /// `ratchet-detectors-count-comment-mentions` trap. The gate's docstring
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
        let raw = try String(contentsOf: sourcePath, encoding: .utf8)
        let code = strippingComments(raw)
        // Self-test: the lint must be reading real code, not an empty string —
        // otherwise every assertion below passes vacuously, which is the exact
        // failure mode this file exists to prevent.
        XCTAssertTrue(code.contains("func getProfileDocument"),
                      "Lint could not find getProfileDocument in \(sourcePath.path) — the file moved or was renamed. "
                      + "Fix the lint; do NOT delete it. A lint that cannot find its target reports a pass.")
        return code
    }

    /// The gate must actually be consulted.
    func testGetProfileDocument_callsTheCredentialsGate() throws {
        let code = try loadCode()
        // The needle must match the CALL, not the declaration. A bare
        // "canAuthenticateProfileRequest(" also matches `static func
        // canAuthenticateProfileRequest(` two lines above, so the assertion could
        // never fail — SoD review caught that. Match the guarded call form.
        XCTAssertTrue(code.contains("if !Account.canAuthenticateProfileRequest("),
                      "getProfileDocument no longer GUARDS on canAuthenticateProfileRequest. The predicate's unit "
                      + "tests stay green when this call is deleted, so they cannot catch it — that is why this lint exists.")
    }

    /// All three inputs must be fed from the live account, not hardcoded.
    func testGate_receivesAllThreeLiveInputs() throws {
        let code = try loadCode()

        for (label, needle) in [
            ("credential presence", "hasCredentials: userAccount.hasCredentials()"),
            ("token expiry", "tokenHasExpired: userAccount.authTokenHasExpired"),
            ("refresh repairability", "tokenRefreshWillRepair: userAccount.isTokenRefreshRequired()")
        ] {
            XCTAssertTrue(
                code.contains(needle),
                "The \(label) input is no longer wired from the live account (expected `\(needle)`). "
                + "Passing a literal here re-opens the defect while every predicate test stays green."
            )
        }
    }

    /// The repairability input is the regression guard: without it the gate
    /// blocks expired-but-refreshable credentials, deleting a repair that works.
    func testGate_doesNotBlockOnExpiryAlone() throws {
        let code = try loadCode()
        XCTAssertFalse(
            code.contains("tokenRefreshWillRepair: false"),
            "tokenRefreshWillRepair is hardcoded false, which makes the gate block every expired token again. "
            + "The reactive 401 path (refreshTokenAndResume → setAuthToken → .loggedIn) repairs exactly those "
            + "credentials and re-drives the task; blocking them removes a working repair."
        )
    }
}
