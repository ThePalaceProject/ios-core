//
// no_problemdoc_in_scope.swift
// Fixture: a function that constructs NSError(...) but never receives or
// binds a TPPProblemDocument. The bug class explicitly requires upstream
// problem-doc context to be in scope — without it, there is nothing to
// drop. This is the false-positive immunity check (PR #935's commit body
// explicitly carves OIDC + DRM-ProfileDoc out as "not the same class of
// bug — no HTTP body to parse").
//
// Detector MUST PASS.
//

import Foundation

final class FixtureNoProblemDocInScope {
    // no-superpartner: D4-1 detector fixture, exercised by tests/test_check_nserror_problemdoc_preservation.py
    func reportEmptyUsername(completion: ((Error) -> Void)?) {
        // No HTTP response, no problemDoc — pure validation error.
        let error = NSError(
            domain: "clientDomain",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Cannot request token with empty username"]
        )
        completion?(error)
    }
}
